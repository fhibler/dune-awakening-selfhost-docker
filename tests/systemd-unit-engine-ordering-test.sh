#!/usr/bin/env bash
# The generated systemd units, and the privileged helpers that install them on
# the host, on both engines.
#
# systemd treats an ordering dependency on a unit that does not exist as a
# silent no-op, and a generated unit runs with a clean environment. A unit that
# names docker.service on a Podman host therefore loses both its ordering
# guarantee and its route to the engine, with nothing said anywhere: the unit
# simply starts before the socket is up, or runs without a DOCKER_HOST it needs.
#
# Two of the five generators are covered, because they are the two shapes:
# restart-schedule.sh orders after an extra target the way db.sh, update.sh and
# ip-change-restart.sh do, and shutdown-protection.sh orders against the engine
# alone inside a DefaultDependencies=no unit. That all five route through the
# seam rather than naming an engine unit by hand is pinned statically in
# console/api/test/systemdHelperScripts.test.js.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# shellcheck source=tests/lib/fake-engine.sh
source tests/lib/fake-engine.sh

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

fail() {
  echo "FAIL $1"
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@"
  exit 1
}

# The install_units()/install_unit() writers, called with a directory of ours
# instead of /etc/systemd/system. Sourcing with $0 set to the script keeps the
# script's own `cd "$(dirname "$0")/../.."` landing in the repo root, and
# `status` is the read-only subcommand that lets the source return.
generate_units() {
  local engine="$1" docker_host="$2" script="$3"
  shift 3

  (
    fake_engine_start "$engine"
    if [ -n "$docker_host" ]; then
      export DOCKER_HOST="$docker_host"
    fi
    bash -c 'source "$0" status >/dev/null 2>&1; "$@"' "$script" "$@"
  )
}

# Everything the generated unit says about the engine, in file order.
engine_lines() {
  grep -E '^(Wants|After|Environment)=' "$1" || true
}

# The [Service] body has to open with its environment and then Type=oneshot,
# with no blank line: on Docker the environment is empty and the unit must stay
# byte for byte what it was before the seam existed.
service_head() {
  local unit="$1" count="$2"
  grep -A"$count" -x '\[Service\]' "$unit" | tail -n +2
}

expect() {
  local label="$1" expected="$2" actual="$3"
  [ "$actual" = "$expected" ] || fail "$label" "expected:" "$expected" "actual:" "$actual"
}

# --- Scheduled restart units --------------------------------------------

docker_units="$test_root/restart-docker"
generate_units docker "" runtime/scripts/restart-schedule.sh \
  write_units_to 04:00 15 03:45 "$docker_units" /opt/dune

for unit in dune-awakening-scheduled-restart.service \
  dune-awakening-scheduled-restart-warning.service; do
  expect "restart-schedule-docker-ordering ($unit)" \
    "$(printf 'Wants=docker.service\nAfter=network-online.target docker.service')" \
    "$(engine_lines "$docker_units/$unit")"
  expect "restart-schedule-docker-service-head ($unit)" \
    "Type=oneshot" \
    "$(service_head "$docker_units/$unit" 1)"
done
echo "PASS restart-schedule-orders-against-docker-service"

podman_units="$test_root/restart-podman"
generate_units podman "unix:///run/podman/podman.sock" runtime/scripts/restart-schedule.sh \
  write_units_to 04:00 15 03:45 "$podman_units" /opt/dune

for unit in dune-awakening-scheduled-restart.service \
  dune-awakening-scheduled-restart-warning.service; do
  expect "restart-schedule-podman-ordering ($unit)" \
    "$(printf 'Wants=podman.socket\nAfter=network-online.target podman.socket\nEnvironment=DOCKER_HOST=unix:///run/podman/podman.sock\nEnvironment=DOCKER_BUILDKIT=0')" \
    "$(engine_lines "$podman_units/$unit")"
  expect "restart-schedule-podman-service-head ($unit)" \
    "$(printf 'Environment=DOCKER_HOST=unix:///run/podman/podman.sock\nEnvironment=DOCKER_BUILDKIT=0\nType=oneshot')" \
    "$(service_head "$podman_units/$unit" 3)"
done
echo "PASS restart-schedule-orders-against-podman-socket"

# The timers reach nothing but their own service, so they must not have grown
# an engine dependency along the way.
for timer in dune-awakening-scheduled-restart.timer \
  dune-awakening-scheduled-restart-warning.timer; do
  expect "restart-schedule-timer-untouched ($timer)" "" \
    "$(engine_lines "$podman_units/$timer")"
done
echo "PASS scheduled-restart-timers-carry-no-engine-dependency"

# --- Shutdown protection unit -------------------------------------------

shutdown_unit="$(grep -m1 '^SERVICE_NAME=' runtime/scripts/shutdown-protection.sh | cut -d'"' -f2)"

docker_shutdown="$test_root/shutdown-docker"
generate_units docker "" runtime/scripts/shutdown-protection.sh \
  write_unit_to "$docker_shutdown" /opt/dune
expect "shutdown-protection-docker-ordering" \
  "$(printf 'Wants=docker.service\nAfter=docker.service')" \
  "$(engine_lines "$docker_shutdown/$shutdown_unit")"
expect "shutdown-protection-docker-service-head" "Type=oneshot" \
  "$(service_head "$docker_shutdown/$shutdown_unit" 1)"
echo "PASS shutdown-protection-orders-against-docker-service"

podman_shutdown="$test_root/shutdown-podman"
generate_units podman "unix:///run/podman/podman.sock" runtime/scripts/shutdown-protection.sh \
  write_unit_to "$podman_shutdown" /opt/dune
expect "shutdown-protection-podman-ordering" \
  "$(printf 'Wants=podman.socket\nAfter=podman.socket\nEnvironment=DOCKER_HOST=unix:///run/podman/podman.sock\nEnvironment=DOCKER_BUILDKIT=0')" \
  "$(engine_lines "$podman_shutdown/$shutdown_unit")"

# The whole point of this unit is that it stops the stack before the engine
# goes away, so the ordering has to stay inside the DefaultDependencies=no
# block and ahead of the shutdown targets.
expect "shutdown-protection-podman-ordering-position" \
  "$(printf 'DefaultDependencies=no\nWants=podman.socket\nAfter=podman.socket\nBefore=shutdown.target reboot.target halt.target kexec.target')" \
  "$(grep -A3 -x 'DefaultDependencies=no' "$podman_shutdown/$shutdown_unit")"
echo "PASS shutdown-protection-orders-against-podman-socket"

# --- Privileged host-systemd helper argv --------------------------------

# A real socket, because the helpers now resolve the engine's socket instead of
# testing the Docker path by name -- a Podman host that skipped the drop-in
# would otherwise fail the guard and never install the timer.
engine_socket="$test_root/engine.sock"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$engine_socket"

helper_calls() {
  local engine="$1" out="$2"

  (
    fake_engine_start "$engine"
    export DOCKER_HOST="unix://$engine_socket"
    bash -c 'source "$0" status >/dev/null 2>&1; install_units_via_docker_host 04:00 15 03:45' \
      runtime/scripts/restart-schedule.sh >/dev/null 2>&1
    cp "$FAKE_ENGINE_LOG" "$out"
  )
}

helper_calls docker "$test_root/helper-docker.log"
helper_calls podman "$test_root/helper-podman.log"

for engine in docker podman; do
  log="$test_root/helper-$engine.log"
  grep -q -- '-v /:/host' "$log" ||
    fail "helper-runs-on-$engine" "the helper never ran:" "$(cat "$log")"
  # A relabel request on / would rewrite the SELinux context of the entire host
  # filesystem, so the mount is never spelled with one on either engine.
  ! grep -qE -- '-v /:/host:[a-zA-Z,]+' "$log" ||
    fail "helper-relabels-host-root-on-$engine" "$(cat "$log")"
done

grep -q -- '--security-opt label=disable' "$test_root/helper-podman.log" ||
  fail helper-does-not-disable-labelling-on-podman "$(cat "$test_root/helper-podman.log")"
! grep -q -- '--security-opt' "$test_root/helper-docker.log" ||
  fail helper-argv-changed-on-docker "$(cat "$test_root/helper-docker.log")"
echo "PASS host-root-helper-disables-relabelling-on-podman-only"

# The unit text the helper hands the container is the same seam output, passed
# as environment because the heredoc is evaluated inside the container.
grep -q 'DUNE_SYSTEMD_UNIT_ORDERING=Wants=podman.socket' "$test_root/helper-podman.log" ||
  fail helper-passes-no-podman-ordering "$(cat "$test_root/helper-podman.log")"
grep -q 'DUNE_SYSTEMD_UNIT_ORDERING=Wants=docker.service' "$test_root/helper-docker.log" ||
  fail helper-passes-no-docker-ordering "$(cat "$test_root/helper-docker.log")"
echo "PASS host-root-helper-carries-the-engine-ordering-into-the-container"

echo "All systemd unit engine ordering tests passed."
