#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT_DIR="$(pwd)"
HOST_ROOT_DIR="${DUNE_HOST_REPO_ROOT:-$ROOT_DIR}"
[ -f .env ] && . ./.env
[ -r runtime/generated/battlegroup.env ] && . runtime/generated/battlegroup.env
source runtime/scripts/runtime-env.sh
source runtime/scripts/fls-signals.sh

fail=0
warn=0

ok() {
  echo "OK   $*"
}

warn_msg() {
  echo "WARN $*"
  warn=1
}

info_msg() {
  echo "INFO $*"
}

fail_msg() {
  echo "FAIL $*"
  fail=1
}

docker_size_bytes() {
  awk '
    function multiplier(unit) {
      if (unit == "kB" || unit == "KB") return 1000
      if (unit == "MB") return 1000000
      if (unit == "GB") return 1000000000
      if (unit == "TB") return 1000000000000
      if (unit == "KiB") return 1024
      if (unit == "MiB") return 1048576
      if (unit == "GiB") return 1073741824
      if (unit == "TiB") return 1099511627776
      return 1
    }
    {
      number = $0
      sub(/[A-Za-z].*$/, "", number)
      unit = $0
      sub(/^[0-9.]+/, "", unit)
      sub(/[[:space:]].*$/, "", unit)
      if (number ~ /^[0-9]+([.][0-9]+)?$/) {
        printf "%.0f\n", number * multiplier(unit)
      }
    }
  '
}

# Podman's half of the host-tools check. Three things have to hold here that
# come free with Docker Engine: the Docker CLI has to be installed at all to
# reach the compat socket, `docker compose` has to resolve to the real
# Compose v2 plugin, and catatonit has to exist for the Console's init process.
check_podman_host_tools() {
  local compose_version

  if command -v docker >/dev/null 2>&1; then
    ok "Docker CLI found (this host runs Podman behind it)"
  else
    fail_msg "Docker CLI not found"
    echo "     Podman hosts still need it to speak Docker's API: sudo dnf install -y podman-docker"
  fi

  if docker info >/dev/null 2>&1; then
    ok "Podman's Docker-compatible API reachable at $DUNE_ENGINE_SOCKET"
  else
    fail_msg "Podman's Docker-compatible API is not reachable at $DUNE_ENGINE_SOCKET"
    echo "     Enable the socket: sudo systemctl enable --now podman.socket"
    echo "     Then grant your user access: sudo usermod -aG podman \$USER && newgrp podman"
  fi

  # podman-compose is a different program that happens to answer to the same
  # words. It labels containers io.podman.compose.*, and every service lookup
  # in this repo resolves a container by its com.docker.compose.* labels, so
  # it would not fail -- it would silently find nothing, everywhere.
  compose_version="$(docker compose version 2>/dev/null || true)"
  if grep -qiE '^Docker Compose version' <<<"$compose_version"; then
    ok "Docker Compose v2 available"
  elif [ -n "$compose_version" ]; then
    fail_msg "docker compose resolves to something other than the Compose v2 plugin: ${compose_version%%$'\n'*}"
    echo "     This stack finds its containers by com.docker.compose.* labels, which podman-compose does not write."
    echo "     Install the real plugin: sudo dnf install -y docker-compose-plugin"
  else
    fail_msg "Docker Compose is not available"
    echo "     Install Docker Compose v2."
  fi

  # docker-compose.web.yml sets init: true. Docker ships its init binary inside
  # the engine package; Podman execs /usr/libexec/podman/catatonit from a
  # package that is only a weak dependency, and without it container creation
  # fails with an error that reads nothing like a missing package.
  if [ -x /usr/libexec/podman/catatonit ] || command -v catatonit >/dev/null 2>&1; then
    ok "catatonit available for the Console's init process"
  else
    fail_msg "catatonit is not installed"
    echo "     The Console container sets init: true and Podman cannot create it without catatonit: sudo dnf install -y catatonit"
  fi
}

# The stack calls the Docker CLI on both engines, so the probes are the same
# either way -- but the remediation is not, and this is the text an operator
# reads exactly when they are already stuck. The Docker branch is untouched so
# doctor's output on a Docker host does not move.
check_host_tools() {
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    check_podman_host_tools
    return
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker command found"
    if docker info >/dev/null 2>&1; then
      ok "Docker daemon reachable"
    else
      fail_msg "Docker daemon is not reachable"
      echo "     Start Docker and make sure your user can access /var/run/docker.sock."
    fi
  else
    fail_msg "Docker command not found"
    echo "     Install Docker Engine."
  fi

  if docker compose version >/dev/null 2>&1; then
    ok "Docker Compose available"
  else
    fail_msg "Docker Compose is not available"
    echo "     Install Docker Compose v2."
  fi
}

check_docker_storage() {
  local rows obsolete_output obsolete_count=0 cache_reclaim="0B" cache_bytes=0
  rows="$(docker system df --format '{{.Type}}|{{.Reclaimable}}' 2>/dev/null || true)"
  [ -n "$rows" ] || { warn_msg "Docker storage usage could not be inspected"; return; }

  obsolete_output="$(runtime/scripts/storage.sh cleanup --dry-run 2>/dev/null || true)"
  obsolete_count="$(grep -c '^WOULD REMOVE ' <<<"$obsolete_output" || true)"
  obsolete_count="${obsolete_count:-0}"

  if [ "$obsolete_count" -gt 0 ]; then
    warn_msg "Docker has ${obsolete_count} obsolete project-owned image(s) that can be cleaned"
    echo "     Preview project-owned cleanup: dune storage cleanup --dry-run"
  else
    ok "No obsolete project-owned Docker images found"
  fi

  # Podman's `system df` has Images, Containers and Local Volumes but no Build
  # Cache row at all, so the awk below would read empty, default to 0B, and
  # report a reassuring figure about a cache it never inspected. An engine
  # whose build cache cannot be pruned from here has nothing to say about it.
  if [ "$DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE" != "1" ]; then
    return
  fi

  cache_reclaim="$(awk -F'|' '$1 == "Build Cache" { print $2; exit }' <<<"$rows")"
  cache_bytes="$(docker_size_bytes <<<"${cache_reclaim:-0B}")"
  cache_bytes="${cache_bytes:-0}"
  if [ "$cache_bytes" -ge 10000000000 ]; then
    warn_msg "Docker has ${cache_reclaim} of reclaimable build cache"
    echo "     On a dedicated host: dune storage cleanup --build-cache"
  else
    ok "Reclaimable Docker build cache: ${cache_reclaim:-0B}"
  fi
}

tcp_socket_listening() {
  local port="$1"
  local sockets
  sockets="$(ss -lntp 2>/dev/null || true)"
  grep -q ":$port " <<<"$sockets"
}

udp_socket_listening() {
  local port="$1"
  local sockets
  sockets="$(ss -lnup 2>/dev/null || true)"
  grep -q ":$port " <<<"$sockets"
}

is_running() {
  local name="$1"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"
}

check_file() {
  local file="$1"
  local label="$2"
  local hint="$3"

  if [ -s "$file" ]; then
    ok "$label"
  else
    fail_msg "$label missing"
    echo "     $hint"
  fi
}

check_tcp() {
  local port="$1"
  local label="$2"

  if tcp_socket_listening "$port"; then
    ok "$label listening on TCP $port"
  else
    fail_msg "$label not listening on TCP $port"
  fi
}

check_udp() {
  local port="$1"
  local label="$2"

  if udp_socket_listening "$port"; then
    ok "$label listening on UDP $port"
  else
    fail_msg "$label not listening on UDP $port"
  fi
}

is_wsl_host() {
  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null
}

check_game_container_pinning() {
  local container
  local cpuset
  local found=0

  command -v docker >/dev/null 2>&1 || return 0

  while IFS= read -r container; do
    [ -n "$container" ] || continue
    [ "$container" = "dune-server-gateway" ] && continue
    cpuset="$(docker inspect -f '{{.HostConfig.CpusetCpus}}' "$container" 2>/dev/null || true)"
    if [ -n "$cpuset" ] && [ "$cpuset" != "<no value>" ]; then
      warn_msg "Game container CPU pinning detected: $container cpuset=$cpuset"
      found=1
    fi
  done < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^dune-server-' || true)

  if [ "$found" -eq 0 ]; then
    ok "No active game container CPU pinning detected"
  fi
}

# Twenty call sites address a peer by container name: both RabbitMQ brokers
# authenticate every client against http://dune-text-router:5059, and the
# gateway, director and text router all reach the database as dune-postgres.
# Docker's embedded resolver is unconditional on a user-defined bridge;
# Podman delegates to netavark plus aardvark-dns, a weak dependency gated per
# network by a flag the Docker compat API cannot set. Either way the failure
# is an NXDOMAIN at runtime, long after the network was created without
# complaint, so the only honest check is to resolve the names from the bridge.
check_bridge_dns() {
  local image="${DUNE_ENGINE_IMAGE_PREFIX}dune-orchestrator:dev"
  local resolved name missing=0

  command -v docker >/dev/null 2>&1 || return 0
  if ! docker network inspect dune-net >/dev/null 2>&1; then
    warn_msg "Bridge name resolution not checked: the dune-net network does not exist yet"
    echo "     Try: dune start"
    return
  fi
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    warn_msg "Bridge name resolution not checked: $image has not been built yet"
    echo "     Try: dune start"
    return
  fi
  for name in dune-postgres dune-text-router; do
    if ! is_running "$name"; then
      warn_msg "Bridge name resolution not checked: $name is not running, so it has no name to resolve"
      return
    fi
  done

  resolved="$(docker run --rm --network dune-net --entrypoint getent "$image" \
    hosts dune-postgres dune-text-router 2>/dev/null || true)"
  for name in dune-postgres dune-text-router; do
    if ! grep -qw -- "$name" <<<"$resolved"; then
      fail_msg "Bridge name resolution failed: $name does not resolve from dune-net"
      missing=1
    fi
  done
  if [ "$missing" -eq 0 ]; then
    ok "Bridge name resolution works for dune-postgres and dune-text-router"
    return
  fi
  echo "     Every RabbitMQ client is authorised through http://dune-text-router:5059, so no player can connect while this fails."
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    echo "     Install the DNS backend, then recreate the bridge: sudo dnf install -y netavark aardvark-dns"
    echo "     Then: dune stop && docker network rm dune-net && dune start"
  fi
}

# ping-diagnostics.sh and autoscaler.sh both read a game server's port
# arguments out of the same container, and both read them from .Config.Cmd.
# Docker fills .Path and .Args as well and all three agree; Podman's compat
# inspect derives them from the entrypoint differently and can leave .Args
# empty. Assert the field the two readers actually use carries the arguments,
# so an engine that files them elsewhere surfaces here rather than as two
# tools quietly disagreeing about one server.
check_game_container_argv() {
  local container cmd args

  command -v docker >/dev/null 2>&1 || return 0
  container="$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '^dune-server-' | grep -vx 'dune-server-gateway' | head -n1 || true)"
  if [ -z "$container" ]; then
    info_msg "No game server container is running; container argument reporting was not checked"
    return
  fi

  cmd="$(docker inspect "$container" --format '{{range .Config.Cmd}}{{println .}}{{end}}' 2>/dev/null || true)"
  if grep -q -- '-ini:engine:' <<<"$cmd"; then
    ok "Game server arguments are readable from .Config.Cmd ($container)"
    return
  fi

  fail_msg "Game server arguments are not readable from .Config.Cmd on $container"
  echo "     The autoscaler and 'dune ping' both read the port arguments from this field, so both will misreport this server."
  args="$(docker inspect "$container" --format '{{range .Args}}{{println .}}{{end}}' 2>/dev/null || true)"
  if grep -q -- '-ini:engine:' <<<"$args"; then
    echo "     This engine reports them under .Args instead."
  fi
}

check_deepdesert_mode() {
  local mode

  [ -x runtime/scripts/map-modes.sh ] || return 0
  mode="$(runtime/scripts/map-modes.sh mode DeepDesert_1 2>/dev/null | awk 'NF { print $NF; exit }' || true)"

  if [ "$mode" = "always-on" ]; then
    info_msg "DeepDesert_1 is always-on; ensure the host has enough dedicated headroom for vehicle timing"
  elif [ -n "$mode" ]; then
    ok "DeepDesert_1 map mode: $mode"
  fi
}

check_always_on_memory_safety() {
  local configured recommended total available swap_free reserve
  local status blocked_rows line map available_gib required_gib requested_gib reserve_gib

  if [ ! -x runtime/scripts/host-memory-safety.sh ]; then
    warn_msg "Always-on host-memory safety helper is missing"
    return
  fi

  status="$(runtime/scripts/host-memory-safety.sh status 2>/dev/null || true)"
  if [ -z "$status" ]; then
    warn_msg "Host memory could not be inspected for always-on startup safety"
    return
  fi
  total="$(awk -F= '$1 == "total_gib" { print $2 }' <<<"$status")"
  available="$(awk -F= '$1 == "available_gib" { print $2 }' <<<"$status")"
  swap_free="$(awk -F= '$1 == "swap_free_gib" { print $2 }' <<<"$status")"
  reserve="$(awk -F= '$1 == "reserve_gib" { print $2 }' <<<"$status")"
  recommended="$(awk -F= '$1 == "recommended_parallelism" { print $2 }' <<<"$status")"
  configured="${DUNE_ALWAYS_ON_STARTUP_PARALLELISM:-1}"
  [[ "$configured" =~ ^[1-9][0-9]*$ ]] || configured=1

  if [ "${DUNE_ALWAYS_ON_HOST_MEMORY_SAFETY:-1}" = "0" ]; then
    if [ "$configured" -gt "${recommended:-1}" ]; then
      warn_msg "Always-on host-memory startup protection is disabled while startup parallelism $configured exceeds this host's safe value ${recommended:-1}"
      echo "     Reduce DUNE_ALWAYS_ON_STARTUP_PARALLELISM to ${recommended:-1}, or remove DUNE_ALWAYS_ON_HOST_MEMORY_SAFETY=0 to restore automatic protection. Host: ${total:-?} GiB RAM, ${available:-?} GiB available, ${swap_free:-?} GiB swap free, ${reserve:-?} GiB protected reserve."
    else
      info_msg "Always-on host-memory startup protection is disabled by configuration; startup parallelism $configured is within this host's safe value ${recommended:-1}"
    fi
  elif [ "$configured" -gt "${recommended:-1}" ]; then
    warn_msg "Always-on startup parallelism $configured exceeds this host's safe value ${recommended:-1}"
    echo "     Runtime startup is automatically limited to ${recommended:-1}. Host: ${total:-?} GiB RAM, ${available:-?} GiB available, ${swap_free:-?} GiB swap free, ${reserve:-?} GiB protected reserve."
  else
    ok "Always-on host-memory protection active (parallelism $configured/${recommended:-1}, reserve ${reserve:-?} GiB)"
  fi

  is_running dune-postgres || return
  blocked_rows="$(runtime/scripts/map-modes.sh list 2>/dev/null | grep 'Block: host-memory' || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    map="$(awk '{ print $1 }' <<<"$line")"
    available_gib="$(sed -n 's/.*Block: host-memory available=\([0-9][0-9]*\)GiB.*/\1/p' <<<"$line")"
    required_gib="$(sed -n 's/.* required=\([0-9][0-9]*\)GiB.*/\1/p' <<<"$line")"
    requested_gib="$(sed -n 's/.* requested=\([0-9][0-9]*\)GiB.*/\1/p' <<<"$line")"
    reserve_gib="$(sed -n 's/.* reserve=\([0-9][0-9]*\)GiB.*/\1/p' <<<"$line")"
    warn_msg "Always-on map $map is queued by physical-memory safety (${available_gib:-?} GiB available; ${required_gib:-?} GiB required)"
    echo "     The map needs ${requested_gib:-?} GiB plus a ${reserve_gib:-?} GiB host safety reserve. Swap is emergency headroom and is not used as startup capacity."
  done <<<"$blocked_rows"
}

config_value() {
  local file="$1"
  local key="$2"

  [ -f "$file" ] || return 1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, length(key) + 2)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "$file"
}

check_project_systemd_timers() {
  local timer service label load_state active_state enabled_state working_directory exec_start
  local installed=0 healthy=0
  local auto_update_enabled auto_interval auto_apply auto_notify auto_notify_minutes auto_wait_empty auto_max_wait

  if ! command -v systemctl >/dev/null 2>&1; then
    local auto_status warnings
    auto_status="$(runtime/scripts/update.sh auto status 2>/dev/null || true)"
    warnings="$(grep '^WARN ' <<<"$auto_status" || true)"
    if [ -n "$warnings" ]; then
      while IFS= read -r warning; do
        [ -n "$warning" ] && warn_msg "${warning#WARN }"
      done <<<"$warnings"
    else
      info_msg "Host systemd timer paths cannot be inspected from the Console container; run 'dune doctor' in the host checkout for the complete timer check"
    fi
    return
  fi

  auto_update_enabled="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_ENABLED || true)"
  auto_interval="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_INTERVAL_MINUTES || true)"
  auto_apply="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_APPLY_ENABLED || true)"
  auto_notify="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_NOTIFY_ENABLED || true)"
  auto_notify_minutes="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_NOTIFY_MINUTES || true)"
  auto_wait_empty="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_WAIT_EMPTY || true)"
  auto_max_wait="$(config_value runtime/generated/update-auto.env DUNE_AUTO_UPDATE_MAX_WAIT_MINUTES || true)"
  while IFS='|' read -r timer service label; do
    load_state="$(systemctl show "$timer" --property=LoadState --value 2>/dev/null || true)"
    if [ -z "$load_state" ] || [ "$load_state" = "not-found" ]; then
      continue
    fi
    installed=$((installed + 1))
    active_state="$(systemctl is-active "$timer" 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled "$timer" 2>/dev/null || true)"
    working_directory="$(systemctl show "$service" --property=WorkingDirectory --value 2>/dev/null || true)"
    exec_start="$(systemctl show "$service" --property=ExecStart --value 2>/dev/null || true)"

    if [ "$timer" = "dune-awakening-auto-update.timer" ] \
      && [ "$active_state" = "active" ] \
      && [ "${auto_update_enabled:-0}" != "1" ]; then
      warn_msg "$label timer is active while the saved preference is disabled"
      echo "     Run: dune update auto disable"
    fi

    if [ -z "$working_directory" ] || [ "$working_directory" != "$HOST_ROOT_DIR" ]; then
      warn_msg "$label timer points to a different checkout: ${working_directory:-unset}"
      echo "     Expected: $HOST_ROOT_DIR"
      continue
    fi
    if [ ! -d "$working_directory" ]; then
      warn_msg "$label timer points to a missing directory: $working_directory"
      continue
    fi
    if [ "$timer" = "dune-awakening-auto-update.timer" ]; then
      case "$exec_start" in
        *"$HOST_ROOT_DIR/runtime/scripts/update.sh"*"auto run"*) ;;
        *"$HOST_ROOT_DIR/runtime/scripts/dune"*"update --yes"*)
          warn_msg "$label timer uses the legacy update command from the current checkout"
          echo "     Repair: dune update auto enable ${auto_interval:-60} ${auto_apply:-1} ${auto_notify:-1} ${auto_notify_minutes:-15,10,5,1} ${auto_wait_empty:-0} ${auto_max_wait:-360}"
          continue
          ;;
        *"$HOST_ROOT_DIR/"*)
          warn_msg "$label timer does not use the current auto-update policy runner"
          echo "     Expected: $HOST_ROOT_DIR/runtime/scripts/update.sh auto run"
          continue
          ;;
        *)
          warn_msg "$label timer ExecStart points outside the current checkout"
          echo "     Expected path below: $HOST_ROOT_DIR"
          continue
          ;;
      esac
    else
      case "$exec_start" in
        *"$HOST_ROOT_DIR/"*) ;;
        *)
          warn_msg "$label timer ExecStart points outside the current checkout"
          echo "     Expected path below: $HOST_ROOT_DIR"
          continue
          ;;
      esac
    fi
    healthy=$((healthy + 1))
    ok "$label timer uses the current checkout ($active_state/$enabled_state)"
  done <<'EOF'
dune-awakening-auto-update.timer|dune-awakening-auto-update.service|Auto-update
dune-awakening-scheduled-restart.timer|dune-awakening-scheduled-restart.service|Scheduled restart
dune-awakening-scheduled-restart-warning.timer|dune-awakening-scheduled-restart-warning.service|Scheduled restart warning
dune-awakening-ip-change-restart.timer|dune-awakening-ip-change-restart.service|Public IP change restart
dune-awakening-db-backup.timer|dune-awakening-db-backup.service|Database backup
EOF

  if [ "$installed" -eq 0 ]; then
    ok "No project systemd timers installed"
  elif [ "$healthy" -eq "$installed" ]; then
    ok "All installed project systemd timer paths are valid"
  fi
}

# Every generated unit orders itself against the container engine's own
# systemd unit, and shutdown-protection.service depends on that ordering for
# the whole of its purpose: DefaultDependencies=no plus After=<engine> plus
# Before=shutdown.target is the only reason its ExecStop gets to stop the game
# gracefully before the engine tears the containers down. systemd treats
# After= on a unit that does not exist as a silent no-op, so a unit generated
# against the wrong engine keeps loading, keeps running, and quietly races
# teardown instead. Nothing logs it, which is why doctor has to look.
check_generated_unit_engine_ordering() {
  local unit load_state after verify_output installed=0 misordered=0
  local -a verify_units=()

  command -v systemctl >/dev/null 2>&1 || return 0

  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    load_state="$(systemctl show "$unit" --property=LoadState --value 2>/dev/null || true)"
    { [ -n "$load_state" ] && [ "$load_state" != "not-found" ]; } || continue
    installed=$((installed + 1))
    verify_units+=("$unit")
    after="$(systemctl show "$unit" --property=After --value 2>/dev/null || true)"
    if ! tr ' ' '\n' <<<"$after" | grep -qxF "$DUNE_ENGINE_SYSTEMD_UNIT"; then
      misordered=$((misordered + 1))
      warn_msg "$unit does not order after $DUNE_ENGINE_SYSTEMD_UNIT"
      echo "     It was generated for a different container engine; re-run the dune command that installed this schedule so the unit is rewritten."
    fi
  done <<'EOF'
dune-awakening-auto-update.service
dune-awakening-scheduled-restart.service
dune-awakening-scheduled-restart-warning.service
dune-awakening-ip-change-restart.service
dune-awakening-db-backup.service
dune-awakening-shutdown-protection.service
EOF

  if [ "$installed" -eq 0 ]; then
    return 0
  fi

  load_state="$(systemctl show "$DUNE_ENGINE_SYSTEMD_UNIT" --property=LoadState --value 2>/dev/null || true)"
  if [ -z "$load_state" ] || [ "$load_state" = "not-found" ]; then
    warn_msg "Generated units order against $DUNE_ENGINE_SYSTEMD_UNIT, which this host does not have"
    echo "     systemd ignores an ordering dependency on a missing unit without a word, so these units race container teardown on reboot."
  elif [ "$misordered" -eq 0 ]; then
    ok "All installed generated units order after $DUNE_ENGINE_SYSTEMD_UNIT"
  fi

  command -v systemd-analyze >/dev/null 2>&1 || return 0
  # Only the "not found" lines. An unfiltered verify reports "no installation
  # config" for nearly every unit on nearly every host, which would bury the
  # one line that means an ordering dependency evaporated.
  verify_output="$(systemd-analyze verify "${verify_units[@]}" 2>&1 | grep -i 'not found' || true)"
  if [ -n "$verify_output" ]; then
    warn_msg "systemd-analyze reports dependencies the generated units name but this host does not have"
    sed 's/^/     /' <<<"$verify_output"
  fi
}

echo "=== Dune doctor ==="
echo

echo "=== Host tools ==="
check_host_tools

echo
echo "=== Docker storage ==="
if docker info >/dev/null 2>&1; then
  check_docker_storage
else
  warn_msg "Skipping Docker storage checks because the daemon is not reachable"
fi

echo
echo "=== Local files ==="
check_file .env ".env config" "Run: dune init"
check_file runtime/secrets/funcom-token.txt "Funcom token file" "Run: dune init, or place the token in runtime/secrets/funcom-token.txt"
check_file runtime/generated/battlegroup.env "Battlegroup config" "Run: dune init"
check_file runtime/generated/image-tags.env "Generated image tags" "Run: dune update install during init, or re-run dune init if this is a fresh install"
if runtime/scripts/battlegroup-identity.sh check >/dev/null 2>&1; then
  ok "Battlegroup ID matches the Funcom token"
else
  fail_msg "Battlegroup ID is missing, invalid, or does not match the Funcom token"
  echo "     Run: runtime/scripts/battlegroup-identity.sh ensure"
fi

echo
echo "=== Host automation ==="
check_project_systemd_timers
check_generated_unit_engine_ordering

echo
echo "=== Containers ==="
for c in \
  dune-postgres \
  dune-rmq-admin \
  dune-rmq-game \
  dune-text-router \
  dune-director \
  dune-server-gateway \
  dune-server-survival-1 \
  dune-server-overmap
do
  if is_running "$c"; then
    ok "container $c"
  else
    fail_msg "container $c is not running"
    echo "     Try: dune start"
  fi
done
check_bridge_dns
check_game_container_argv

echo
echo "=== Ports ==="
postgres_port="$(resolve_postgres_port)"
rmq_admin_port="$(resolve_rmq_admin_port)"
rmq_game_port="$(resolve_rmq_game_port)"
rmq_game_http_port="$(resolve_rmq_game_http_port)"
text_router_port="$(resolve_text_router_port)"
director_port="$(resolve_director_port)"
check_tcp "$postgres_port" "Postgres"
check_tcp "$rmq_admin_port" "RabbitMQ admin"
check_tcp "$rmq_game_port" "RabbitMQ game"
check_tcp "$rmq_game_http_port" "RabbitMQ game HTTP"
check_tcp "$text_router_port" "TextRouter"
check_tcp "$director_port" "Director"
client_port_base="$(resolve_client_port_base)"
igw_port_base="$(resolve_igw_port_base)"
check_udp "$client_port_base" "Overmap clients"
check_udp "$((client_port_base + 1))" "Survival_1 clients"
check_udp "$igw_port_base" "Survival_1 server-to-server"
check_udp "$((igw_port_base + 1))" "Overmap server-to-server"

echo
echo "=== Host latency and vehicle timing ==="
if is_wsl_host; then
  warn_msg "WSL2 host detected"
  echo "     Fast vehicle movement can be more sensitive to WSL2 scheduling/network jitter; a full Linux VM or native Linux is preferred for busy servers."
else
  ok "Host is not detected as WSL2"
fi
check_game_container_pinning
check_deepdesert_mode
check_always_on_memory_safety

echo
echo "=== Steam server files ==="
app_id="$(config_value .env STEAM_APP_ID || true)"
app_id="${app_id:-${STEAM_APP_ID:-4754530}}"
orchestrator_container="$(dune_compose_running_service_container "$DUNE_COMPOSE_PROJECT_NAME" orchestrator 2>/dev/null || true)"
if [ -n "$orchestrator_container" ] && is_running "$orchestrator_container"; then
  if docker compose exec -T orchestrator test -f "/srv/dune/server/steamapps/appmanifest_${app_id}.acf" 2>/dev/null; then
    ok "Steam appmanifest found for app $app_id"
  else
    fail_msg "Steam appmanifest not found for app $app_id"
    echo "     Run first-time setup: dune init"
  fi
else
  warn_msg "The orchestrator service is not running; cannot inspect Steam appmanifest"
fi

echo
echo "=== Database ==="
if is_running dune-postgres; then
  if docker exec dune-postgres pg_isready -U postgres -d dune >/dev/null 2>&1; then
    ok "Postgres reachable"
  else
    fail_msg "Postgres is running but not ready"
  fi

  partition_count="$(docker exec dune-postgres psql -U dune -d dune -Atc "select count(*) from world_partition;" 2>/dev/null | tr -d '[:space:]' || true)"
  if [ "${partition_count:-0}" -gt 0 ] 2>/dev/null; then
    ok "world_partition rows: $partition_count"
  else
    fail_msg "world_partition has no rows"
    echo "     Fresh init should apply canonical world partitions."
  fi
else
  fail_msg "Cannot check database because dune-postgres is not running"
fi

echo
echo "=== Sietch state ==="
if is_running dune-postgres; then
  if runtime/scripts/sietches.sh validate >/tmp/dune-doctor-sietch.out 2>/tmp/dune-doctor-sietch.err; then
    ok "Sietch generated state matches current world partitions"
  else
    fail_msg "Sietch generated state validation failed"
    sed 's/^/     /' /tmp/dune-doctor-sietch.out 2>/dev/null || true
    sed 's/^/     /' /tmp/dune-doctor-sietch.err 2>/dev/null || true
  fi
  rm -f /tmp/dune-doctor-sietch.out /tmp/dune-doctor-sietch.err
else
  warn_msg "Skipping Sietch state validation because dune-postgres is not running"
fi

echo
echo "=== RabbitMQ and service signals ==="
if is_running dune-rmq-game && docker exec dune-rmq-game rabbitmq-diagnostics -q ping >/dev/null 2>&1; then
  ok "RabbitMQ game reachable"
else
  fail_msg "RabbitMQ game is not reachable"
fi

director_logs="$(docker logs --since 15m dune-director 2>&1 || true)"
if director_fls_logs_ready "$director_logs"; then
  ok "Director heartbeat to Funcom/FLS"
else
  warn_msg "Director heartbeat not seen in recent logs"
  echo "     If the stack just started, wait a few minutes and run: dune ready"
fi

gateway_logs="$(docker logs --tail 5000 dune-server-gateway 2>&1 || true)"
if grep -Eq 'Monitoring for servers going up or down|Starting gateway for battlegroup' <<<"$gateway_logs"; then
  ok "Gateway DB monitoring"
elif is_running dune-server-gateway; then
  info_msg "Gateway is running, but its DB-monitoring startup message is no longer present in retained logs"
  echo "     Use 'dune ready' for the live Gateway readiness check."
else
  warn_msg "Gateway DB monitoring cannot be confirmed because dune-server-gateway is not running"
fi

echo
echo "=== Hosting mode hints ==="
mode="$(config_value .env SERVER_IP_MODE || true)"
mode="${mode:-$(config_value runtime/generated/battlegroup.env SERVER_IP_MODE || true)}"
mode="${mode:-${SERVER_IP_MODE:-}}"
server_ip="$(config_value .env SERVER_IP || true)"
server_ip="${server_ip:-$(config_value runtime/generated/battlegroup.env SERVER_IP || true)}"
server_ip="${server_ip:-${SERVER_IP:-unknown}}"
if [ -z "$mode" ] || [ "$mode" = "unknown" ]; then
  if printf '%s' "$server_ip" | grep -Eq '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)'; then
    mode="local"
  elif [ "$server_ip" != "unknown" ] && [ -n "$server_ip" ]; then
    mode="public"
  else
    mode="unknown"
  fi
fi
case "$mode" in
  public)
    ok "Hosting mode: public"
    echo "     Make sure your firewall/router allows TCP ${rmq_game_port}, TCP ${rmq_game_http_port}, and the configured UDP game ranges."
    ;;
  local)
    ok "Hosting mode: local/LAN"
    echo "     Only players on the same local network should be expected to connect."
    ;;
  *)
    warn_msg "Hosting mode is unknown"
    echo "     Check SERVER_IP_MODE in .env."
    ;;
esac

advertised_ip="$(resolve_advertised_ip)"
bind_ip="$(resolve_bind_ip)"
nonlocal_bind="$(read_ipv4_ip_nonlocal_bind 2>/dev/null || true)"
if [ "$mode" = "public" ] \
  && is_ipv4 "$advertised_ip" \
  && is_ipv4 "$bind_ip" \
  && is_private_ipv4 "$bind_ip" \
  && [ "$advertised_ip" != "$bind_ip" ] \
  && [ "$nonlocal_bind" = "1" ]; then
  warn_msg "Public IP bind risk detected: net.ipv4.ip_nonlocal_bind=1 with SERVER_IP=$advertised_ip and SERVER_BIND_IP=$bind_ip"
  echo "     In NAT/double NAT, game sockets must bind to SERVER_BIND_IP while advertising SERVER_IP."
  echo "     Run: dune network fix"
fi

echo
if [ "$fail" -eq 0 ] && [ "$warn" -eq 0 ]; then
  echo "DOCTOR: no obvious issues found."
  exit 0
elif [ "$fail" -eq 0 ]; then
  echo "DOCTOR: warnings found. Review WARN lines above."
  exit 0
else
  echo "DOCTOR: issues found. Review FAIL lines above."
  exit 1
fi
