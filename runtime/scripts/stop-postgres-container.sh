#!/usr/bin/env bash
set -euo pipefail

# A forced remove sends SIGKILL to PostgreSQL and makes every ordinary
# Battlegroup restart run crash recovery. Let PostgreSQL finish its shutdown
# before removing the container; keep it in place if shutdown fails.
#
# Match the exact name in the listing rather than with
# `--filter 'name=^/dune-postgres$'`: the leading slash is Docker's internal
# spelling of a container name, and Podman's compat layer does not reproduce
# it, so there the filter matches nothing and this script exits 0 having
# skipped both the graceful shutdown and the remove -- which then leaves
# start-postgres.sh to fail on the name conflict.
containers="$(docker ps -a --format '{{.Names}}')"
if ! grep -qx dune-postgres <<<"$containers"; then
  exit 0
fi

if [ "$(docker inspect -f '{{.State.Running}}' dune-postgres)" = "true" ]; then
  docker stop --time 120 dune-postgres >/dev/null
fi
docker rm dune-postgres >/dev/null
