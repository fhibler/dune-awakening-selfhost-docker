#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
[ -f .env ] && . ./.env
# shellcheck source=runtime/scripts/lib/engine.sh
source runtime/scripts/lib/engine.sh

HOST_SWAP_FILE="/var/lib/dune-awakening/swapfile"

# Splice into the privileged helper that binds /:/host and chroots into it:
# that mount must never be relabelled. See dune_engine_label_disable_args in
# lib/engine.sh. Empty on Docker. memory-swap.sh does not source
# runtime-env.sh, which builds the same array for the scripts that do.
DUNE_ENGINE_LABEL_DISABLE_ARGS=()
if [ -n "$(dune_engine_label_disable_args)" ]; then
  DUNE_ENGINE_LABEL_DISABLE_ARGS=(--security-opt label=disable)
fi

env_value() {
  awk -F= -v key="$1" '$1 == key { print substr($0, length(key) + 2); exit }' .env 2>/dev/null || true
}

set_env_value() {
  local key="$1" value="$2" tmp
  touch .env
  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    $0 ~ "^" key "=" { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' .env > "$tmp"
  mv "$tmp" .env
  chmod 644 .env
}

world_server_count() {
  local count
  count="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -Ec '^dune-server-(survival|overmap|deepdesert|sh-|cb-|story-|dlc-)' || true)"
  [ "$count" -ge 2 ] || count=2
  echo "$count"
}

existing_non_project_swap_gib() {
  awk -v managed="$HOST_SWAP_FILE" 'NR > 1 && $1 != managed { total += $3 } END { printf "%d\n", int((total + 1048575) / 1048576) }' /proc/swaps 2>/dev/null || echo 0
}

recommended_pool_gib() {
  local allowance="$1" count existing recommended
  count="$(world_server_count)"
  existing="$(existing_non_project_swap_gib)"
  recommended=$((allowance * count - existing))
  [ "$recommended" -ge 0 ] || recommended=0
  [ "$recommended" -le 32 ] || recommended=32
  echo "$recommended"
}

host_helper() {
  local action="$1" image host_root
  shift
  if [ "$(id -u)" -eq 0 ] && [ -x runtime/scripts/memory-swap-host.sh ]; then
    runtime/scripts/memory-swap-host.sh "$action" "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1 && [ -t 0 ] && sudo -v; then
    sudo runtime/scripts/memory-swap-host.sh "$action" "$@"
    return
  fi
  command -v docker >/dev/null 2>&1 || { echo "Docker is required to manage host swap from the Console." >&2; exit 1; }
  image="${DUNE_SYSTEMD_HELPER_IMAGE:-redblink-dune-docker-console:dev}"
  host_root="${DUNE_HOST_REPO_ROOT:-$(pwd -P)}"
  docker image inspect "$image" >/dev/null 2>&1 || { echo "Console helper image not found: $image" >&2; exit 1; }
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${DUNE_ENGINE_LABEL_DISABLE_ARGS[@]}" \
    -v /:/host \
    --entrypoint chroot \
    "$image" /host "$host_root/runtime/scripts/memory-swap-host.sh" "$action" "$@"
}

apply_container_allowance() {
  local allowance_gib="$1" container memory_bytes memory_mib swap_mib
  command -v docker >/dev/null 2>&1 || return 0
  while IFS= read -r container; do
    [ -n "$container" ] || continue
    memory_bytes="$(docker inspect "$container" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)"
    printf '%s' "$memory_bytes" | grep -Eq '^[1-9][0-9]*$' || continue
    memory_mib=$(((memory_bytes + 1024 * 1024 - 1) / 1024 / 1024))
    if [ "$allowance_gib" -gt 0 ]; then
      swap_mib=$((memory_mib + allowance_gib * 1024))
    else
      # Restore Docker's pre-feature default: swap allowance equals RAM.
      swap_mib=$((memory_mib * 2))
    fi
    docker update --memory-swap "${swap_mib}m" "$container" >/dev/null
    if [ "$allowance_gib" -gt 0 ]; then
      echo "Applied ${allowance_gib} GiB swap allowance to $container."
    else
      echo "Restored Docker's default swap allowance for $container."
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep '^dune-server-' || true)
}

show_status() {
  local enabled allowance pool configured_swappiness running existing total_mem free_kib total_kib managed_kib reserve_kib safe_available recommendation count swappiness
  enabled="$(env_value DUNE_MEMORY_SWAP_ENABLED)"; enabled="${enabled:-0}"
  allowance="$(env_value DUNE_MEMORY_SWAP_PER_SERVER_GIB)"; allowance="${allowance:-2}"
  pool="$(env_value DUNE_MEMORY_SWAP_POOL_GIB)"; pool="${pool:-0}"
  configured_swappiness="$(env_value DUNE_MEMORY_SWAP_SWAPPINESS)"; configured_swappiness="${configured_swappiness:-10}"
  running="$(awk -v file="$HOST_SWAP_FILE" 'NR > 1 && $1 == file { print 1; found = 1 } END { if (!found) print 0 }' /proc/swaps 2>/dev/null)"
  existing="$(existing_non_project_swap_gib)"
  total_mem="$(awk '/^MemTotal:/ { printf "%d", int(($2 + 1048575) / 1048576) }' /proc/meminfo)"
  read -r total_kib free_kib < <(df -Pk . | awk 'NR == 2 { print $2, $4 }')
  managed_kib="$(awk -v file="$HOST_SWAP_FILE" 'NR > 1 && $1 == file { print $3; found = 1 } END { if (!found) print 0 }' /proc/swaps 2>/dev/null)"
  reserve_kib=$((25 * 1024 * 1024)); [ $((total_kib / 10)) -le "$reserve_kib" ] || reserve_kib=$((total_kib / 10))
  safe_available=$(((free_kib + managed_kib - reserve_kib) / 1024 / 1024)); [ "$safe_available" -ge 0 ] || safe_available=0
  recommendation="$(recommended_pool_gib "$allowance")"
  count="$(world_server_count)"
  swappiness="$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)"
  cat <<EOF
enabled=$enabled
host_pool_active=$running
pool_gib=$pool
per_server_gib=$allowance
recommended_pool_gib=$recommendation
world_server_count=$count
existing_swap_gib=$existing
physical_memory_gib=$total_mem
safe_available_disk_gib=$safe_available
swappiness=$swappiness
configured_swappiness=$configured_swappiness
swap_file=$HOST_SWAP_FILE
EOF
}

enable_swap() {
  local allowance="${1:-2}" pool="${2:-}" swappiness="${3:-10}"
  if ! printf '%s' "$allowance" | grep -Eq '^[1-9][0-9]*$' || [ "$allowance" -gt 16 ]; then echo "Per-server swap must be 1-16 GiB." >&2; exit 2; fi
  [ -n "$pool" ] || pool="$(recommended_pool_gib "$allowance")"
  if ! printf '%s' "$pool" | grep -Eq '^[0-9]+$' || [ "$pool" -gt 32 ]; then echo "Host swap pool must be 0-32 GiB." >&2; exit 2; fi
  if ! printf '%s' "$swappiness" | grep -Eq '^[0-9]+$' || [ "$swappiness" -gt 100 ]; then echo "Swappiness must be 0-100." >&2; exit 2; fi
  host_helper enable "$pool" "$swappiness"
  if [ "$pool" -eq 0 ]; then
    echo "Existing administrator-managed host swap is sufficient; no project swap file is required."
  fi
  set_env_value DUNE_MEMORY_SWAP_ENABLED 1
  set_env_value DUNE_MEMORY_SWAP_PER_SERVER_GIB "$allowance"
  set_env_value DUNE_MEMORY_SWAP_POOL_GIB "$pool"
  set_env_value DUNE_MEMORY_SWAP_SWAPPINESS "$swappiness"
  apply_container_allowance "$allowance"
  echo "Each running, newly started, or rebalanced world server may use up to ${allowance} GiB of emergency swap. Host swappiness is ${swappiness}."
}

disable_swap() {
  apply_container_allowance 0
  host_helper disable
  set_env_value DUNE_MEMORY_SWAP_ENABLED 0
  set_env_value DUNE_MEMORY_SWAP_PER_SERVER_GIB 0
  set_env_value DUNE_MEMORY_SWAP_POOL_GIB 0
  set_env_value DUNE_MEMORY_SWAP_SWAPPINESS 10
}

case "${1:-status}" in
  status) show_status ;;
  enable) enable_swap "${2:-2}" "${3:-}" "${4:-10}" ;;
  disable) disable_swap ;;
  *) echo "Usage: dune memory-swap status | enable [per-server-gib] [pool-gib] [swappiness] | disable" >&2; exit 2 ;;
esac
