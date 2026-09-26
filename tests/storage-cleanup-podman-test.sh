#!/usr/bin/env bash
# The Podman leg of storage.sh. Its sibling storage-cleanup-test.sh covers the
# Docker leg; this covers only the three places Podman answers differently,
# each of which silently loses an image or prints the wrong command:
#
#   * locally built images live under localhost/, so the protected set has to
#     ask for them by that name or an in-use image drops out of it;
#   * the compat endpoints are inconsistent about the sha256: digest prefix,
#     and the protected set is matched whole-line;
#   * there is no `docker builder prune` to run.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/repo/runtime/generated" "$TEST_ROOT/repo/runtime/scripts/lib"
cp "$REPO_ROOT/runtime/scripts/storage.sh" "$TEST_ROOT/repo/runtime/scripts/storage.sh"
cp "$REPO_ROOT/runtime/scripts/lib/engine.sh" "$TEST_ROOT/repo/runtime/scripts/lib/engine.sh"
export DUNE_CONTAINER_ENGINE=podman
cat > "$TEST_ROOT/repo/runtime/generated/image-tags.env" <<'EOF'
DUNE_WORLD_IMAGE_TAG=current
DUNE_POSTGRES_IMAGE_TAG=pg-current
EOF

# Digests come back bare from `inspect .Image` and prefixed from `image ls`,
# which is the Podman inconsistency the normalisation in storage.sh exists for.
cat > "$TEST_ROOT/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"

case "$*" in
  info) exit 0 ;;
  "container ls -aq") printf '%s\n' live-container ;;
  "inspect --format {{.Image}} live-container") printf '%s\n' used-old ;;
  "image inspect --format {{.Id}} registry.funcom.com/funcom/self-hosting/seabass-server:current")
    printf '%s\n' sha256:current-world ;;
  "image inspect --format {{.Id}} localhost/dune-orchestrator:dev")
    printf '%s\n' sha256:required-orchestrator ;;
  "image inspect --format {{.Id}} localhost/redblink-dune-docker-console:dev")
    printf '%s\n' sha256:required-console ;;
  image\ inspect\ --format*sha256:required-orchestrator)
    printf '%s\n' orchestrator ;;
  image\ inspect\ --format*sha256:old-console)
    printf '%s\n' console ;;
  "image inspect --format "*) exit 1 ;;
  "image ls --no-trunc --format {{.Repository}}|{{.Tag}}|{{.ID}}")
    cat <<'IMAGES'
registry.funcom.com/funcom/self-hosting/seabass-server|current|sha256:current-world
registry.funcom.com/funcom/self-hosting/seabass-server|old|sha256:old-world
registry.funcom.com/funcom/self-hosting/seabass-server-gateway|old|sha256:used-old
IMAGES
    ;;
  "image ls --no-trunc --filter label=io.github.red-blink.dune-selfhost.component --format {{.Repository}}|{{.Tag}}|{{.ID}}")
    cat <<'IMAGES'
localhost/dune-orchestrator|dev|sha256:required-orchestrator
localhost/redblink-dune-docker-console|<none>|sha256:old-console
IMAGES
    ;;
  *) echo "Unexpected fake Podman call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/docker"

export PATH="$TEST_ROOT/bin:$PATH"
export FAKE_DOCKER_LOG="$TEST_ROOT/docker.log"
cd "$TEST_ROOT/repo"

dry_output="$(runtime/scripts/storage.sh cleanup --dry-run)"
if ! grep -q 'WOULD REMOVE .*seabass-server:old (sha256:old-world)' <<<"$dry_output"; then
  echo "An obsolete game image was not offered for cleanup on the Podman leg:" >&2
  echo "$dry_output" >&2
  exit 1
fi
if ! grep -q 'WOULD REMOVE localhost/redblink-dune-docker-console:<none> (sha256:old-console)' <<<"$dry_output"; then
  echo "A dangling project image under localhost/ was not offered for cleanup:" >&2
  echo "$dry_output" >&2
  exit 1
fi

# used-old is protected only if the bare digest from `inspect .Image` compares
# equal to the sha256:-prefixed one from `image ls`.
if grep -q 'used-old' <<<"$dry_output"; then
  echo "An image still used by a container was offered for cleanup; digest normalisation is not protecting it." >&2
  echo "$dry_output" >&2
  exit 1
fi
# required-orchestrator is protected only if it was looked up under localhost/.
if grep -Eq 'current-world|required-orchestrator|required-console' <<<"$dry_output"; then
  echo "A protected image was offered for cleanup on the Podman leg:" >&2
  echo "$dry_output" >&2
  exit 1
fi
grep -qx 'image inspect --format {{.Id}} localhost/dune-orchestrator:dev' "$FAKE_DOCKER_LOG"
grep -qx 'image inspect --format {{.Id}} localhost/redblink-dune-docker-console:dev' "$FAKE_DOCKER_LOG"

cache_output="$(runtime/scripts/storage.sh cleanup --dry-run --build-cache)"
grep -q 'WOULD RUN podman system prune --build --force' <<<"$cache_output"
if grep -q 'builder prune' <<<"$cache_output"; then
  echo "The build-cache preview still advertises a command Podman does not have:" >&2
  echo "$cache_output" >&2
  exit 1
fi

echo "storage cleanup Podman leg tests passed"
