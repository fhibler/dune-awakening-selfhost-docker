#!/usr/bin/env bash
# The container-start scripts must reach the engine only through the seam.
#
# Every difference these scripts have to absorb -- the restart policy, the
# SELinux relabel, the cgroup namespace, the bridge's name resolution -- is
# invisible on Docker and silent on Podman: the container starts either way and
# misbehaves later, after a reboot, on a labelled host, or under the Console's
# memory balancer. A real run cannot show that without a Podman host, and the
# game-server scripts cannot be run here at all: they want SteamCMD secrets, a
# battlegroup identity and a live database. What is checkable here is that no
# call site quietly grew its own answer.
set -euo pipefail

cd "$(dirname "$0")/../.."

# Globbed rather than listed, so a new start script is covered the day it
# lands.
scripts=(runtime/scripts/start-*.sh runtime/scripts/spawn-server.sh)

failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# Report every offending line, so a sweep is one run rather than one per site.
refute_lines() {
  local pattern="$1" description="$2" hits
  hits="$(grep -nE -- "$pattern" "${scripts[@]}" || true)"
  if [ -n "$hits" ]; then
    fail "$description"
    printf '%s\n' "$hits" | sed 's/^/  /' >&2
  fi
}

# podman-restart.service, the Podman analogue of Docker's restart daemon,
# revives only `always` containers; an `unless-stopped` one stays down after a
# reboot until someone notices.
refute_lines '--restart +[a-z-]' \
  "a restart policy was hardcoded instead of read from DUNE_ENGINE_RESTART_POLICY"

# On an SELinux host an unlabelled bind mount is unreadable to the container.
# Named volumes and psql's own -v are left alone: only a path-valued source
# needs the relabel.
refute_lines '\-v +("\$\(host_path|/|"\$[A-Za-z_])' \
  "a bind mount bypassed dune_engine_mount and will be unreadable under SELinux"

# :Z gives the mount a private category pair. The orchestrator, the spawners
# and the game servers share these paths, so the first container to be given
# one locks the others out.
refute_lines ':Z' \
  "a bind mount was relabelled privately, which breaks sharing between containers"

# Podman gates bridge name resolution behind a flag the Docker compat API does
# not carry; dune_engine_create_network sets it before the compat call.
refute_lines 'docker network create' \
  "a bridge was created through the compat API alone and may come up without name resolution"

# The Console's memory balancer reads memory.swap.current from inside a game
# server and takes it for that server's own usage, which is only true under a
# private cgroup namespace. Podman's default comes from containers.conf and has
# shipped as host.
for script in "${scripts[@]}"; do
  if grep -q -- '--memory ' "$script" \
      && ! grep -q 'DUNE_ENGINE_CGROUPNS_ARGS' "$script"; then
    fail "$script limits memory without pinning the cgroup namespace"
  fi
done

# A seam answer that is merely spelled is an unbound variable under `set -u`,
# which aborts the start rather than misconfiguring it.
for script in "${scripts[@]}"; do
  if grep -qE 'DUNE_ENGINE_|dune_engine_' "$script" \
      && ! grep -qE '^source runtime/scripts/(runtime-env|lib/engine)\.sh$' "$script"; then
    fail "$script reads the seam without sourcing it"
  fi
done

if [ "$failures" -ne 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

echo "OK: engine call sites in the container-start scripts"
