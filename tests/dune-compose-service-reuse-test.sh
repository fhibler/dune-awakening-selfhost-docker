#!/usr/bin/env bash
# `dune start` must not rebuild a Compose service that is already up.
#
# The orchestrator service runs as a container named dune-orchestrator, so the
# old `docker ps | grep -qx orchestrator` guard never matched and every start
# rebuilt the image. The replacement resolves the container through its
# com.docker.compose.* labels, which is also the only resolution that survives
# the move to Podman -- container naming is engine-dependent, the labels are
# not.
set -euo pipefail

cd "$(dirname "$0")/.."

dune_cli="runtime/scripts/dune"
bash -n "$dune_cli"

# shellcheck source=runtime/scripts/compose-project.sh
. runtime/scripts/compose-project.sh
# shellcheck source=tests/lib/fake-engine.sh
. tests/lib/fake-engine.sh

# The shipped function body, lifted out of the CLI by name: sourcing the whole
# dispatcher would run a command.
eval "$(awk '
  $0 == "start_compose_service_if_available() {" { inside = 1 }
  inside { print }
  inside && $0 == "}" { inside = 0 }
' "$dune_cli")"

failures=0
DUNE_COMPOSE_PROJECT_NAME=dune-awakening-selfhost-docker

check() {
  local description="$1"
  shift
  if ! "$@"; then
    echo "FAIL: $description" >&2
    fake_engine_calls | sed 's/^/      /' >&2
    failures=$((failures + 1))
  fi
}

check_not() {
  local description="$1"
  shift
  if "$@"; then
    echo "FAIL: $description" >&2
    fake_engine_calls | sed 's/^/      /' >&2
    failures=$((failures + 1))
  fi
}

# A running orchestrator: the service must be left alone.
fake_engine_start docker
fake_engine_respond compose <<'OUT'
orchestrator
OUT
fake_engine_respond ps <<'OUT'
dune-orchestrator
OUT
start_compose_service_if_available docker-compose.yml orchestrator >/dev/null
check "the running service is resolved by its Compose labels" \
  fake_engine_called_with 'ps .*--filter label=com.docker.compose.project=dune-awakening-selfhost-docker .*--filter label=com.docker.compose.service=orchestrator'
check_not "a service that is already up is not rebuilt" \
  fake_engine_called_with 'up -d --build'
fake_engine_stop

# Nothing running: the service must still be brought up.
fake_engine_start docker
fake_engine_respond compose <<'OUT'
orchestrator
OUT
fake_engine_respond ps </dev/null
start_compose_service_if_available docker-compose.yml orchestrator >/dev/null
check "a service that is not up is still started" \
  fake_engine_called_with 'compose -f docker-compose.yml up -d --build orchestrator'
fake_engine_stop

# The same resolution has to work on Podman, where the container naming the
# old guard relied on is not guaranteed in the first place.
fake_engine_start podman
fake_engine_respond compose <<'OUT'
orchestrator
OUT
fake_engine_respond ps <<'OUT'
dune-orchestrator
OUT
start_compose_service_if_available docker-compose.yml orchestrator >/dev/null
check_not "the label resolution also short-circuits the rebuild on Podman" \
  fake_engine_called_with 'up -d --build'
fake_engine_stop

if [ "$failures" -ne 0 ]; then
  echo "dune compose service reuse: $failures failure(s)" >&2
  exit 1
fi
echo "OK: dune start reuses a running Compose service on both engines"
