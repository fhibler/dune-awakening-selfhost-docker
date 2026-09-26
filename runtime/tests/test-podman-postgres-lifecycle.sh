#!/usr/bin/env bash
# The Postgres lifecycle on both engines: the real start-postgres.sh and
# stop-postgres-container.sh, driven by the recorded fake engine.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

assert_called() {
  local pattern="$1" log="$2" description="$3"
  grep -Eq -- "$pattern" "$log" || fail "$description"
}

refute_called() {
  local pattern="$1" log="$2" description="$3"
  grep -Eq -- "$pattern" "$log" && fail "$description"
  return 0
}

line_of() {
  grep -En -- "$1" "$2" | head -1 | cut -d: -f1
}

# Run the real start-postgres.sh against a throwaway project tree and leave the
# recorded argv in $1, one call per line.
#
# The whole runtime/scripts tree is copied rather than a hand-picked list:
# these scripts source half a dozen siblings, and a list that drifts fails as a
# missing file rather than as the behaviour under test.
#
# Each leg runs in a subshell -- fake_engine_start exports the engine it is
# impersonating and installs its own EXIT trap, and neither may leak into the
# next leg.
start_postgres_leg() {
  local kind="$1" out="$2" volume_create_status="$3" listing="$4"
  (
    local test_root
    test_root="$(mktemp -d)"
    mkdir -p "$test_root/runtime"
    cp -R runtime/scripts "$test_root/runtime/scripts"

    # shellcheck disable=SC1091
    source tests/lib/fake-engine.sh
    fake_engine_start "$kind"

    # fake-engine.sh stubs `docker` only, and the network seam reaches for the
    # native podman(1) for the one flag the compat API cannot carry.
    cat >"$FAKE_ENGINE_DIR/bin/podman" <<'STUB'
#!/usr/bin/env bash
# Recorded stub, logged alongside the docker calls so ordering is visible.
printf 'podman %s\n' "$*" >>"$FAKE_ENGINE_LOG"
STUB
    chmod +x "$FAKE_ENGINE_DIR/bin/podman"

    fake_engine_respond images <<'OUT'
registry.funcom.com/funcom/self-hosting/igw-postgres
OUT
    printf '%s' "$listing" | fake_engine_respond 'ps -a'
    fake_engine_respond inspect <<'OUT'
true
OUT
    fake_engine_exit_status 'volume create' "$volume_create_status"

    cd "$test_root"
    runtime/scripts/start-postgres.sh >/dev/null
    cd "$repo_root"

    fake_engine_calls >"$out"
    rm -rf "$test_root"
  )
}

# --- Podman -----------------------------------------------------------------

podman_log="$(mktemp)"
listing='dune-postgres
dune-postgres-exporter
'

# A second and every later run hits a volume that already exists. Docker's
# compat endpoint answers that with success; podman(1) exits 125, and under
# `set -e` an unguarded create means Postgres never starts again.
if ! start_postgres_leg podman "$podman_log" 125 "$listing"; then
  fail "start-postgres.sh aborted on Podman when the data volume already existed"
fi

assert_called '^run -d .* --name dune-postgres ' "$podman_log" \
  "the duplicate volume create stopped start-postgres.sh before it ran the container"

assert_called '^run -d .* --restart always ' "$podman_log" \
  "Podman containers must restart 'always': podman-restart.service leaves 'unless-stopped' ones down after a reboot"

# `--dns-enabled` exists only on podman(1). Without it the bridge can come up
# with netavark resolution off, and every container-name reference in the stack
# fails as an NXDOMAIN at runtime rather than as an error here.
assert_called '^podman network create --dns-enabled dune-net$' "$podman_log" \
  "the stack's bridge was created without Podman's name resolution"

native="$(line_of '^podman network create ' "$podman_log")"
compat="$(line_of '^network create dune-net$' "$podman_log")"
if [ -n "$native" ] && [ -n "$compat" ] && [ "$native" -gt "$compat" ]; then
  fail "the compat create won the race and made the bridge without DNS"
fi

# --- Docker -----------------------------------------------------------------

docker_log="$(mktemp)"
start_postgres_leg docker "$docker_log" 0 "$listing"

assert_called '^run -d .* --restart unless-stopped ' "$docker_log" \
  "Docker's restart policy changed"
assert_called '^network create dune-net$' "$docker_log" \
  "Docker's network create argv changed"
refute_called '^podman ' "$docker_log" \
  "the Docker leg shelled out to podman"

# --- the container-name filter (both legs) ----------------------------------

# `--filter 'name=^/dune-postgres$'` matches Docker's internal `/name`
# spelling, which Podman's compat layer does not reproduce; there the filter
# finds nothing, the container is neither stopped nor removed, and the next
# start-postgres.sh fails on the name conflict.
for log in "$podman_log" "$docker_log"; do
  refute_called 'filter [^ ]*name=\^?/' "$log" \
    "a container name was matched through Docker's internal leading-slash form"
  assert_called '^stop --time 120 dune-postgres$' "$log" \
    "the running container was not shut down gracefully before removal"
  assert_called '^rm dune-postgres$' "$log" \
    "the old container was not removed"
done

# The listing is matched whole-line, so a peer whose name merely starts with
# the same string must not be mistaken for it.
near_miss_log="$(mktemp)"
(
  # shellcheck disable=SC1091
  source tests/lib/fake-engine.sh
  fake_engine_start docker
  fake_engine_respond 'ps -a' <<'OUT'
dune-postgres-exporter
OUT
  runtime/scripts/stop-postgres-container.sh
  fake_engine_calls >"$near_miss_log"
)
refute_called '^(stop|rm) ' "$near_miss_log" \
  "a container named like dune-postgres, but not it, was stopped and removed"

rm -f "$podman_log" "$docker_log" "$near_miss_log"

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

echo "OK: Postgres lifecycle on both engines"
