#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

# shellcheck source=runtime/scripts/lib/engine.sh
. runtime/scripts/lib/engine.sh

usage() {
  cat <<'EOF'
Usage:
  dune storage status
  dune storage cleanup [--dry-run] [--build-cache]

The default cleanup removes only obsolete Funcom/Dune game images. It never
removes containers, volumes, databases, game files, or backups.

--build-cache also removes unused build cache. The engine protects cache used
by active builds, but the builder is shared, so this option can affect build
cache from other projects on the same host.
EOF
}

require_docker() {
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    # Naming Docker here would send an operator to install a second engine.
    command -v docker >/dev/null 2>&1 \
      || { echo "The Docker CLI is not installed; Podman hosts still need it to talk to $DUNE_ENGINE_SOCKET." >&2; exit 1; }
    docker info >/dev/null 2>&1 \
      || { echo "Podman's Docker-compatible API at $DUNE_ENGINE_SOCKET is not reachable." >&2; exit 1; }
    return
  fi
  command -v docker >/dev/null 2>&1 || { echo "Docker is not installed." >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker daemon is not reachable." >&2; exit 1; }
}

current_image_refs() {
  local world_tag="" postgres_tag=""
  if [ -r runtime/generated/image-tags.env ]; then
    # shellcheck disable=SC1091
    . runtime/generated/image-tags.env
    world_tag="${DUNE_WORLD_IMAGE_TAG:-}"
    postgres_tag="${DUNE_POSTGRES_IMAGE_TAG:-}"
  fi

  if [ -n "$world_tag" ]; then
    printf '%s:%s\n' \
      registry.funcom.com/funcom/self-hosting/seabass-server "$world_tag" \
      registry.funcom.com/funcom/self-hosting/seabass-server-bg-director "$world_tag" \
      registry.funcom.com/funcom/self-hosting/seabass-server-db-utils "$world_tag" \
      registry.funcom.com/funcom/self-hosting/seabass-server-gateway "$world_tag" \
      registry.funcom.com/funcom/self-hosting/seabass-server-rabbitmq "$world_tag" \
      registry.funcom.com/funcom/self-hosting/seabass-server-text-router "$world_tag"
  fi
  if [ -n "$postgres_tag" ]; then
    printf '%s:%s\n' registry.funcom.com/funcom/self-hosting/igw-postgres "$postgres_tag"
  fi

  # These tags are operational dependencies even when the containers currently
  # using their older image IDs are still running. Startup and host-side repair
  # scripts launch short-lived helpers from these exact references.
  #
  # The prefix matters: Podman stores a locally built image as
  # localhost/<name>, and an unqualified name that does not resolve leaves the
  # image out of the protected set below -- which is the set that keeps
  # cleanup from removing an image the stack still launches helpers from.
  printf '%s\n' \
    "${DUNE_ENGINE_IMAGE_PREFIX}dune-orchestrator:dev" \
    "${DUNE_ENGINE_IMAGE_PREFIX}redblink-dune-docker-console:dev"
}

# The protection set is built from container .Image and image .Id, then matched
# whole-line against `image ls --no-trunc`. Docker prefixes all three with
# `sha256:`; Podman's compat endpoints are not consistent about it, and a
# single bare digest silently drops an in-use image out of the protected set.
# Compare the bare digests so the three sides cannot disagree on either engine.
protected_image_ids() {
  local container ref id

  while IFS= read -r container; do
    [ -n "$container" ] || continue
    id="$(docker inspect --format '{{.Image}}' "$container" 2>/dev/null || true)"
    [ -n "$id" ] && printf '%s\n' "$(dune_engine_normalize_digest "$id")"
  done < <(docker container ls -aq)

  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    id="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true)"
    [ -n "$id" ] && printf '%s\n' "$(dune_engine_normalize_digest "$id")"
  done < <(current_image_refs)
  return 0
}

cleanup_candidate_images() {
  docker image ls --no-trunc --format '{{.Repository}}|{{.Tag}}|{{.ID}}'
  docker image ls --no-trunc \
    --filter label=io.github.red-blink.dune-selfhost.component \
    --format '{{.Repository}}|{{.Tag}}|{{.ID}}'
}

obsolete_dune_image_ids() {
  local protected_file id repo tag
  declare -A seen=()
  protected_file="$(mktemp)"
  protected_image_ids | sort -u > "$protected_file"

  while IFS='|' read -r repo tag id; do
    case "$repo" in
      registry.funcom.com/funcom/self-hosting/igw-postgres|\
      registry.funcom.com/funcom/self-hosting/seabass-server|\
      registry.funcom.com/funcom/self-hosting/seabass-server-bg-director|\
      registry.funcom.com/funcom/self-hosting/seabass-server-db-utils|\
      registry.funcom.com/funcom/self-hosting/seabass-server-gateway|\
      registry.funcom.com/funcom/self-hosting/seabass-server-rabbitmq|\
      registry.funcom.com/funcom/self-hosting/seabass-server-text-router) ;;
      *)
        if ! docker image inspect --format '{{index .Config.Labels "io.github.red-blink.dune-selfhost.component"}}' "$id" 2>/dev/null \
          | grep -Eq '^(console|orchestrator)$'; then
          continue
        fi
        ;;
    esac
    grep -qxF "$(dune_engine_normalize_digest "$id")" "$protected_file" && continue
    [ -z "${seen[$id]:-}" ] || continue
    seen[$id]=1
    printf '%s|%s:%s\n' "$id" "$repo" "$tag"
  done < <(cleanup_candidate_images)
  rm -f "$protected_file"
}

storage_status() {
  echo "=== Docker storage ==="
  docker system df
  echo
  echo "The reclaimable image figure can include obsolete Funcom releases."
  echo "Use 'dune storage cleanup --dry-run' to list project-owned candidates."
}

cleanup_storage() {
  local dry_run=0 build_cache=0 row id ref removed=0
  local -a prune_cmd=()
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1 ;;
      --build-cache) build_cache=1 ;;
      *) echo "Unknown storage cleanup option: $1" >&2; usage; exit 2 ;;
    esac
    shift
  done

  echo "=== Obsolete Dune game images ==="
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="${row%%|*}"
    ref="${row#*|}"
    if [ "$dry_run" = "1" ]; then
      echo "WOULD REMOVE $ref ($id)"
    elif docker image rm "$id" >/dev/null; then
      echo "REMOVED $ref"
      removed=$((removed + 1))
    else
      echo "SKIPPED $ref (Docker reports it is still in use)"
    fi
  done < <(obsolete_dune_image_ids)

  if [ "$removed" -eq 0 ] && [ "$dry_run" = "0" ]; then
    echo "No obsolete Dune game images were removed."
  fi

  if [ "$build_cache" = "1" ]; then
    echo
    echo "=== Unused Docker build cache ==="
    if [ "$DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE" = "1" ]; then
      prune_cmd=(docker builder prune --force --all)
    else
      # The one divergence where the Docker dialect cannot reach the thing at
      # all. `podman builder prune` does exist (`P2`) -- it is an alias of
      # `podman image prune` -- but the compat API does not implement
      # /build/prune, so `docker builder prune` through the socket answers
      # `Not Found` however the CLI is pointed. The native command is the only
      # way in, and Buildah's store is where the cache actually lives.
      prune_cmd=(podman system prune --build --force)
    fi
    if [ "$dry_run" = "1" ]; then
      echo "WOULD RUN ${prune_cmd[*]}"
    elif ! command -v "${prune_cmd[0]}" >/dev/null 2>&1; then
      echo "SKIPPED: ${prune_cmd[0]} is not available here."
      echo "Run this on the container host: ${prune_cmd[*]}"
    else
      echo "This builder may be shared with other projects on this Docker host."
      "${prune_cmd[@]}"
    fi
  fi
}

require_docker
cmd="${1:-status}"
case "$cmd" in
  status) storage_status ;;
  cleanup) cleanup_storage "$@" ;;
  help|--help|-h) usage ;;
  *) echo "Unknown storage command: $cmd" >&2; usage; exit 2 ;;
esac
