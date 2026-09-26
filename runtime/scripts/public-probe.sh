#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

# The probe image is built here through Compose. On Podman that build has to
# run on the classic builder and may have to reach a socket outside the Docker
# default; the seam exports both. It also supplies the repository prefix the
# engine stores a locally built image under.
# shellcheck source=runtime/scripts/lib/engine.sh
. runtime/scripts/lib/engine.sh

COMPOSE_FILE="docker-compose.public-probe.yml"
HOST_COMPOSE_FILE="docker-compose.public-probe-host.yml"
PROBE_ENV="runtime/generated/public-probe.env"
BUILD_STATE="runtime/generated/public-probe-build.sha256"
CONTAINER="dune-public-probe"
PROJECT="dune-public-probe"

usage() {
  cat <<'EOF'
Usage:
  public-probe.sh reconcile
  public-probe.sh stop
  public-probe.sh status

The public latency probe uses authenticated signaling through dunedocker.app.
Direct measurements use UDP 32000-32015. Permit or forward that range through
the host and upstream firewall for direct results; relay remains available.
EOF
}

load_probe_env() {
  [ -r "$PROBE_ENV" ] || return 1
  # shellcheck disable=SC1090
  . "$PROBE_ENV"
  [ -n "${DUNE_PUBLIC_PROBE_SERVER_ID:-}" ] &&
    [ -n "${DUNE_PUBLIC_PROBE_SECRET:-}" ] &&
    [ -n "${DUNE_PUBLIC_PROBE_SIGNAL_URL:-}" ]
}

compose() {
  local compose_files=(-f "$COMPOSE_FILE")
  if [ "${DUNE_PUBLIC_PROBE_FORCE_BRIDGE:-false}" != "true" ] && use_host_network; then
    compose_files+=(-f "$HOST_COMPOSE_FILE")
  fi
  # --env-file replaces .env rather than adding to it, so the restart policy
  # install.sh persisted there never reaches this project. What does reach it
  # is the seam sourced at the top of this file, which exports the policy into
  # the environment Compose interpolates from. Keep that source.
  DUNE_HOST_REPO_ROOT="${DUNE_HOST_REPO_ROOT:-$(pwd -P)}" \
    COMPOSE_PROJECT_NAME="$PROJECT" \
    docker compose --env-file "$PROBE_ENV" "${compose_files[@]}" "$@"
}

use_host_network() {
  [ "$(uname -s)" = "Linux" ] || return 1
  if [ -r /proc/version ] && grep -Eqi '(microsoft|wsl)' /proc/version; then
    return 1
  fi
  ! docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -qi 'docker desktop'
}

stop_probe() {
  if [ -f "$PROBE_ENV" ]; then
    compose down --remove-orphans
  else
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
}

reconcile_probe() {
  local current_hash saved_hash=""
  if ! load_probe_env; then
    echo "Public probe is waiting for signaling credentials from dunedocker.app." >&2
    exit 2
  fi
  if [ "${DUNE_PUBLIC_PROBE_ENABLED:-false}" != "true" ]; then
    stop_probe
    return
  fi
  current_hash="$(
    sha256sum \
      runtime/public-probe/Dockerfile \
      runtime/public-probe/go.mod \
      runtime/public-probe/go.sum \
      runtime/public-probe/main.go |
      sha256sum |
      awk '{print $1}'
  )"
  [ -r "$BUILD_STATE" ] && saved_hash="$(tr -d '[:space:]' <"$BUILD_STATE")"
  if [ "$current_hash" != "$saved_hash" ] || ! docker image inspect "${DUNE_ENGINE_IMAGE_PREFIX}dune-public-probe:dev" >/dev/null 2>&1; then
    compose build dune-public-probe
    printf '%s\n' "$current_hash" >"$BUILD_STATE"
    chmod 600 "$BUILD_STATE" 2>/dev/null || true
  fi
  if use_host_network; then
    if ! compose up -d; then
      echo "Native Linux LAN discovery is unavailable; falling back to WebRTC compatibility mode." >&2
      DUNE_PUBLIC_PROBE_FORCE_BRIDGE=true compose up -d
    fi
  else
    compose up -d
  fi
}

status_probe() {
  if ! docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "State: disabled"
    return
  fi
  # The nested guard is not redundant: Docker leaves .State.Health nil for a
  # container without a healthcheck, so the outer test is what keeps the
  # template from dereferencing nil; Podman's compat inspect instead returns a
  # non-nil empty object, so without the inner test it would print a bare
  # "health=" for every container.
  docker inspect "$CONTAINER" --format 'State: {{.State.Status}}{{if .State.Health}}{{if .State.Health.Status}} health={{.State.Health.Status}}{{end}}{{end}}'
  if load_probe_env; then
    local network_mode
    echo "Server ID: ${DUNE_PUBLIC_PROBE_SERVER_ID}"
    echo "Signaling: ${DUNE_PUBLIC_PROBE_SIGNAL_URL}"
    network_mode="$(docker inspect "$CONTAINER" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
    if [ "$network_mode" = "host" ]; then
      echo "Network: WebRTC with native Linux LAN discovery"
      echo "Direct UDP: 32000-32015 (optional; relay fallback remains available)"
    else
      echo "Network: outbound-only WebRTC compatibility mode"
    fi
  fi
}

case "${1:-status}" in
  reconcile) reconcile_probe ;;
  stop) stop_probe ;;
  status) status_probe ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
