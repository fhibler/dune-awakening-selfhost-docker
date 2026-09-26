#!/usr/bin/env bash
# Compose files render engine-correct values on both engines.
#
# Several literals in the Compose files became interpolated variables so the
# same file can describe a Docker and a Podman deployment. Two things can go
# wrong and neither shows up until a host is running: a variable nothing
# exports renders empty, and a default that drifts silently changes what an
# existing Docker install gets. Both legs are asserted here against the
# environment the production code really produces -- engine.sh for the shared
# values, metrics-stack.sh for the two host paths only it knows.
#
# There is no container engine in CI, so `docker compose config` cannot be the
# renderer; tests/lib/compose-render.py stands in for its interpolation.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root="$(pwd -P)"

test_no=0

note() {
  printf '# %s\n' "$*"
}

ok() {
  test_no=$((test_no + 1))
  printf 'ok %02d - %s\n' "$test_no" "$*"
}

fail() {
  test_no=$((test_no + 1))
  printf 'not ok %02d - %s\n' "$test_no" "$*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2" label="$3"
  if grep -Fq -- "$expected" "$file"; then
    ok "$label"
    return 0
  fi
  echo "Expected to find: $expected" >&2
  echo "--- rendered ---" >&2
  cat "$file" >&2
  echo "----------------" >&2
  fail "$label"
}

assert_missing() {
  local file="$1" unexpected="$2" label="$3"
  if grep -Fq -- "$unexpected" "$file"; then
    echo "Expected NOT to find: $unexpected" >&2
    echo "--- rendered ---" >&2
    cat "$file" >&2
    echo "----------------" >&2
    fail "$label"
  fi
  ok "$label"
}

assert_count() {
  local file="$1" expected="$2" wanted="$3" label="$4"
  local found
  found="$(grep -Fc -- "$expected" "$file" || true)"
  if [ "$found" = "$wanted" ]; then
    ok "$label"
    return 0
  fi
  echo "Expected $wanted occurrences of: $expected (found $found)" >&2
  echo "--- rendered ---" >&2
  cat "$file" >&2
  echo "----------------" >&2
  fail "$label"
}

echo "TAP version 13"
note "compose engine rendering tests"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

compose_files=(
  docker-compose.yml
  docker-compose.web.yml
  docker-compose.metrics.yml
  docker-compose.public-probe.yml
  docker-compose.public-probe-host.yml
)

for compose_file in "${compose_files[@]}"; do
  python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$compose_file"
  ok "$compose_file is valid YAML"
done

# Render a Compose file with the environment runtime/scripts/lib/engine.sh
# exports for one engine. DOCKER_HOST is always given explicitly: the seam
# falls back to probing /var/run/docker.sock, and whether that exists is a
# property of the machine running the suite.
render_for_engine() {
  local kind="$1" docker_host="$2" compose_file="$3" out="$4"
  env -u DUNE_ENGINE_READY -u DOCKER_HOST \
    DUNE_CONTAINER_ENGINE="$kind" \
    ${docker_host:+DOCKER_HOST="$docker_host"} \
    sh -c '. runtime/scripts/lib/engine.sh && exec python3 tests/lib/compose-render.py "$1"' \
    sh "$compose_file" >"$out"
}

note "Docker renders exactly what it rendered before the engine seam"

docker_out="$tmpdir/docker-orchestrator.json"
render_for_engine docker "" docker-compose.yml "$docker_out"
assert_contains "$docker_out" '"restart": "unless-stopped"' "orchestrator keeps unless-stopped on Docker"
assert_contains "$docker_out" '"/var/run/docker.sock:/var/run/docker.sock"' "orchestrator keeps the Docker socket bind"
assert_contains "$docker_out" '"max-file": "3"' "orchestrator keeps its json-file max-file on Docker"

docker_web="$tmpdir/docker-web.json"
render_for_engine docker "" docker-compose.web.yml "$docker_web"
assert_contains "$docker_web" '"restart": "unless-stopped"' "console keeps unless-stopped on Docker"
assert_contains "$docker_web" '"/var/run/docker.sock:/var/run/docker.sock"' "console keeps the Docker socket bind"

docker_probe="$tmpdir/docker-probe.json"
render_for_engine docker "" docker-compose.public-probe.yml "$docker_probe"
assert_contains "$docker_probe" '"restart": "unless-stopped"' "public probe keeps unless-stopped on Docker"

note "Podman gets the restart policy podman-restart.service actually revives"

podman_out="$tmpdir/podman-orchestrator.json"
render_for_engine podman "unix:///run/podman/podman.sock" docker-compose.yml "$podman_out"
assert_contains "$podman_out" '"restart": "always"' "orchestrator becomes always on Podman"
assert_contains "$podman_out" '"/run/podman/podman.sock:/var/run/docker.sock"' \
  "orchestrator binds the Podman socket without moving the container path"

podman_web="$tmpdir/podman-web.json"
render_for_engine podman "unix:///run/podman/podman.sock" docker-compose.web.yml "$podman_web"
assert_contains "$podman_web" '"restart": "always"' "console becomes always on Podman"
assert_contains "$podman_web" '"/run/podman/podman.sock:/var/run/docker.sock"' "console binds the Podman socket"

podman_probe="$tmpdir/podman-probe.json"
render_for_engine podman "unix:///run/podman/podman.sock" docker-compose.public-probe.yml "$podman_probe"
assert_contains "$podman_probe" '"restart": "always"' "public probe becomes always on Podman"

# The recommended deployment publishes the Podman socket at the Docker path
# through a podman.socket drop-in, and then nothing about the bind changes.
podman_dropin="$tmpdir/podman-dropin.json"
render_for_engine podman "unix:///var/run/docker.sock" docker-compose.yml "$podman_dropin"
assert_contains "$podman_dropin" '"/var/run/docker.sock:/var/run/docker.sock"' \
  "socket bind is unchanged when the podman.socket drop-in is in place"

note "no interpolation is left unresolved on either engine"
for rendered in "$docker_out" "$docker_web" "$docker_probe" "$podman_out" "$podman_web" "$podman_probe"; do
  assert_missing "$rendered" '${' "$(basename "$rendered") resolves every variable"
done

# The metrics stack is rendered through its real launcher: the two host paths
# docker-compose.metrics.yml needs are exported by metrics-stack.sh, so a test
# that set them itself would prove nothing.
cat >"$tmpdir/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  info | network)
    exit 0
    ;;
  compose)
    shift || true
    case "${1:-}" in
      version)
        echo "Docker Compose version v2.test"
        exit 0
        ;;
      -f)
        if [ "${3:-}" = "config" ]; then
          # Dump the environment metrics-stack.sh handed the engine, then
          # render the file with exactly that environment.
          env -0 >"$FAKE_ENV_DUMP"
          exec python3 "$DUNE_TEST_REPO_ROOT/tests/lib/compose-render.py" "$2" --env-file "$FAKE_ENV_DUMP"
        fi
        ;;
    esac
    echo "unexpected docker compose args: $*" >&2
    exit 1
    ;;
esac
echo "unexpected docker args: $*" >&2
exit 1
EOF
chmod +x "$tmpdir/bin/docker"

render_metrics() {
  local kind="$1" out="$2"
  env -u DUNE_ENGINE_READY -u DOCKER_HOST \
    PATH="$tmpdir/bin:$PATH" \
    DUNE_CONTAINER_ENGINE="$kind" \
    DUNE_TEST_REPO_ROOT="$repo_root" \
    FAKE_ENV_DUMP="$tmpdir/metrics-env-$kind.env0" \
    bash runtime/scripts/metrics-stack.sh config >"$out"
}

note "metrics stack renders the engine's own host paths"

metrics_docker="$tmpdir/docker-metrics.json"
render_metrics docker "$metrics_docker"
assert_count "$metrics_docker" '"restart": "unless-stopped"' 4 "all four metrics services keep unless-stopped on Docker"
assert_contains "$metrics_docker" '"/var/lib/docker:/var/lib/docker:ro"' "cAdvisor keeps the Docker storage bind"
assert_contains "$metrics_docker" \
  '"--collector.filesystem.mount-points-exclude=^(/dev|/proc|/sys|/run/docker/netns|/var/lib/docker/.+)($|/)"' \
  "node-exporter keeps the Docker mount-point exclusions"
assert_missing "$metrics_docker" '${' "metrics stack resolves every variable on Docker"

metrics_podman="$tmpdir/podman-metrics.json"
render_metrics podman "$metrics_podman"
assert_count "$metrics_podman" '"restart": "always"' 4 "all four metrics services become always on Podman"
assert_contains "$metrics_podman" '"/var/lib/containers/storage:/var/lib/containers/storage:ro"' \
  "cAdvisor binds Podman's container storage instead of a path that does not exist"
assert_contains "$metrics_podman" \
  '"--collector.filesystem.mount-points-exclude=^(/dev|/proc|/sys|/run/netns|/var/lib/containers/storage/.+)($|/)"' \
  "node-exporter excludes Podman's netns and storage directories"
assert_missing "$metrics_podman" '${' "metrics stack resolves every variable on Podman"

# The exclusion regex had to be restructured to hold an absolute path
# (`^/(dev|...)` cannot interpolate `/var/lib/containers/storage`). Restructured
# is not rewritten: on Docker's values the new pattern must accept and reject
# exactly what the old one did.
note "the restructured exclusion regex is the same regex on Docker"
python3 - "$metrics_docker" <<'PY'
import json
import re
import sys

previous = r"^/(dev|proc|sys|run/docker/netns|var/lib/docker/.+)($|/)"
doc = json.load(open(sys.argv[1]))
command = doc["services"]["dune-node-exporter"]["command"]
flag = "--collector.filesystem.mount-points-exclude="
current = next(arg for arg in command if arg.startswith(flag))[len(flag):]

samples = [
    "/", "/dev", "/dev/shm", "/devices", "/proc", "/procfs", "/sys",
    "/sys/fs/cgroup", "/system", "/run", "/run/docker", "/run/docker/netns",
    "/run/docker/netns/abc", "/run/user/1000", "/var", "/var/lib",
    "/var/lib/docker", "/var/lib/docker/overlay2/x", "/var/lib/dockerfoo",
    "/var/lib/containers/storage", "/boot", "/home", "/srv/dune",
    "/dev/", "/var/lib/docker/", "xx/dev",
]
mismatched = [
    s for s in samples
    if bool(re.search(previous, s)) != bool(re.search(current, s))
]
if mismatched:
    print(f"previous: {previous}\ncurrent:  {current}", file=sys.stderr)
    print(f"differ on: {mismatched}", file=sys.stderr)
    raise SystemExit(1)
PY
ok "Docker's rendered exclusion regex accepts and rejects exactly what it always did"

echo "1..$test_no"
note "compose engine rendering tests completed"
