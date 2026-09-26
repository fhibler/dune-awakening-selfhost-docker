#!/usr/bin/env bash
# The engine-aware checks in doctor.sh.
#
# `dune doctor` is the operator's only window into a misconfigured host, so
# the property under test throughout is that a check either asserts something
# or says it could not -- never that it passes vacuously on Podman.
#
# doctor.sh runs top to bottom and needs a configured checkout, a running
# stack and `ss` before it reaches any of these, so the checks are lifted out
# of the shipped file by name and run against a fake engine. The bodies under
# test are the ones that ship.
set -euo pipefail

cd "$(dirname "$0")/.."

doctor="runtime/scripts/doctor.sh"
bash -n "$doctor"

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT

# A host with one generated unit installed, ordered against docker.service.
cat >"$STUB_DIR/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "show dune-awakening-shutdown-protection.service --property=LoadState --value") echo loaded ;;
  "show dune-awakening-shutdown-protection.service --property=After --value") echo "network-online.target docker.service" ;;
  "show docker.service --property=LoadState --value") echo loaded ;;
  "show podman.socket --property=LoadState --value") echo loaded ;;
  *"--property=LoadState --value") echo not-found ;;
  *) : ;;
esac
STUB
chmod +x "$STUB_DIR/systemctl"
export PATH="$STUB_DIR:$PATH"

# shellcheck source=tests/lib/fake-engine.sh
. tests/lib/fake-engine.sh

eval "$(awk '
  $0 ~ /^(ok|warn_msg|info_msg|fail_msg|is_running|docker_size_bytes|check_docker_storage|check_podman_host_tools|check_bridge_dns|check_game_container_argv|check_generated_unit_engine_ordering)\(\) \{$/ { inside = 1 }
  inside { print }
  inside && $0 == "}" { inside = 0 }
' "$doctor")"

failures=0
fail=0
warn=0

use_engine() {
  fake_engine_start "$1"
  unset DOCKER_HOST DOCKER_BUILDKIT DUNE_ENGINE_READY
  # shellcheck source=runtime/scripts/lib/engine.sh
  . runtime/scripts/lib/engine.sh
}

assert_contains() {
  local output="$1" needle="$2" description="$3"
  if ! grep -qF -- "$needle" <<<"$output"; then
    echo "FAIL: $description" >&2
    sed 's/^/      /' <<<"$output" >&2
    failures=$((failures + 1))
  fi
}

assert_missing() {
  local output="$1" needle="$2" description="$3"
  if grep -qF -- "$needle" <<<"$output"; then
    echo "FAIL: $description" >&2
    sed 's/^/      /' <<<"$output" >&2
    failures=$((failures + 1))
  fi
}

# --- 5.11: the build-cache line -------------------------------------------

use_engine docker
fake_engine_respond "system df" <<'OUT'
Images|1.2GB
Build Cache|3GB
OUT
out="$(check_docker_storage 2>&1)"
assert_contains "$out" "Reclaimable Docker build cache: 3GB" \
  "the Docker leg still reports reclaimable build cache"
fake_engine_stop

use_engine podman
fake_engine_respond "system df" <<'OUT'
Images|1.2GB
Local Volumes|0B
OUT
out="$(check_docker_storage 2>&1)"
assert_missing "$out" "build cache" \
  "Podman has no build-cache row, so doctor must not report a figure for one"
assert_contains "$out" "No obsolete project-owned Docker images found" \
  "the image check still runs after the build-cache line is dropped"
fake_engine_stop

# --- 5.18: bridge name resolution -----------------------------------------

use_engine podman
fake_engine_respond ps <<'OUT'
dune-postgres
dune-text-router
OUT
fake_engine_respond run <<'OUT'
10.89.0.2	dune-postgres
10.89.0.5	dune-text-router
OUT
out="$(check_bridge_dns 2>&1)"
assert_contains "$out" "OK   Bridge name resolution works" \
  "resolving both names from the bridge passes"
if ! fake_engine_called_with 'run --rm --network dune-net --entrypoint getent localhost/dune-orchestrator:dev'; then
  echo "FAIL: the probe container must run on dune-net from the localhost/-prefixed image" >&2
  fake_engine_calls | sed 's/^/      /' >&2
  failures=$((failures + 1))
fi
fake_engine_stop

use_engine podman
fake_engine_respond ps <<'OUT'
dune-postgres
dune-text-router
OUT
fake_engine_respond run </dev/null
out="$(check_bridge_dns 2>&1)"
assert_contains "$out" "FAIL Bridge name resolution failed: dune-postgres" \
  "an unresolvable database name fails"
assert_contains "$out" "FAIL Bridge name resolution failed: dune-text-router" \
  "an unresolvable text-router name fails"
assert_contains "$out" "aardvark-dns" \
  "the Podman failure names the missing DNS backend"
fake_engine_stop

use_engine podman
fake_engine_exit_status "network inspect" 1
out="$(check_bridge_dns 2>&1)"
assert_contains "$out" "WARN Bridge name resolution not checked" \
  "a missing bridge is reported as unchecked"
assert_missing "$out" "OK   Bridge name resolution" \
  "a check that could not run must never report success"
fake_engine_stop

# --- 5.28: the field both argv readers use --------------------------------

use_engine podman
fake_engine_respond ps <<'OUT'
dune-server-gateway
dune-server-survival-1
OUT
fake_engine_respond inspect <<'OUT'
/opt/dune-local/run-server.sh
Hagga_Basin
-ini:engine:[URL]:IGWPort=27020
OUT
out="$(check_game_container_argv 2>&1)"
assert_contains "$out" "OK   Game server arguments are readable from .Config.Cmd (dune-server-survival-1)" \
  "argv read from .Config.Cmd passes, and the gateway is skipped"
fake_engine_stop

use_engine podman
fake_engine_respond ps <<'OUT'
dune-server-survival-1
OUT
fake_engine_respond inspect </dev/null
out="$(check_game_container_argv 2>&1)"
assert_contains "$out" "FAIL Game server arguments are not readable from .Config.Cmd" \
  "an engine that files argv elsewhere is reported, not ignored"
fake_engine_stop

# --- 5.19: generated units ordered against the wrong engine ---------------

use_engine docker
out="$(check_generated_unit_engine_ordering 2>&1)"
assert_contains "$out" "OK   All installed generated units order after docker.service" \
  "a unit ordered against this host's engine passes"
fake_engine_stop

use_engine podman
out="$(check_generated_unit_engine_ordering 2>&1)"
assert_contains "$out" "WARN dune-awakening-shutdown-protection.service does not order after podman.socket" \
  "a unit left behind from the other engine is reported"
fake_engine_stop

# --- 5.4: the Compose provider --------------------------------------------

use_engine podman
fake_engine_respond "compose version" <<'OUT'
podman-compose version 1.0.6
OUT
out="$(check_podman_host_tools 2>&1)"
assert_contains "$out" "FAIL docker compose resolves to something other than the Compose v2 plugin" \
  "podman-compose is rejected"
assert_contains "$out" "com.docker.compose.* labels" \
  "the rejection says why it matters"
fake_engine_stop

use_engine podman
fake_engine_respond "compose version" <<'OUT'
Docker Compose version v2.29.7
OUT
out="$(check_podman_host_tools 2>&1)"
assert_contains "$out" "OK   Docker Compose v2 available" \
  "the real Compose v2 plugin is accepted"
fake_engine_stop

if [ "$failures" -ne 0 ]; then
  echo "doctor engine checks: $failures failure(s)" >&2
  exit 1
fi
echo "OK: doctor's engine-aware checks assert or abstain, never pass vacuously"
