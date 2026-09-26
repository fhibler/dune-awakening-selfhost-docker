#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${DUNE_RUNTIME_PERMISSIONS_REPAIRED:-0}" != "1" ]; then
  runtime/scripts/repair-host-runtime-permissions.sh
  export DUNE_RUNTIME_PERMISSIONS_REPAIRED=1
fi

[ -f .env ] && . ./.env
source runtime/scripts/host-paths.sh
source runtime/scripts/lib/engine.sh

CONTAINER_NAME="dune-autoscaler"
IMAGE="dune-orchestrator:dev"
REPO_UID="$(stat -c '%u' .)"
REPO_GID="$(stat -c '%g' .)"
HOST_UID="${DUNE_HOST_UID:-$REPO_UID}"
HOST_GID="${DUNE_HOST_GID:-$REPO_GID}"
DOCKER_SOCK_GID="${DOCKER_SOCKET_GID:-}"
AUTOSCALER_CONTAINER_REPO_ROOT="/repo"
HOST_REPO_ROOT="$(host_path "$PWD")"

if [ "$HOST_UID" = "0" ] && [ "$REPO_UID" != "0" ]; then
  HOST_UID="$REPO_UID"
fi
if [ "$HOST_GID" = "0" ] && [ "$REPO_GID" != "0" ]; then
  HOST_GID="$REPO_GID"
fi

if [ -z "$DOCKER_SOCK_GID" ] && [ -S /var/run/docker.sock ]; then
  DOCKER_SOCK_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
fi

mkdir -p runtime/generated runtime/logs

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Autoscaler already running: $CONTAINER_NAME"
  exit 0
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

if ! docker ps --format '{{.Names}}' | grep -qx dune-director; then
  echo "Cannot start autoscaler: dune-director is not running."
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx dune-postgres; then
  echo "Cannot start autoscaler: dune-postgres is not running."
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Cannot start autoscaler: Docker image not found: $IMAGE"
  echo "Start or build the orchestrator first:"
  echo "  docker compose up -d --build orchestrator"
  exit 1
fi

echo "Starting autoscaler container..."
group_args=()
if [ -n "$DOCKER_SOCK_GID" ]; then
  group_args+=(--group-add "$DOCKER_SOCK_GID")
fi

docker run -d \
  "${DUNE_DOCKER_LOG_ARGS[@]}" \
  --name "$CONTAINER_NAME" \
  --network host \
  --restart "$DUNE_ENGINE_RESTART_POLICY" \
  --user "${HOST_UID}:${HOST_GID}" \
  "${group_args[@]}" \
  --entrypoint bash \
  -e "DUNE_CONTAINER_REPO_ROOT=$AUTOSCALER_CONTAINER_REPO_ROOT" \
  -e "DUNE_HOST_REPO_ROOT=$HOST_REPO_ROOT" \
  -v "$(dune_engine_mount /var/run/docker.sock /var/run/docker.sock)" \
  -v "$(dune_engine_mount "$HOST_REPO_ROOT" "$AUTOSCALER_CONTAINER_REPO_ROOT")" \
  -w "$AUTOSCALER_CONTAINER_REPO_ROOT" \
  "$IMAGE" \
  runtime/scripts/autoscaler.sh >/dev/null

echo "Autoscaler started: $CONTAINER_NAME"
echo "Logs:"
echo "  dune autoscaler logs"
