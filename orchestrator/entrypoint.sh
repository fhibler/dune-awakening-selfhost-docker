#!/bin/bash
set -e

echo "[entrypoint] Running as root - preparing mounted runtime directories"

# Upgrade path: repair root-owned volumes from previous installs.
# This allows existing root-owned deployments to migrate to non-root.
WRITABLE_DIRS=(
  /srv/dune/server
  /srv/dune/steam
  /srv/dune/generated
  /srv/dune/cache
  /home/dune/.steam
  /work
)

for dir in "${WRITABLE_DIRS[@]}"; do
  mkdir -p "$dir"
  current_owner="$(stat -c '%u:%g' "$dir" 2>/dev/null || echo 'unknown')"
  if [ "$current_owner" != "$(id -u dune):$(id -g dune)" ]; then
    echo "[entrypoint] Repairing $dir ownership ($current_owner -> dune:dune)"
    if ! chown -R dune:dune "$dir"; then
      echo "[entrypoint] ERROR: could not repair ownership for $dir" >&2
      exit 1
    fi
  fi
done

for dir in "${WRITABLE_DIRS[@]}"; do
  marker="$dir/.dune-write-test"
  if ! runuser -u dune -- sh -c 'touch "$1" && rm -f "$1"' sh "$marker"; then
    echo "[entrypoint] ERROR: $dir is not writable by the dune runtime user." >&2
    echo "[entrypoint] Check the volume mount and host filesystem permissions, then recreate the orchestrator." >&2
    exit 1
  fi
done

# Handle engine socket group
if [ -z "${DOCKER_SOCKET_GID:-}" ] && [ -S /var/run/docker.sock ] && command -v stat >/dev/null 2>&1; then
  DOCKER_SOCKET_GID="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || echo '')"
fi

# A named group can only be created for a non-zero GID, so GID 0 falls through
# to the explicit group list below. Rootful Podman's socket is root:root 0660
# and reports exactly that.
if [ -n "${DOCKER_SOCKET_GID:-}" ] && [ "${DOCKER_SOCKET_GID}" != "0" ]; then
  SOCK_GROUP="docker-socket-gid-${DOCKER_SOCKET_GID}"
  if ! getent group "$SOCK_GROUP" >/dev/null 2>&1; then
    groupadd -g "$DOCKER_SOCKET_GID" "$SOCK_GROUP" 2>/dev/null || true
  fi
  if getent group "$SOCK_GROUP" >/dev/null 2>&1; then
    usermod -aG "$SOCK_GROUP" dune 2>/dev/null || true
    echo "[entrypoint] Added dune to group $SOCK_GROUP (GID=$DOCKER_SOCKET_GID) for engine socket access"
  fi
fi

echo "[entrypoint] Dropping privileges to dune user"

# Assemble the group set explicitly instead of letting the privilege drop
# re-derive it.
#
# `group_add` in docker-compose.yml is what actually delivers the socket's
# group into the container, but it lands on *this* process, not in
# /etc/group -- and runuser, su and gosu all call initgroups(), which replaces
# the process group set with dune's /etc/group memberships and discards it
# silently. Under Docker that is masked: the socket's GID is non-zero, so the
# block above recreated it as a real group and dune genuinely belongs to it.
# Rootful Podman's socket is root:root, no group can be created for GID 0, and
# the orchestrator ends up unable to open the one socket its entire job is to
# drive -- every engine call fails with EACCES and nothing says why.
#
# Group 0 is inherited only when the socket actually needs it: root is this
# container's own primary group before the drop, so carrying it across
# unconditionally would widen dune's access on Docker for nothing.
DUNE_UID="$(id -u dune)"
DUNE_GID="$(id -g dune)"
INHERITED_GROUPS="$(id -G | tr ' ' '\n' | sed '/^0$/d' | tr '\n' ' ')"
SUPP_GROUPS="$(
  printf '%s %s %s\n' "$(id -G dune)" "$INHERITED_GROUPS" "${DOCKER_SOCKET_GID:-}" |
    tr ' ' '\n' | sed -n '/^[0-9][0-9]*$/p' | sort -un | paste -sd ' ' -
)"
echo "[entrypoint] dune will run as ${DUNE_UID}:${DUNE_GID} with groups ${SUPP_GROUPS}"

# Argument-preserving privilege drop (not su -c — that loses boundaries).
#
# setpriv leads because it is the only one of these that takes raw numeric
# GIDs: runuser's -G rejects a GID with no /etc/group entry, which is exactly
# what an inherited group_add value is, and gosu and su can only re-derive the
# user's own memberships. The three fallbacks therefore carry no inherited
# group and are kept only for an image that somehow lacks util-linux.
#
# setpriv leaves the environment completely alone, so the variables runuser
# would have rewritten are set here instead, to the same values: dune's
# SteamCMD tree lives under its HOME.
if command -v setpriv >/dev/null 2>&1; then
  HOME="$(getent passwd dune | cut -d: -f6)"
  USER=dune
  LOGNAME=dune
  export HOME USER LOGNAME
  exec setpriv --reuid="$DUNE_UID" --regid="$DUNE_GID" --groups="${SUPP_GROUPS// /,}" --inh-caps=-all -- "$@"
fi
if command -v runuser >/dev/null 2>&1; then
  exec runuser -u dune -- "$@"
fi
if command -v gosu >/dev/null 2>&1; then
  exec gosu dune "$@"
fi
exec su -s /bin/bash dune -c 'exec "$@"' -- "$@"
