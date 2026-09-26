#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT_DIR="$(pwd)"
HOST_ROOT_DIR="${DUNE_HOST_REPO_ROOT:-$ROOT_DIR}"

# shellcheck source=runtime/scripts/lib/engine.sh
source runtime/scripts/lib/engine.sh

STATE_FILE="runtime/generated/shutdown-protection.env"
SERVICE_NAME="dune-awakening-shutdown-protection.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
LOG_FILE="runtime/generated/shutdown-protection.log"

# DefaultDependencies=no plus this ordering plus Before=shutdown.target is the
# entire mechanism by which ExecStop gets to shut the game down before the
# engine tears its containers apart. systemd treats `After=` on a unit that
# does not exist as a silent no-op, so naming docker.service on a Podman host
# would drop the guarantee and leave the world database to be torn down
# mid-write -- the exact outcome this unit exists to prevent. Generated units
# also run with a clean environment, so whatever the shell exported to reach
# the engine has to be written into the file. The environment carries its own
# newline and expands ahead of the next directive rather than on a line of its
# own, because it is empty on Docker and the unit there has to stay byte for
# byte what it is today.
SYSTEMD_UNIT_ORDERING="$(dune_engine_systemd_unit_ordering)"
SYSTEMD_SERVICE_ENVIRONMENT="$(dune_engine_systemd_service_environment)"
if [ -n "$SYSTEMD_SERVICE_ENVIRONMENT" ]; then
  SYSTEMD_SERVICE_ENVIRONMENT+=$'\n'
fi

# Splice into the privileged helpers that bind /:/host and chroot into it: that
# mount must never be relabelled. See dune_engine_label_disable_args in
# lib/engine.sh. Empty on Docker. shutdown-protection.sh does not source
# runtime-env.sh, which builds the same array for the scripts that do.
DUNE_ENGINE_LABEL_DISABLE_ARGS=()
if [ -n "$(dune_engine_label_disable_args)" ]; then
  DUNE_ENGINE_LABEL_DISABLE_ARGS=(--security-opt label=disable)
fi

usage() {
  cat <<'EOF'
Usage:
  dune shutdown-protection enable
  dune shutdown-protection disable
  dune shutdown-protection remove
  dune shutdown-protection status
  dune shutdown-protection run-stop
EOF
}

write_state() {
  local enabled="$1"
  local installed="${2:-${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-0}}"
  local tmp

  mkdir -p runtime/generated
  tmp="${STATE_FILE}.$$"
  cat > "$tmp" <<EOF
DUNE_SHUTDOWN_PROTECTION_ENABLED=$enabled
DUNE_SHUTDOWN_PROTECTION_INSTALLED=$installed
EOF
  chmod 644 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$STATE_FILE"
}

read_state() {
  DUNE_SHUTDOWN_PROTECTION_ENABLED=0
  DUNE_SHUTDOWN_PROTECTION_INSTALLED=""
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
  fi
}

can_manage_systemd_units() {
  [ -d /etc/systemd/system ] && [ -w /etc/systemd/system ]
}

can_write_log() {
  [ -w "$LOG_FILE" ] || { [ ! -e "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; }
}

log_event() {
  local message="$1"
  if can_write_log; then
    echo "[$(date -Is)] $message" >> "$LOG_FILE" 2>/dev/null || true
  else
    echo "[$(date -Is)] $message"
  fi
}

docker_helper_image() {
  printf '%s' "${DUNE_SYSTEMD_HELPER_IMAGE:-redblink-dune-docker-console:dev}"
}

can_manage_host_systemd_with_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  # Resolved, not assumed: a Podman host that skipped the socket drop-in would
  # fail the hardcoded path silently and never install the unit.
  [ -S "$DUNE_ENGINE_SOCKET" ] || return 1
  docker image inspect "$(docker_helper_image)" >/dev/null 2>&1 || return 1
}

write_unit_to() {
  local systemd_dir="$1"
  local exec_root="$2"

  mkdir -p "$systemd_dir"
  cat > "$systemd_dir/$SERVICE_NAME" <<EOF
[Unit]
Description=Dune Docker Console clean shutdown protection
Documentation=https://github.com/Red-Blink/dune-awakening-selfhost-docker
DefaultDependencies=no
$SYSTEMD_UNIT_ORDERING
Before=shutdown.target reboot.target halt.target kexec.target

[Service]
${SYSTEMD_SERVICE_ENVIRONMENT}Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$exec_root
ExecStart=/bin/true
ExecStop=$exec_root/runtime/scripts/shutdown-protection.sh run-stop
TimeoutStopSec=240

[Install]
WantedBy=multi-user.target
EOF
}

install_unit() {
  write_unit_to "/etc/systemd/system" "$HOST_ROOT_DIR"
}

install_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${DUNE_ENGINE_LABEL_DISABLE_ARGS[@]}" \
    -e DUNE_SYSTEMD_UNIT_ORDERING="$SYSTEMD_UNIT_ORDERING" \
    -e DUNE_SYSTEMD_SERVICE_ENVIRONMENT="$SYSTEMD_SERVICE_ENVIRONMENT" \
    -e DUNE_HOST_REPO_ROOT="$HOST_ROOT_DIR" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      systemd_dir=/host/etc/systemd/system
      mkdir -p "$systemd_dir"
      cat > "$systemd_dir/dune-awakening-shutdown-protection.service" <<EOF
[Unit]
Description=Dune Docker Console clean shutdown protection
Documentation=https://github.com/Red-Blink/dune-awakening-selfhost-docker
DefaultDependencies=no
${DUNE_SYSTEMD_UNIT_ORDERING}
Before=shutdown.target reboot.target halt.target kexec.target

[Service]
${DUNE_SYSTEMD_SERVICE_ENVIRONMENT}Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${DUNE_HOST_REPO_ROOT}
ExecStart=/bin/true
ExecStop=${DUNE_HOST_REPO_ROOT}/runtime/scripts/shutdown-protection.sh run-stop
TimeoutStopSec=240

[Install]
WantedBy=multi-user.target
EOF
      chroot /host /bin/systemctl daemon-reload
      chroot /host /bin/systemctl enable --now dune-awakening-shutdown-protection.service
    '
}

disable_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${DUNE_ENGINE_LABEL_DISABLE_ARGS[@]}" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      chroot /host /bin/systemctl disable --now dune-awakening-shutdown-protection.service >/dev/null 2>&1 || true
      chroot /host /bin/systemctl daemon-reload
    '
}

remove_unit_via_docker_host() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${DUNE_ENGINE_LABEL_DISABLE_ARGS[@]}" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      chroot /host /bin/systemctl disable --now dune-awakening-shutdown-protection.service >/dev/null 2>&1 || true
      rm -f /host/etc/systemd/system/dune-awakening-shutdown-protection.service
      chroot /host /bin/systemctl daemon-reload
    '
}

show_host_status_via_docker() {
  local image
  image="$(docker_helper_image)"

  can_manage_host_systemd_with_docker || return 1
  docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${DUNE_ENGINE_LABEL_DISABLE_ARGS[@]}" \
    -v /:/host \
    --entrypoint bash \
    "$image" -lc '
      set -euo pipefail
      if chroot /host /bin/systemctl list-unit-files dune-awakening-shutdown-protection.service --no-legend --no-pager 2>/dev/null | grep -q "^dune-awakening-shutdown-protection.service"; then
        active="$(chroot /host /bin/systemctl is-active dune-awakening-shutdown-protection.service 2>/dev/null || true)"
        enabled="$(chroot /host /bin/systemctl is-enabled dune-awakening-shutdown-protection.service 2>/dev/null || true)"
        echo "Systemd service:         ${active:-unknown}"
        echo "Systemd enabled:         ${enabled:-unknown}"
      else
        echo "Systemd service:         not installed"
        echo "Systemd enabled:         disabled"
      fi
    '
}

enable_protection() {
  if ! command -v systemctl >/dev/null 2>&1; then
    if install_unit_via_docker_host; then
      write_state 1 1
      echo "Shutdown protection enabled."
      echo "Service: $SERVICE_NAME"
      return 0
    fi
    write_state 0 0
    echo "Shutdown protection could not be installed because systemctl was not found and the host service could not be installed through Docker."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh enable"
    return 1
  fi

  if ! can_manage_systemd_units; then
    if install_unit_via_docker_host; then
      write_state 1 1
      echo "Shutdown protection enabled."
      echo "Service: $SERVICE_NAME"
      return 0
    fi
    write_state 0 0
    echo "Shutdown protection could not be installed because this user cannot write systemd units."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh enable"
    return 1
  fi

  install_unit
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  write_state 1 1

  echo "Shutdown protection enabled."
  echo "Service: $SERVICE_NAME"
}

disable_protection() {
  read_state
  write_state 0 "${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-1}"
  if command -v systemctl >/dev/null 2>&1 && can_manage_systemd_units; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl daemon-reload
    write_state 0 1
  elif can_manage_host_systemd_with_docker; then
    disable_unit_via_docker_host
    write_state 0 1
  else
    echo "Shutdown protection could not be disabled because the host systemd service cannot be managed from this environment."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh disable"
    return 1
  fi

  echo "Shutdown protection disabled."
}

remove_protection() {
  write_state 0 0
  if command -v systemctl >/dev/null 2>&1 && can_manage_systemd_units; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    write_state 0 0
  elif can_manage_host_systemd_with_docker; then
    remove_unit_via_docker_host
    write_state 0 0
  else
    echo "Shutdown protection could not be removed because the host systemd service cannot be managed from this environment."
    echo "Run this command with sudo/root on the Linux host:"
    echo "  runtime/scripts/shutdown-protection.sh remove"
    return 1
  fi

  echo "Shutdown protection removed."
}

show_status() {
  read_state
  local enabled_text="false"
  local installed_text="${DUNE_SHUTDOWN_PROTECTION_INSTALLED:-}"

  if [ "${DUNE_SHUTDOWN_PROTECTION_ENABLED:-0}" = "1" ]; then
    enabled_text="true"
  fi
  if [ -z "$installed_text" ] && [ "$enabled_text" = "true" ]; then
    installed_text=1
  fi

  echo "Shutdown protection enabled: $enabled_text"
  echo "Unit file:                   $SERVICE_NAME"
  echo "Clean stop command:          $HOST_ROOT_DIR/runtime/scripts/shutdown-protection.sh run-stop"
  echo "Timeout:                     240 seconds"
  echo "Manual install command:      sudo $HOST_ROOT_DIR/runtime/scripts/shutdown-protection.sh enable"

  if [ "$installed_text" = "1" ]; then
    if [ "$enabled_text" = "true" ]; then
      echo
      echo "Systemd service:         active"
      echo "Systemd enabled:         enabled"
    else
      echo
      echo "Systemd service:         inactive"
      echo "Systemd enabled:         disabled"
    fi
    return 0
  fi

  echo
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files "$SERVICE_NAME" --no-legend --no-pager 2>/dev/null | grep -q "^$SERVICE_NAME"; then
      active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || true)"
      enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || true)"
      echo "Systemd service:         ${active:-unknown}"
      echo "Systemd enabled:         ${enabled:-unknown}"
    else
      echo "Systemd service:         not installed"
      echo "Systemd enabled:         disabled"
    fi
  else
    show_host_status_via_docker || {
      echo "Systemd service:         not installed"
      echo "Systemd enabled:         disabled"
    }
  fi
}

run_stop() {
  mkdir -p runtime/generated
  read_state
  if [ "${DUNE_SHUTDOWN_PROTECTION_ENABLED:-0}" != "1" ]; then
    log_event "Host shutdown protection clean stop skipped because protection is disabled."
    return 0
  fi
  if can_write_log; then
    {
      echo "[$(date -Is)] Host shutdown protection clean stop started."
      runtime/scripts/stop-all.sh
      echo "[$(date -Is)] Host shutdown protection clean stop finished."
    } >> "$LOG_FILE" 2>&1
  else
    echo "[$(date -Is)] Host shutdown protection clean stop started."
    runtime/scripts/stop-all.sh
    echo "[$(date -Is)] Host shutdown protection clean stop finished."
  fi
}

cmd="${1:-status}"

case "$cmd" in
  help|--help|-h)
    usage
    ;;
  enable|on)
    enable_protection
    ;;
  disable|off)
    disable_protection
    ;;
  remove|uninstall)
    remove_protection
    ;;
  status)
    show_status
    ;;
  run-stop)
    run_stop
    ;;
  *)
    usage
    exit 2
    ;;
esac
