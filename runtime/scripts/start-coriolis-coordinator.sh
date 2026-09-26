#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

START_MODE="${1:-}"
if [ -n "$START_MODE" ] && [ "$START_MODE" != "--if-stack-running" ] && [ "$START_MODE" != "--replace-if-stack-running" ]; then
  echo "Usage: $0 [--if-stack-running|--replace-if-stack-running]" >&2
  exit 2
fi
if [ -n "$START_MODE" ] && ! docker ps --format '{{.Names}}' 2>/dev/null \
  | grep -Eq '^(dune-orchestrator|dune-autoscaler|dune-director|dune-server-gateway|dune-server-survival-1|dune-server-overmap)$'; then
  echo "Coriolis Coordinator startup skipped because the Battlegroup is stopped."
  exit 0
fi

if [ "${DUNE_RUNTIME_PERMISSIONS_REPAIRED:-0}" != "1" ]; then
  runtime/scripts/repair-host-runtime-permissions.sh
  export DUNE_RUNTIME_PERMISSIONS_REPAIRED=1
fi

[ -f .env ] && . ./.env
source runtime/scripts/host-paths.sh
source runtime/scripts/runtime-env.sh

CONTAINER_NAME="dune-coriolis-coordinator"
IMAGE="dune-orchestrator:dev"
REPO_UID="$(stat -c '%u' .)"
REPO_GID="$(stat -c '%g' .)"
HOST_UID="${DUNE_HOST_UID:-$REPO_UID}"
HOST_GID="${DUNE_HOST_GID:-$REPO_GID}"
DOCKER_SOCK_GID="${DOCKER_SOCKET_GID:-}"
CONTAINER_REPO_ROOT="/repo"
HOST_REPO_ROOT="$(host_path "$PWD")"

if [ "${DUNE_CORIOLIS_COORDINATOR_ENABLED:-1}" = "0" ]; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  echo "Coriolis Coordinator is disabled."
  exit 0
fi
if [ "$HOST_UID" = "0" ] && [ "$REPO_UID" != "0" ]; then HOST_UID="$REPO_UID"; fi
if [ "$HOST_GID" = "0" ] && [ "$REPO_GID" != "0" ]; then HOST_GID="$REPO_GID"; fi
if [ -z "$DOCKER_SOCK_GID" ] && [ -S /var/run/docker.sock ]; then
  DOCKER_SOCK_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
fi

mkdir -p runtime/generated runtime/logs
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  if [ "$START_MODE" = "--replace-if-stack-running" ]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    echo "Coriolis Coordinator already running: $CONTAINER_NAME"
    exit 0
  fi
fi
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Cannot start Coriolis coordinator: Docker image not found: $IMAGE" >&2
  exit 1
}

group_args=()
if [ -n "$DOCKER_SOCK_GID" ]; then group_args+=(--group-add "$DOCKER_SOCK_GID"); fi

docker run -d \
  "${DUNE_DOCKER_LOG_ARGS[@]}" \
  --name "$CONTAINER_NAME" \
  --network host \
  --restart "$DUNE_ENGINE_RESTART_POLICY" \
  --user "${HOST_UID}:${HOST_GID}" \
  "${group_args[@]}" \
  --entrypoint bash \
  -e "DUNE_CONTAINER_REPO_ROOT=$CONTAINER_REPO_ROOT" \
  -e "DUNE_HOST_REPO_ROOT=$HOST_REPO_ROOT" \
  -e "DUNE_HOST_UID=$HOST_UID" \
  -e "DUNE_HOST_GID=$HOST_GID" \
  -e "DUNE_CORIOLIS_SAFE_DATA_CLEANUP=${DUNE_CORIOLIS_SAFE_DATA_CLEANUP:-1}" \
  -e DUNE_RUNTIME_PERMISSIONS_REPAIRED=1 \
  -v "$(dune_engine_mount /var/run/docker.sock /var/run/docker.sock)" \
  -v "$(dune_engine_mount "$HOST_REPO_ROOT" "$CONTAINER_REPO_ROOT")" \
  -w "$CONTAINER_REPO_ROOT" \
  "$IMAGE" \
  runtime/scripts/coriolis-coordinator.sh monitor >/dev/null

# `docker run -d` only confirms that Docker created the container. Catch an
# immediate runtime failure here so deployments and updates do not report a
# successful coordinator start while the Console shows it as failed.
sleep 1
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Coriolis Coordinator exited during startup." >&2
  docker logs --tail 40 "$CONTAINER_NAME" >&2 2>/dev/null || true
  exit 1
fi

echo "Coriolis Coordinator started: $CONTAINER_NAME"
