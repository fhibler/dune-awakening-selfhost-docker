#!/usr/bin/env bash
# The installer's Podman bootstrap, exercised against the real install.sh.
#
# Everything here runs with PATH replaced by a curated directory of symlinks
# and stubs. That is heavier than shadowing one command, but it is the only
# way the package table, the engine fork and the socket work are decided by
# the test rather than by whatever the runner happens to have installed --
# GitHub's Ubuntu images ship both docker and podman.
#
# Nothing is executed with real privilege: the `sudo` stub records its
# arguments instead of running them, and captures stdin when it is asked to
# tee, which is how the socket drop-in is inspected without writing to /etc.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# shellcheck source=tests/lib/fake-engine.sh
. tests/lib/fake-engine.sh

failures=0
fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
bin="$test_root/bin"
capture="$test_root/capture"
# The installer cd's to its own directory and writes .env there. Run it from a
# directory of symlinks so that file lands in the test's scratch space and the
# working tree stays clean.
stage="$test_root/stage"
sudo_log="$test_root/sudo.log"
curl_log="$test_root/curl.log"
mkdir -p "$bin" "$capture" "$stage"
ln -s "$repo_root/install.sh" "$stage/install.sh"
ln -s "$repo_root/runtime" "$stage/runtime"
ln -s "$repo_root/docker-compose.web.yml" "$stage/docker-compose.web.yml"
stage_env="$stage/.env"

# The real tools install.sh and the libraries it sources reach for. A missing
# one would change the path under test, so it is an error rather than a skip.
for real_tool in sh bash cat cmp cut dirname grep head mkdir printf rm sed sleep stat tar touch tr uname awk install openssl gpg python3; do
  real_path="$(command -v "$real_tool" 2>/dev/null || true)"
  if [ -z "$real_path" ]; then
    echo "FAIL: this host has no $real_tool, which the installer needs" >&2
    exit 1
  fi
  ln -sf "$real_path" "$bin/$real_tool"
done

cat > "$bin/id" <<'EOF'
#!/bin/sh
case "${1:-}" in
  -u | -g) echo 1000 ;;
  -nG) echo "${FAKE_ID_GROUPS:-}" ;;
  *) echo "unexpected id $*" >&2; exit 2 ;;
esac
EOF

cat > "$bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
# `tee` is how the installer writes the socket drop-in. Capture the body under
# the test's own directory instead of letting it reach /etc.
if [ "${1:-}" = "tee" ]; then
  cat > "$FAKE_CAPTURE_DIR/$(printf '%s' "$2" | tr / _)"
fi
exit 0
EOF

cat > "$bin/getent" <<'EOF'
#!/bin/sh
[ "${1:-}" = "group" ] || exit 2
[ "${FAKE_GROUP_EXISTS:-1}" = "1" ] || exit 2
printf '%s:x:990:\n' "$2"
EOF

cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
# Only the unprivileged queries land here; everything that changes state goes
# through the sudo stub. is-active answers "no" so the installer takes its
# first-install path.
[ "${1:-}" = "is-active" ] && exit 3
exit 0
EOF

cat > "$bin/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
exit 1
EOF

cat > "$bin/podman" <<'EOF'
#!/bin/sh
exit 0
EOF

# podman-docker's shim, in its own directory so a scenario can decide whether
# this host has it. It answers `command -v docker` and reports podman.
shim="$test_root/shim"
mkdir -p "$shim"
cat > "$shim/docker" <<'EOF'
#!/bin/sh
[ "${1:-}" = "--version" ] && { echo "podman version 5.4.0"; exit 0; }
exit 0
EOF
chmod +x "$shim/docker"

# Podman's weak dependencies live in their own directory so a scenario can
# choose whether this host has them, by putting it on PATH or leaving it off.
helpers="$test_root/helpers"
mkdir -p "$helpers"
for podman_helper in netavark aardvark-dns catatonit; do
  printf '#!/bin/sh\nexit 0\n' > "$helpers/$podman_helper"
  chmod +x "$helpers/$podman_helper"
done

# Present so the installer can find them, never executed: both are privileged
# and therefore reach the sudo stub, which records instead of running.
for privileged_tool in dnf groupadd usermod; do
  cat > "$bin/$privileged_tool" <<EOF
#!/bin/sh
echo "$privileged_tool must not run directly; it goes through sudo" >&2
exit 1
EOF
done

chmod +x "$bin"/id "$bin"/sudo "$bin"/getent "$bin"/systemctl "$bin"/curl "$bin"/podman \
  "$bin"/dnf "$bin"/groupadd "$bin"/usermod

# has_systemd() wants a systemd host. Where there is not one, a mount
# namespace with a private /run supplies the directory it looks for; the
# scenarios that need it are skipped when even that is unavailable.
host_has_systemd=0
[ -d /run/systemd/system ] && host_has_systemd=1
can_fake_systemd=0
if [ "$host_has_systemd" = "0" ] && unshare -rm true 2>/dev/null; then
  can_fake_systemd=1
  mkdir -p "$test_root/run/systemd/system"
fi

installer_output=""
installer_status=0
installer_path=""
PATH_EXTRA=""
SEED_ENV=""

# Run the real installer with the curated PATH. Extra arguments are VAR=VALUE
# assignments for the scenario.
# PATH_EXTRA is how a scenario adds the podman helper stubs. `touch` is
# deliberately not in this PATH: nothing under test should reach the code that
# writes .env, and a 127 there is a louder failure than a dirtied repository.
run_installer() {
  installer_path="$bin${PATH_EXTRA:+:$PATH_EXTRA}${FAKE_ENGINE_DIR:+:$FAKE_ENGINE_DIR/bin}"
  : >"$sudo_log"
  : >"$curl_log"
  rm -rf "${capture:?}"/*
  rm -f "$stage_env"
  if [ -n "$SEED_ENV" ]; then
    printf '%s\n' "$SEED_ENV" > "$stage_env"
  fi

  set +e
  if [ "$host_has_systemd" = "1" ]; then
    installer_output="$(env -i "$@" \
      PATH="$installer_path" \
      HOME="$test_root" USER=dune \
      FAKE_ENGINE_DIR="${FAKE_ENGINE_DIR:-}" FAKE_ENGINE_LOG="${FAKE_ENGINE_LOG:-}" \
      FAKE_SUDO_LOG="$sudo_log" FAKE_CURL_LOG="$curl_log" FAKE_CAPTURE_DIR="$capture" \
      sh "$stage/install.sh" 2>&1)"
  else
    installer_output="$(unshare -rm sh -c '
      mount --bind "$1" /run || exit 97
      shift
      exec env -i "$@"' _ "$test_root/run" "$@" \
      PATH="$installer_path" \
      HOME="$test_root" USER=dune \
      FAKE_ENGINE_DIR="${FAKE_ENGINE_DIR:-}" FAKE_ENGINE_LOG="${FAKE_ENGINE_LOG:-}" \
      FAKE_SUDO_LOG="$sudo_log" FAKE_CURL_LOG="$curl_log" FAKE_CAPTURE_DIR="$capture" \
      sh "$stage/install.sh" 2>&1)"
  fi
  installer_status=$?
  set -e
}

report() {
  if [ "$installer_status" -eq 0 ]; then
    fail "$1: the installer was expected to stop, but it exited 0"
  fi
  if [ -n "${DUNE_TEST_DEBUG:-}" ]; then
    printf '\n--- %s (exit %s) ---\n%s\n' "$1" "$installer_status" "$installer_output" >&2
  fi
}

# --------------------------------------------------------------------------
# The package table: Podman's weak dependencies are asked for by name, and
# their absence stops the install instead of surfacing at runtime.
# --------------------------------------------------------------------------
run_installer DUNE_CONTAINER_ENGINE=podman
report "package table"

grep -Fq 'podman netavark aardvark-dns catatonit' "$sudo_log" \
  || fail "the Podman package list does not request netavark, aardvark-dns and catatonit by name"
grep -Fq 'netavark' <<<"$installer_output" \
  || fail "a missing netavark does not stop the install with a message naming it"
grep -Fq 'aardvark-dns' <<<"$installer_output" \
  || fail "a missing aardvark-dns does not stop the install with a message naming it"
grep -Fq 'catatonit' <<<"$installer_output" \
  || fail "a missing catatonit does not stop the install with a message naming it"
grep -Fq 'podman-plugins' "$sudo_log" \
  && fail "the package list still asks for podman-plugins, which Podman 5 dropped with CNI"

# --------------------------------------------------------------------------
# The Docker path is untouched: distro Compose package, and a missing docker
# group stays a warning rather than becoming fatal.
# --------------------------------------------------------------------------
(
  fake_engine_start docker
  fake_engine_exit_status "compose version" 1
  run_installer DUNE_CONTAINER_ENGINE=docker FAKE_GROUP_EXISTS=0 FAKE_ID_GROUPS=dune
  report "docker leg"

  grep -Fq 'Docker Compose is still not available after installation.' <<<"$installer_output" \
    || fail "the Docker leg no longer installs Compose from the distro"
  grep -Fq 'docker-compose-plugin' "$sudo_log" \
    || fail "the Docker leg no longer asks for the docker-compose-plugin package"
  grep -Fq 'Docker group does not exist yet' <<<"$installer_output" \
    || fail "a missing docker group is no longer survivable on the Docker leg"
  grep -Eq 'podman' "$sudo_log" \
    && fail "the Docker leg touched podman"
  grep -Fqx 'DUNE_ENGINE_RESTART_POLICY=unless-stopped' "$stage_env" \
    || fail "the Docker leg no longer renders unless-stopped for the Compose files"

  [ "$failures" -eq 0 ]
) || failures=$((failures + 1))

if [ "$host_has_systemd" = "0" ] && [ "$can_fake_systemd" = "0" ]; then
  echo "SKIP: no systemd and no usable mount namespace; the socket scenarios need one" >&2
else
  # ------------------------------------------------------------------------
  # The socket drop-in, podman-restart.service, and the Compose plugin.
  # ------------------------------------------------------------------------
  (
    fake_engine_start podman
    fake_engine_exit_status "compose version" 1
    PATH_EXTRA="$helpers"
    # A host migrated from Docker carries the old policy in .env, which is the
    # same reboot failure with the engines swapped.
    SEED_ENV="DUNE_ENGINE_RESTART_POLICY=unless-stopped"
    run_installer DUNE_CONTAINER_ENGINE=podman FAKE_ID_GROUPS=podman
    report "podman socket"

    dropin="$capture/_etc_systemd_system_podman.socket.d_10-dune-docker-compat.conf"
    if [ ! -f "$dropin" ]; then
      fail "no podman.socket drop-in was written (sudo log: $(tr '\n' ';' <"$sudo_log"))"
    else
      grep -Fqx 'ListenStream=' "$dropin" \
        || fail "the drop-in does not reset ListenStream, so podman gets two activation descriptors and refuses to start"
      grep -Fqx 'ListenStream=/var/run/docker.sock' "$dropin" \
        || fail "the drop-in does not publish the compat socket at /var/run/docker.sock"
      [ "$(grep -c '^ListenStream=' "$dropin")" -eq 2 ] \
        || fail "the drop-in does not leave exactly one listening socket"
      grep -Fqx 'SocketGroup=podman' "$dropin" \
        || fail "the drop-in does not hand the socket to the podman group"
      grep -Fqx 'SocketMode=0660' "$dropin" \
        || fail "the drop-in does not restrict the socket to its group"
    fi

    grep -Fq 'systemctl enable podman-restart.service' "$sudo_log" \
      || fail "podman-restart.service is not enabled, so nothing returns after a reboot"
    grep -Fq 'systemctl enable --now podman.socket' "$sudo_log" \
      || fail "podman.socket is not enabled"
    grep -Fq 'systemctl daemon-reload' "$sudo_log" \
      || fail "the new drop-in is never read back by systemd"
    grep -Fq 'already in the podman group' <<<"$installer_output" \
      || fail "group access is still checked against the docker group on a Podman host"
    grep -Fq 'docker-compose-plugin' "$sudo_log" \
      && fail "the Podman leg asks a distro for Compose, which would install podman-compose's label dialect"
    grep -Fq 'compose/releases/download/v2.29.7/docker-compose-linux-' "$curl_log" \
      || fail "the Podman leg does not fetch the pinned Compose v2 plugin"
    grep -Fqx 'DUNE_ENGINE_RESTART_POLICY=always' "$stage_env" \
      || fail "the Compose files will not render restart: always, so podman-restart.service revives nothing"
    [ "$(grep -c '^DUNE_ENGINE_RESTART_POLICY=' "$stage_env")" -eq 1 ] \
      || fail "the stale restart policy was appended to rather than replaced"

    [ "$failures" -eq 0 ]
  ) || failures=$((failures + 1))

  # ------------------------------------------------------------------------
  # The socket group is created before the socket needs it, and its absence
  # afterwards is fatal rather than a printed shrug.
  # ------------------------------------------------------------------------
  (
    fake_engine_start podman
    PATH_EXTRA="$helpers"
    run_installer DUNE_CONTAINER_ENGINE=podman FAKE_GROUP_EXISTS=0
    report "socket group"

    grep -Eq 'groupadd (--system|-r) podman|addgroup -S podman' "$sudo_log" \
      || fail "the podman socket group is never created"
    grep -Fq 'group is missing' <<<"$installer_output" \
      || fail "a missing socket group does not stop the install on a Podman host"

    [ "$failures" -eq 0 ]
  ) || failures=$((failures + 1))
fi

# --------------------------------------------------------------------------
# podman-docker's shim answers `command -v docker` but routes `docker compose`
# to `podman compose`, which ignores the plugin directory this installer fills.
# It must not be mistaken for the real CLI.
# --------------------------------------------------------------------------
(
  PATH_EXTRA="$helpers:$shim"
  run_installer DUNE_CONTAINER_ENGINE=podman
  report "podman-docker shim"

  grep -Fq "podman-docker's shim" <<<"$installer_output" \
    || fail "the podman-docker shim is accepted as the real Docker CLI"
  grep -Fq 'download.docker.com/linux/static/stable/' "$curl_log" \
    || fail "the installer does not fetch the real Docker CLI over the shim"
  grep -Fq 'docker-27.5.1.tgz' "$curl_log" \
    || fail "the Docker CLI download is not pinned to the console image's version"

  [ "$failures" -eq 0 ]
) || failures=$((failures + 1))

# --------------------------------------------------------------------------
# The CLI and plugin versions are pinned in two files that must agree: the
# host talks to the same socket the console container does, and a skew shows
# up as a Compose file that parses in one place and not the other.
# --------------------------------------------------------------------------
installer_cli_version="$(sed -n 's/^DOCKER_CLI_VERSION="\(.*\)"$/\1/p' install.sh)"
installer_compose_version="$(sed -n 's/^DOCKER_COMPOSE_VERSION="\(.*\)"$/\1/p' install.sh)"
[ -n "$installer_cli_version" ] || fail "install.sh does not pin a Docker CLI version"
[ -n "$installer_compose_version" ] || fail "install.sh does not pin a Compose version"
grep -Fq "docker-${installer_cli_version}.tgz" console/api/Dockerfile \
  || fail "install.sh pins Docker CLI $installer_cli_version but console/api/Dockerfile ships another"
grep -Fq "v${installer_compose_version}/docker-compose-linux-" console/api/Dockerfile \
  || fail "install.sh pins Compose $installer_compose_version but console/api/Dockerfile ships another"

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures check(s)" >&2
  exit 1
fi

echo "PASS: the installer bootstraps Podman, publishes the compat socket, and leaves the Docker path alone"
