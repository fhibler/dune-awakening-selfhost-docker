#!/bin/sh
# Container-engine seam for the Dune self-host stack.
#
# The stack speaks Docker's dialect everywhere: every call site is spelled
# `docker`, ~60 of them parse Docker-shaped `inspect --format` output, and 39
# invoke `docker compose`. Podman support is therefore delivered by pointing
# the real Docker CLI and the real Compose v2 plugin at Podman's
# Docker-compatible API socket -- not by rewriting the call sites to `podman`.
# Rewriting them would turn a socket change into an audit of every Go template
# in the repo, on the engine that is already working. See docs/architecture/CONTAINER-ENGINES.md.
#
# What survives that socket swap is the set of places where Podman genuinely
# behaves differently: restart policy, SELinux mount labels, log options,
# systemd unit names, image-reference spelling, build-cache pruning. This file
# is the single description of those differences. Nothing else in the repo
# should branch on the engine by hand.
#
# Deliberately POSIX sh. install.sh runs under /bin/sh -- CI checks it with
# `dash -n` and BusyBox ash -- and needs the same answers as the Bash runtime
# helpers. No arrays, no `local`, no bashisms.
#
# Sourced, never executed. Sourcing runs dune_engine_detect once and exports
# the result, so every DUNE_ENGINE_* variable below is safe to read under
# `set -u` without the caller remembering to initialise anything. Re-sourcing
# is free. Safe under `set -euo pipefail`: every probe is guarded and nothing
# here exits.

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------

# Probe the engine behind the Docker CLI. Order matters: the operator's
# override wins, then a host that has no Docker CLI at all, then the engine's
# own self-report, then Docker as the fallback -- an engine we cannot identify
# must behave exactly as it does today.
dune_engine_probe_kind() {
  case "${DUNE_CONTAINER_ENGINE:-auto}" in
    docker | podman)
      printf '%s' "$DUNE_CONTAINER_ENGINE"
      return 0
      ;;
    auto | '') ;;
    *)
      echo "Ignoring unknown DUNE_CONTAINER_ENGINE=$DUNE_CONTAINER_ENGINE; expected docker, podman or auto." >&2
      ;;
  esac

  if ! command -v docker >/dev/null 2>&1; then
    if command -v podman >/dev/null 2>&1; then
      printf 'podman'
      return 0
    fi
    printf 'docker'
    return 0
  fi

  # Podman's compat layer names itself in the server block -- "Podman Engine"
  # appears as a component. Ask for the whole block rather than one named
  # field so an upstream field rename degrades to "looks like Docker" instead
  # of misreporting.
  dune_engine_report="$(docker version --format '{{json .Server}}' 2>/dev/null || true)"
  case "$dune_engine_report" in
    *[Pp]odman*)
      unset dune_engine_report
      printf 'podman'
      return 0
      ;;
  esac

  # An unreachable engine answers nothing, which is the state install.sh and
  # `dune doctor` run in. Decide from what is installed instead: a real Docker
  # Engine host has dockerd, a Podman host does not.
  if [ -z "$dune_engine_report" ] || [ "$dune_engine_report" = "null" ]; then
    if command -v podman >/dev/null 2>&1 && ! command -v dockerd >/dev/null 2>&1; then
      unset dune_engine_report
      printf 'podman'
      return 0
    fi
  fi

  unset dune_engine_report
  printf 'docker'
}

# Resolve the engine's API socket path. Under the recommended deployment the
# Podman socket is published *at* /var/run/docker.sock by a podman.socket
# drop-in, so this usually returns the Docker default on both engines and
# nothing has to be re-pointed. It differs only on a host that skipped the
# drop-in, which is exactly when diagnostics need to say so.
dune_engine_probe_socket() {
  case "${DOCKER_HOST:-}" in
    unix://*)
      printf '%s' "${DOCKER_HOST#unix://}"
      return 0
      ;;
  esac

  if [ "$1" = "podman" ] && [ ! -S /var/run/docker.sock ]; then
    printf '/run/podman/podman.sock'
    return 0
  fi
  printf '/var/run/docker.sock'
}

# Populate and export the DUNE_ENGINE_* contract. Idempotent, and the result is
# exported so a process tree pays for the probe once rather than once per
# script.
dune_engine_detect() {
  if [ "${DUNE_ENGINE_READY:-0}" = "1" ]; then
    return 0
  fi

  DUNE_ENGINE_KIND="$(dune_engine_probe_kind)"
  DUNE_ENGINE_SOCKET="$(dune_engine_probe_socket "$DUNE_ENGINE_KIND")"

  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    # `podman-restart.service` only revives containers whose policy is
    # `always`; `unless-stopped` containers stay down across a reboot with no
    # diagnostic anywhere.
    DUNE_ENGINE_RESTART_POLICY='always'
    # There is no docker.service on a Podman host. systemd treats `After=` on a
    # unit that does not exist as a silent no-op, so a generated unit that
    # names the wrong one loses its ordering guarantee without warning.
    DUNE_ENGINE_SYSTEMD_UNIT='podman.socket'
    # Shared relabel. Never `Z`: its private MCS category pair makes a volume
    # written by one container unreadable by its peers, and most of this
    # stack's binds are shared between the orchestrator, the spawners and the
    # game servers.
    DUNE_ENGINE_MOUNT_SUFFIX='z'
    # Podman's json-file/k8s-file drivers honour max-size but not max-file.
    DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE='0'
    # Locally built images normalise to localhost/<name>, so exact string
    # comparisons against `image ls` output need the prefix.
    DUNE_ENGINE_IMAGE_PREFIX='localhost/'
    # No `podman builder prune`, and the compat API does not implement
    # /build/prune either.
    DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE='0'
    # The `security_opt` every container that bind-mounts the engine socket
    # needs. Podman runs a container as `container_t`, which has no `connectto`
    # for the compat socket's listener (`container_runtime_t`), so on an
    # enforcing host none of them can reach the engine at all: the orchestrator
    # cannot load the Funcom image tarballs, the autoscaler cannot spawn a map
    # and the console cannot run a single stack command. The denial is
    # dontaudit'ed in the shipped policy, so it leaves no AVC -- the only
    # symptom is "Cannot connect to the Docker daemon" over an empty audit log,
    # and `semodule -DB` is needed to see it at all.
    #
    # This is the same concession dune_engine_label_disable_args already makes
    # for the privileged host-systemd helpers, and it concedes as little here:
    # a process holding the engine socket is root-equivalent whatever its
    # SELinux label.
    DUNE_ENGINE_SOCKET_SECURITY_OPT='label=disable'
  else
    DUNE_ENGINE_RESTART_POLICY='unless-stopped'
    DUNE_ENGINE_SYSTEMD_UNIT='docker.service'
    DUNE_ENGINE_MOUNT_SUFFIX=''
    DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE='1'
    DUNE_ENGINE_IMAGE_PREFIX=''
    DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE='1'
    # Docker's own default, stated rather than omitted. Compose has no way to
    # spell an absent list entry, so the socket-mounting services carry one
    # interpolated `security_opt` unconditionally, and this is the value that
    # leaves the Docker path behaving exactly as it did with no `security_opt`
    # at all. The `docker run` call sites spell the same variable as a
    # `--security-opt` flag, for one name per concept rather than two.
    DUNE_ENGINE_SOCKET_SECURITY_OPT='no-new-privileges:false'
  fi

  DUNE_ENGINE_READY=1
  export DUNE_ENGINE_KIND DUNE_ENGINE_SOCKET DUNE_ENGINE_RESTART_POLICY
  export DUNE_ENGINE_SYSTEMD_UNIT DUNE_ENGINE_MOUNT_SUFFIX
  export DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE DUNE_ENGINE_IMAGE_PREFIX
  export DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE DUNE_ENGINE_READY
  export DUNE_ENGINE_SOCKET_SECURITY_OPT

  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    # Compose v2 against the compat socket cannot use BuildKit: Podman does not
    # implement /build/cancel or the session API. No Dockerfile here needs
    # BuildKit, so force the classic builder rather than let Compose try and
    # fail with an error that reads like a broken Dockerfile.
    DOCKER_BUILDKIT="${DOCKER_BUILDKIT:-0}"
    export DOCKER_BUILDKIT
    # Only when the drop-in is absent: the CLI already defaults to the path the
    # drop-in publishes.
    if [ "$DUNE_ENGINE_SOCKET" != "/var/run/docker.sock" ] && [ -z "${DOCKER_HOST:-}" ]; then
      DOCKER_HOST="unix://$DUNE_ENGINE_SOCKET"
      export DOCKER_HOST
    fi
  fi
}

# ---------------------------------------------------------------------------
# Bind mounts
# ---------------------------------------------------------------------------

# Build the value of a `-v` argument, applying the engine's SELinux relabel.
#
#   dune_engine_mount /host/dir /in/container        -> /host/dir:/in/container[:z]
#   dune_engine_mount /host/dir /in/container ro     -> /host/dir:/in/container:ro[,z]
#
# The suffix belongs on the whole argument, not on the source path, which is
# why this wraps host_path()'s output rather than living inside it.
dune_engine_mount() {
  dune_engine_mount_src="$1"
  dune_engine_mount_dest="$2"
  dune_engine_mount_opts="${3:-}"

  if [ -n "$DUNE_ENGINE_MOUNT_SUFFIX" ]; then
    if [ -n "$dune_engine_mount_opts" ]; then
      dune_engine_mount_opts="$dune_engine_mount_opts,$DUNE_ENGINE_MOUNT_SUFFIX"
    else
      dune_engine_mount_opts="$DUNE_ENGINE_MOUNT_SUFFIX"
    fi
  fi

  if [ -n "$dune_engine_mount_opts" ]; then
    printf '%s:%s:%s' "$dune_engine_mount_src" "$dune_engine_mount_dest" "$dune_engine_mount_opts"
  else
    printf '%s:%s' "$dune_engine_mount_src" "$dune_engine_mount_dest"
  fi
  unset dune_engine_mount_src dune_engine_mount_dest dune_engine_mount_opts
}

# The privileged host-systemd helpers bind `/:/host` and chroot into it. A
# relabel there would recursively rewrite the host root filesystem's SELinux
# contexts -- catastrophic, and slow enough to look like a hang. They already
# run --privileged --pid=host, so turning labelling off for them concedes
# nothing that is not already conceded.
#
# Prints an empty string on Docker, so splicing it unquoted expands to nothing.
dune_engine_label_disable_args() {
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    printf '%s' '--security-opt label=disable'
  fi
}

# ---------------------------------------------------------------------------
# Cgroups
# ---------------------------------------------------------------------------

# The console's memory balancer reads /sys/fs/cgroup/memory.swap.current from
# inside a game server and treats the number as that server's own usage. That
# only holds under a private cgroup namespace, where the container sees its
# own cgroup at the root of /sys/fs/cgroup. Docker defaults to private on a
# cgroup-v2 host; rootful Podman takes the default from containers.conf and
# has shipped `host` in several configurations, where the same read returns
# the host root's figures -- a plausible number, so the balancer moves memory
# on host-wide swap and nothing looks wrong.
#
# Prints an empty string on Docker, whose default is already private, so
# splicing it there expands to nothing.
dune_engine_cgroupns_args() {
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    printf '%s' '--cgroupns=private'
  fi
}

# ---------------------------------------------------------------------------
# Networks
# ---------------------------------------------------------------------------

# Create the stack's user-defined bridge, tolerating one that already exists.
#
# Twenty call sites address a peer by container name -- both RabbitMQ brokers
# authenticate every client against http://dune-text-router:5059, and the
# gateway, director and text router all reach the database as dune-postgres.
# Docker's embedded resolver is unconditional on a user-defined bridge.
# Podman gates resolution per network behind netavark's dns_enabled, which
# the Docker compat API does not expose, so a bridge created through the
# socket inherits whatever the backend happens to default to and the failure
# surfaces as an NXDOMAIN at runtime rather than an error here. `--dns-enabled`
# exists only on podman(1), so the network is created there first and the
# compat call behind it becomes the no-op its `|| true` already allowed for.
dune_engine_create_network() {
  if [ "$DUNE_ENGINE_KIND" = "podman" ] && command -v podman >/dev/null 2>&1; then
    podman network create --dns-enabled "$1" >/dev/null 2>&1 || true
  fi
  docker network create "$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------

# Strip the engine's repository prefix so a reference read back out of
# `image ls` compares equal to the short name the scripts build with. Podman
# reports a locally built `dune-orchestrator:dev` as
# `localhost/dune-orchestrator:dev`; Docker reports it unprefixed.
dune_engine_normalize_image_ref() {
  dune_engine_image_ref="${1:-}"
  printf '%s' "${dune_engine_image_ref#localhost/}"
  unset dune_engine_image_ref
}

# Strip the `sha256:` algorithm prefix from an image or container digest.
# Docker prints it consistently across `inspect .Image`, `image inspect .Id`
# and `image ls --no-trunc`; Podman's compat endpoints do not, and the callers
# compare those three against each other with an exact whole-line match.
dune_engine_normalize_digest() {
  dune_engine_digest="${1:-}"
  printf '%s' "${dune_engine_digest#sha256:}"
  unset dune_engine_digest
}

# ---------------------------------------------------------------------------
# systemd unit generation
# ---------------------------------------------------------------------------

# Emit the [Unit] ordering directives for a generated unit that must run while
# the engine is up. Extra units to order after are passed as arguments and are
# placed before the engine's own unit.
#
#   dune_engine_systemd_unit_ordering                        -> Wants=/After=<engine unit>
#   dune_engine_systemd_unit_ordering network-online.target   -> After=network-online.target <engine unit>
dune_engine_systemd_unit_ordering() {
  printf 'Wants=%s\n' "$DUNE_ENGINE_SYSTEMD_UNIT"
  if [ "$#" -gt 0 ]; then
    printf 'After=%s %s\n' "$*" "$DUNE_ENGINE_SYSTEMD_UNIT"
  else
    printf 'After=%s\n' "$DUNE_ENGINE_SYSTEMD_UNIT"
  fi
}

# Emit the [Service] environment a generated unit needs to reach the engine.
# Generated units run with a clean environment, so anything the shell exports
# has to be written into the unit file. Empty whenever the CLI's own defaults
# already work, which is the case on Docker and on any Podman host that
# publishes its socket at /var/run/docker.sock.
dune_engine_systemd_service_environment() {
  if [ "$DUNE_ENGINE_SOCKET" != "/var/run/docker.sock" ]; then
    printf 'Environment=DOCKER_HOST=unix://%s\n' "$DUNE_ENGINE_SOCKET"
  fi
  if [ "$DUNE_ENGINE_KIND" = "podman" ]; then
    printf 'Environment=DOCKER_BUILDKIT=0\n'
  fi
}

# ---------------------------------------------------------------------------
# Runtime environment
# ---------------------------------------------------------------------------

# True when this process is running inside a container. Podman writes
# /run/.containerenv and sets container=podman; it never creates /.dockerenv.
# Strictly wider than the /.dockerenv test it replaces, so the Docker path is
# unchanged by construction.
dune_in_container() {
  [ -f /.dockerenv ] && return 0
  [ -f /run/.containerenv ] && return 0
  [ -n "${container:-}" ] && return 0
  return 1
}

dune_engine_detect
