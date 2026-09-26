#!/usr/bin/env bash
# A stub `docker` on PATH that records what it was asked to do and can present
# itself as either container engine.
#
# The suite already fakes `docker` in two dozen places -- five shadow it as a
# shell function, the rest drop a one-off stub on PATH. Both work, but neither
# can answer the engine-detection probe in runtime/scripts/lib/engine.sh, so
# neither can exercise the Podman leg of a script. This consolidates the
# existing pattern into one fake that can.
#
# Usage:
#
#   source tests/lib/fake-engine.sh
#   fake_engine_start podman            # or docker
#   fake_engine_respond images <<'OUT'
#   localhost/dune-orchestrator dev
#   OUT
#   fake_engine_exit_status "volume create" 125
#
#   runtime/scripts/start-postgres.sh
#
#   fake_engine_called_with 'run .*--restart always' || fail ...
#   fake_engine_stop                    # restores PATH; also runs on EXIT
#
# Subcommand keys are matched against the leading arguments, longest first, so
# both `volume` and `volume create` are valid keys.
#
# fake_engine_start installs an EXIT trap so a failing assertion still removes
# the stub. A test that needs its own EXIT trap must install it afterwards and
# call fake_engine_stop from it.

FAKE_ENGINE_DIR=""
FAKE_ENGINE_LOG=""
_fake_engine_saved_path=""

fake_engine_start() {
  local kind="${1:-docker}"
  case "$kind" in
    docker | podman) ;;
    *)
      echo "fake_engine_start: unknown engine kind '$kind'" >&2
      return 1
      ;;
  esac

  FAKE_ENGINE_DIR="$(mktemp -d)"
  FAKE_ENGINE_LOG="$FAKE_ENGINE_DIR/calls.log"
  mkdir -p "$FAKE_ENGINE_DIR/bin" "$FAKE_ENGINE_DIR/stdout" "$FAKE_ENGINE_DIR/status"
  : >"$FAKE_ENGINE_LOG"
  printf '%s' "$kind" >"$FAKE_ENGINE_DIR/kind"

  cat >"$FAKE_ENGINE_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
# Recorded stub. See tests/lib/fake-engine.sh.
printf '%s\n' "$*" >>"$FAKE_ENGINE_LOG"

kind="$(cat "$FAKE_ENGINE_DIR/kind")"

# The engine-detection probe. Podman's compat layer names itself in the server
# block; Docker's never contains the string.
if [ "${1:-}" = "version" ] && [ "${2:-}" = "--format" ] && [ "${3:-}" = '{{json .Server}}' ]; then
  if [ "$kind" = "podman" ]; then
    printf '%s\n' '{"Platform":{"Name":"linux/arm64/almalinux-10"},"Components":[{"Name":"Podman Engine","Version":"5.4.0"}],"Version":"5.4.0","ApiVersion":"1.41"}'
  else
    printf '%s\n' '{"Platform":{"Name":"Docker Engine - Community"},"Components":[{"Name":"Engine","Version":"27.5.1"}],"Version":"27.5.1","ApiVersion":"1.47"}'
  fi
  exit 0
fi

# Longest-prefix match, so both "volume" and "volume create" are usable keys.
key=""
for count in 3 2 1; do
  [ "$#" -ge "$count" ] || continue
  candidate="$(printf '%s' "${*:1:count}" | tr ' /' '__')"
  if [ -e "$FAKE_ENGINE_DIR/stdout/$candidate" ] || [ -e "$FAKE_ENGINE_DIR/status/$candidate" ]; then
    key="$candidate"
    break
  fi
done

[ -n "$key" ] && [ -f "$FAKE_ENGINE_DIR/stdout/$key" ] && cat "$FAKE_ENGINE_DIR/stdout/$key"
if [ -n "$key" ] && [ -f "$FAKE_ENGINE_DIR/status/$key" ]; then
  exit "$(cat "$FAKE_ENGINE_DIR/status/$key")"
fi
exit 0
STUB
  chmod +x "$FAKE_ENGINE_DIR/bin/docker"

  _fake_engine_saved_path="$PATH"
  PATH="$FAKE_ENGINE_DIR/bin:$PATH"
  export PATH FAKE_ENGINE_DIR FAKE_ENGINE_LOG

  # Pin the engine the code under test sees. Detection would reach the stub
  # anyway, but a test that says which engine it is exercising is a test whose
  # failure names the leg it failed on.
  DUNE_CONTAINER_ENGINE="$kind"
  unset DUNE_ENGINE_READY
  export DUNE_CONTAINER_ENGINE

  trap fake_engine_stop EXIT
}

# Script the stub's stdout for a subcommand. Body on stdin.
fake_engine_respond() {
  local key="${1//[ \/]/_}"
  cat >"$FAKE_ENGINE_DIR/stdout/$key"
}

# Script the stub's exit status for a subcommand.
fake_engine_exit_status() {
  local key="${1//[ \/]/_}"
  printf '%s' "$2" >"$FAKE_ENGINE_DIR/status/$key"
}

# Every recorded invocation, one argv per line.
fake_engine_calls() {
  cat "$FAKE_ENGINE_LOG"
}

fake_engine_reset_calls() {
  : >"$FAKE_ENGINE_LOG"
}

# True when some invocation matched the extended regular expression.
fake_engine_called_with() {
  grep -Eq -- "$1" "$FAKE_ENGINE_LOG"
}

fake_engine_stop() {
  [ -n "$_fake_engine_saved_path" ] && PATH="$_fake_engine_saved_path"
  [ -n "$FAKE_ENGINE_DIR" ] && rm -rf "$FAKE_ENGINE_DIR"
  FAKE_ENGINE_DIR=""
  FAKE_ENGINE_LOG=""
  _fake_engine_saved_path=""
  unset DUNE_CONTAINER_ENGINE DUNE_ENGINE_READY
}
