#!/usr/bin/env bash
# The container-engine seam: detection, and the per-engine answers every other
# script reads instead of branching on the engine itself.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

# shellcheck disable=SC1091
source tests/lib/fake-engine.sh

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

assert_value() {
  local expected="$1" actual="$2" description="$3"
  [ "$actual" = "$expected" ] || fail "$description: expected '$expected', got '$actual'"
}

# Each case gets a fresh shell: detection caches itself in the environment, so
# sharing one would test the cache rather than the probe.
engine_case() {
  bash -c "
    set -euo pipefail
    cd '$repo_root'
    source tests/lib/fake-engine.sh
    $1
  "
}

# --- detection --------------------------------------------------------------

assert_value podman "$(engine_case '
  fake_engine_start podman
  unset DUNE_CONTAINER_ENGINE
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_KIND"
')" "auto-detection recognises Podman from the compat socket's server block"

assert_value docker "$(engine_case '
  fake_engine_start docker
  unset DUNE_CONTAINER_ENGINE
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_KIND"
')" "auto-detection reports Docker for a Docker server block"

assert_value docker "$(engine_case '
  fake_engine_start podman
  export DUNE_CONTAINER_ENGINE=docker
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_KIND"
')" "the DUNE_CONTAINER_ENGINE override beats the probe"

assert_value podman "$(engine_case '
  fake_engine_start podman
  export DUNE_CONTAINER_ENGINE=nonsense
  source runtime/scripts/lib/engine.sh 2>/dev/null
  printf "%s" "$DUNE_ENGINE_KIND"
  # An unusable override must not be fatal, and must not be trusted either.
  true
')" "an unknown override falls back to detection rather than failing"

assert_value docker "$(engine_case '
  fake_engine_stop                      # remove the stub: no engine at all
  export PATH=/nonexistent
  unset DUNE_CONTAINER_ENGINE
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_KIND"
')" "an undetectable engine behaves exactly as Docker does today"

assert_value 0 "$(engine_case '
  fake_engine_start podman
  unset DUNE_CONTAINER_ENGINE
  source runtime/scripts/lib/engine.sh
  fake_engine_reset_calls
  source runtime/scripts/lib/engine.sh   # cached: must not probe again
  fake_engine_calls | grep -c . || true
')" "re-sourcing the seam costs no engine round-trip"

# --- the per-engine contract ------------------------------------------------

assert_value "unless-stopped docker.service  1 1" "$(engine_case '
  fake_engine_start docker
  source runtime/scripts/lib/engine.sh
  printf "%s %s %s %s %s" "$DUNE_ENGINE_RESTART_POLICY" "$DUNE_ENGINE_SYSTEMD_UNIT" \
    "$DUNE_ENGINE_MOUNT_SUFFIX" "$DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE" \
    "$DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE"
')" "the Docker contract is unchanged"

assert_value "always podman.socket z 0 0" "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  printf "%s %s %s %s %s" "$DUNE_ENGINE_RESTART_POLICY" "$DUNE_ENGINE_SYSTEMD_UNIT" \
    "$DUNE_ENGINE_MOUNT_SUFFIX" "$DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE" \
    "$DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE"
')" "the Podman contract differs only where Podman does"

# `unless-stopped` containers are not revived by podman-restart.service, so a
# reboot leaves the whole stack down. This is the single most consequential
# value in the file.
assert_value always "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_RESTART_POLICY"
')" "Podman containers get a restart policy that survives a reboot"

# --- bind mounts ------------------------------------------------------------

assert_value "/srv/a:/b|/srv/a:/b:ro|" "$(engine_case '
  fake_engine_start docker
  source runtime/scripts/lib/engine.sh
  printf "%s|%s|%s" "$(dune_engine_mount /srv/a /b)" "$(dune_engine_mount /srv/a /b ro)" \
    "$(dune_engine_label_disable_args)"
')" "Docker mounts are byte-identical to the hand-written form they replace"

assert_value "/srv/a:/b:z|/srv/a:/b:ro,z|--security-opt label=disable" "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  printf "%s|%s|%s" "$(dune_engine_mount /srv/a /b)" "$(dune_engine_mount /srv/a /b ro)" \
    "$(dune_engine_label_disable_args)"
')" "Podman mounts carry the shared relabel, appended to any existing options"

# :Z would give each container a private MCS category pair, which is exactly
# wrong for mounts shared between the orchestrator, the spawners and the
# servers.
assert_value z "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_MOUNT_SUFFIX"
')" "the relabel is shared (:z), never private (:Z)"

# --- images -----------------------------------------------------------------

assert_value "dune-orchestrator:dev|dune-orchestrator:dev|abc123|abc123" "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  printf "%s|%s|%s|%s" \
    "$(dune_engine_normalize_image_ref localhost/dune-orchestrator:dev)" \
    "$(dune_engine_normalize_image_ref dune-orchestrator:dev)" \
    "$(dune_engine_normalize_digest sha256:abc123)" \
    "$(dune_engine_normalize_digest abc123)"
')" "image and digest normalisation is idempotent and engine-independent"

# --- generated systemd units ------------------------------------------------

assert_value "Wants=docker.service
After=network-online.target docker.service" "$(engine_case '
  fake_engine_start docker
  source runtime/scripts/lib/engine.sh
  dune_engine_systemd_unit_ordering network-online.target
')" "generated units order against docker.service on Docker"

assert_value "Wants=podman.socket
After=podman.socket" "$(engine_case '
  fake_engine_start podman
  source runtime/scripts/lib/engine.sh
  dune_engine_systemd_unit_ordering
')" "generated units order against a unit that exists on Podman"

assert_value "" "$(engine_case '
  fake_engine_start docker
  unset DOCKER_HOST
  source runtime/scripts/lib/engine.sh
  dune_engine_systemd_service_environment
')" "a Docker unit needs no environment of its own"

# Generated units run with a clean environment, so a non-default socket has
# nowhere else to be declared.
assert_value "Environment=DOCKER_HOST=unix:///run/podman/podman.sock
Environment=DOCKER_BUILDKIT=0" "$(engine_case '
  fake_engine_start podman
  export DOCKER_HOST=unix:///run/podman/podman.sock
  source runtime/scripts/lib/engine.sh
  dune_engine_systemd_service_environment
')" "a Podman unit carries the socket and the classic builder into its own environment"

assert_value "Environment=DOCKER_BUILDKIT=0" "$(engine_case '
  fake_engine_start podman
  export DOCKER_HOST=unix:///var/run/docker.sock
  source runtime/scripts/lib/engine.sh
  dune_engine_systemd_service_environment
')" "a socket published at the Docker default needs no DOCKER_HOST"

# --- socket resolution ------------------------------------------------------

assert_value /custom/engine.sock "$(engine_case '
  fake_engine_start podman
  export DOCKER_HOST=unix:///custom/engine.sock
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_SOCKET"
')" "an explicit DOCKER_HOST wins over both defaults"

assert_value /var/run/docker.sock "$(engine_case '
  fake_engine_start docker
  unset DOCKER_HOST
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DUNE_ENGINE_SOCKET"
')" "Docker keeps its own socket path"

# --- Compose builder --------------------------------------------------------

# Compose v2 against the compat socket cannot use BuildKit; letting it try
# produces an error that reads like a broken Dockerfile.
assert_value 0 "$(engine_case '
  fake_engine_start podman
  unset DOCKER_BUILDKIT
  source runtime/scripts/lib/engine.sh
  printf "%s" "${DOCKER_BUILDKIT:-unset}"
')" "the classic builder is forced on Podman"

assert_value unset "$(engine_case '
  fake_engine_start docker
  unset DOCKER_BUILDKIT
  source runtime/scripts/lib/engine.sh
  printf "%s" "${DOCKER_BUILDKIT:-unset}"
')" "Docker's builder choice is left alone"

assert_value 1 "$(engine_case '
  fake_engine_start podman
  export DOCKER_BUILDKIT=1
  source runtime/scripts/lib/engine.sh
  printf "%s" "$DOCKER_BUILDKIT"
')" "an operator who asked for BuildKit is not overruled"

# --- container detection ----------------------------------------------------

# Podman never creates /.dockerenv; it writes /run/.containerenv and sets
# container=podman.
assert_value yes "$(engine_case '
  fake_engine_start docker
  source runtime/scripts/lib/engine.sh
  container=podman
  dune_in_container && printf yes || printf no
')" "the container marker Podman actually sets is recognised"

assert_value no "$(engine_case '
  fake_engine_start docker
  source runtime/scripts/lib/engine.sh
  unset container
  if [ -f /.dockerenv ] || [ -f /run/.containerenv ]; then printf no; exit 0; fi
  dune_in_container && printf yes || printf no
')" "a host with no container marker is reported as a host"

# --- log options (runtime-env.sh consumes the seam) -------------------------

log_args_case() {
  engine_case "
    fake_engine_start $1
    export DUNE_COMPOSE_PROJECT_NAME=test-engine-seam
    source runtime/scripts/runtime-env.sh
    printf '%s' \"\${DUNE_DOCKER_LOG_ARGS[*]}\"
  "
}

assert_value "--log-driver json-file --log-opt max-size=50m --log-opt max-file=3" \
  "$(log_args_case docker)" "Docker keeps the rotation count"

assert_value "--log-driver json-file --log-opt max-size=50m" \
  "$(log_args_case podman)" "Podman drops max-file, which its json-file driver rejects"

label_disable_case() {
  engine_case "
    fake_engine_start $1
    export DUNE_COMPOSE_PROJECT_NAME=test-engine-seam
    source runtime/scripts/runtime-env.sh
    printf '%s' \"\${DUNE_ENGINE_LABEL_DISABLE_ARGS[*]}\"
  "
}

assert_value "" "$(label_disable_case docker)" \
  "the host-root helpers pass nothing extra on Docker"
assert_value "--security-opt label=disable" "$(label_disable_case podman)" \
  "the host-root helpers never relabel / on Podman"

socket_security_opt_case() {
  engine_case "
    fake_engine_start $1
    source runtime/scripts/lib/engine.sh
    printf '%s' \"\$DUNE_ENGINE_SOCKET_SECURITY_OPT\"
  "
}

# Not empty on Docker: compose cannot spell an absent list entry, so the value
# has to be one Docker treats as its own default.
assert_value "no-new-privileges:false" "$(socket_security_opt_case docker)" \
  "socket mounters keep Docker's own default"
assert_value "label=disable" "$(socket_security_opt_case podman)" \
  "socket mounters get the label separation turned off, without which container_t cannot connectto the compat socket"

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

echo "OK: container-engine seam"
