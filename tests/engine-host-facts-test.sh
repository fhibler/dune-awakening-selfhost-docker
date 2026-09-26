#!/usr/bin/env bash
# The engine facts that .env cannot carry, and the one it must never pin.
#
# install.sh writes DUNE_ENGINE_RESTART_POLICY into .env because Compose
# interpolates the restart key from there. Two callers sit outside that
# mechanism, and both fail silently rather than loudly:
#
#   * public-probe.sh passes --env-file, which *replaces* .env rather than
#     adding to it. What saves it is the seam it sources, which exports the
#     policy into the environment Compose also interpolates from. Drop that
#     source and the probe alone renders `unless-stopped` on a Podman host and
#     stays down after every reboot, with nothing logged;
#   * DOCKER_SOCKET_GID is read from the live socket, not from the engine, and
#     persisting the root-owned 0 that Podman ships before its drop-in takes
#     would make a transient misconfiguration permanent -- the probe is skipped
#     whenever .env already supplies a value.
#
# Both bodies are lifted out of the shipped files by name: sourcing either
# entrypoint whole runs a command.
set -euo pipefail

cd "$(dirname "$0")/.."

failures=0

check() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s\n      expected: %s\n      actual:   %s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

# --- --env-file callers must source the seam -------------------------------

# Compose interpolates from --env-file *or* .env, never both, and it also
# interpolates from the process environment. Sourcing the seam is what puts
# the policy there, so for these callers the source line is the fix. A static
# sweep rather than a run: it covers the next --env-file caller the day it
# lands, which is the case that would otherwise ship broken.
while IFS= read -r script; do
  [ -n "$script" ] || continue
  if ! grep -q '^\. runtime/scripts/lib/engine\.sh$\|^source runtime/scripts/lib/engine\.sh$' "$script"; then
    printf 'FAIL: %s hands Compose an --env-file but does not source lib/engine.sh,\n' "$script" >&2
    printf '      so DUNE_ENGINE_RESTART_POLICY reaches neither .env nor the environment\n' >&2
    failures=$((failures + 1))
  fi
done < <(grep -rl -- '--env-file' runtime/scripts/ install.sh 2>/dev/null | grep -v '/lib/')

# --- console.sh and dune: a root-owned socket GID is never pinned ----------

# Both entrypoints carry the same body. Test both: they are separate copies,
# and a fix applied to one of them is the failure mode worth catching.
socket_gid_outcome() {
  local script="$1" kind="$2" socket_gid="$3" workdir out
  workdir="$(mktemp -d)"
  out="$(
    cd "$workdir"
    mkdir -p bin
    # stat is what reads the socket's group; the socket itself cannot be
    # created with an arbitrary GID here without root.
    printf '#!/usr/bin/env bash\necho %s\n' "$socket_gid" >bin/stat
    chmod +x bin/stat
    export PATH="$PWD/bin:$PATH"

    # Read by the lifted prepare_docker_socket_gid below; shellcheck cannot
    # see through the eval that defines it.
    # shellcheck disable=SC2034
    DUNE_ENGINE_KIND="$kind"
    persist_env_value() { printf 'persisted %s=%s\n' "$1" "$2"; }
    eval "$(awk '
      $0 == "prepare_docker_socket_gid() {" { inside = 1 }
      inside { print }
      inside && $0 == "}" { inside = 0 }
    ' "$OLDPWD/$script")"

    # The real function guards on [ -S /var/run/docker.sock ]; this environment
    # has no engine socket, so seed the value the probe would have produced.
    # shellcheck disable=SC2034
    DOCKER_SOCKET_GID="$socket_gid"
    prepare_docker_socket_gid 2>/dev/null
  )"
  rm -rf "$workdir"
  printf '%s' "${out:-nothing}"
}

for script in runtime/scripts/console.sh runtime/scripts/dune; do
  check "$script persists a real GID on Podman" \
    "persisted DOCKER_SOCKET_GID=989" "$(socket_gid_outcome "$script" podman 989)"
  check "$script refuses to pin the root-owned GID Podman ships before its drop-in" \
    "nothing" "$(socket_gid_outcome "$script" podman 0)"
  # On Docker a 0 has always meant "the socket was not there yet" and stays
  # survivable, so the Docker leg must keep behaving exactly as it did.
  check "$script still persists on Docker, including the 0 it always persisted" \
    "persisted DOCKER_SOCKET_GID=0" "$(socket_gid_outcome "$script" docker 0)"
done

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures check(s)" >&2
  exit 1
fi
echo "OK: engine host facts reach their callers"
