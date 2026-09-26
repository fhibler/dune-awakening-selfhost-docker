#!/usr/bin/env bash
# The orchestrator must still hold the engine socket's group after it drops
# privileges.
#
# `group_add` in docker-compose.yml delivers the socket's GID to the
# entrypoint's own process, not to /etc/group. runuser, su and gosu all call
# initgroups(), which replaces the process group set with the target user's
# /etc/group memberships and discards everything else without a word. On
# Docker that damage is invisible, because the socket's group is non-zero and
# the entrypoint recreates it as a real group. Rootful Podman's socket is
# root:root, no group can be created for GID 0, and the orchestrator loses
# access to the one socket its entire job is to drive.
#
# Every case below drives the real orchestrator/entrypoint.sh and asserts the
# group list it hands the privilege-drop program.
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

assert_line() {
  local file="$1" expected="$2" label="$3"
  if grep -Fxq -- "$expected" "$file"; then
    ok "$label"
    return 0
  fi
  echo "Expected line: $expected" >&2
  echo "--- recorded ---" >&2
  cat "$file" >&2
  echo "----------------" >&2
  fail "$label"
}

assert_no_line() {
  local file="$1" unexpected="$2" label="$3"
  if grep -Fxq -- "$unexpected" "$file"; then
    echo "Expected no line: $unexpected" >&2
    echo "--- recorded ---" >&2
    cat "$file" >&2
    echo "----------------" >&2
    fail "$label"
  fi
  ok "$label"
}

echo "TAP version 13"
note "orchestrator privilege-drop tests"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/state"

# dune is 1000:1000 with no supplementary memberships of its own until the
# entrypoint's groupadd/usermod add one, which is what FAKE_MEMBER_GIDS holds.
cat >"$tmpdir/bin/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -u) echo 1000 ;;
  -g) echo 1000 ;;
  -G)
    if [ -n "${2:-}" ]; then
      # dune's own memberships, as /etc/group would report them.
      printf '1000'
      [ -s "$FAKE_STATE/member-gids" ] && printf ' %s' "$(tr '\n' ' ' <"$FAKE_STATE/member-gids")"
      printf '\n'
    else
      # This process's group set, as group_add left it.
      printf '%s\n' "$FAKE_PROC_GROUPS"
    fi
    ;;
  *) echo "unexpected id args: $*" >&2; exit 1 ;;
esac
EOF

cat >"$tmpdir/bin/stat" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  '%u:%g') echo "1000:1000" ;;
  '%g') echo "${FAKE_SOCKET_GID:-0}" ;;
  *) echo "unexpected stat args: $*" >&2; exit 1 ;;
esac
EOF

cat >"$tmpdir/bin/mkdir" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$tmpdir/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown: %s\n' "$*" >>"$FAKE_STATE/calls"
exit 0
EOF

cat >"$tmpdir/bin/getent" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  passwd)
    [ "$2" = "dune" ] || exit 2
    echo "dune:x:1000:1000::/home/dune:/bin/bash"
    ;;
  group)
    grep -Fxq -- "$2" "$FAKE_STATE/groups" 2>/dev/null || exit 2
    echo "$2:x:0:"
    ;;
  *) exit 2 ;;
esac
EOF

cat >"$tmpdir/bin/groupadd" <<'EOF'
#!/usr/bin/env bash
printf 'groupadd: %s\n' "$*" >>"$FAKE_STATE/calls"
[ "${FAKE_GROUPADD_FAIL:-0}" = "1" ] && exit 4
printf '%s\n' "${3:-}" >>"$FAKE_STATE/groups"
printf '%s\n' "${2:-}" >>"$FAKE_STATE/pending-gids"
exit 0
EOF

cat >"$tmpdir/bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf 'usermod: %s\n' "$*" >>"$FAKE_STATE/calls"
# -aG <group> dune: reflect the membership the way /etc/group would.
tail -n 1 "$FAKE_STATE/pending-gids" >>"$FAKE_STATE/member-gids"
exit 0
EOF

# The write-test loop runs before the drop and is not what this test is about.
cat >"$tmpdir/bin/runuser" <<'EOF'
#!/usr/bin/env bash
printf 'runuser: %s\n' "$*" >>"$FAKE_STATE/calls"
exit 0
EOF

cat >"$tmpdir/bin/setpriv" <<'EOF'
#!/usr/bin/env bash
printf 'HOME=%s\nUSER=%s\nLOGNAME=%s\n' "${HOME:-}" "${USER:-}" "${LOGNAME:-}" >"$FAKE_STATE/drop"
printf 'arg: %s\n' "$@" >>"$FAKE_STATE/drop"
exit 0
EOF

chmod +x "$tmpdir"/bin/*

# Drive the real entrypoint for one scenario and leave the recording in
# $FAKE_STATE/drop.
run_entrypoint() {
  local socket_gid="$1" proc_groups="$2" groupadd_fail="$3" state
  state="$tmpdir/state"
  rm -rf "$state"
  mkdir -p "$state"
  : >"$state/groups"
  : >"$state/member-gids"
  : >"$state/pending-gids"
  : >"$state/calls"

  env -i \
    PATH="$tmpdir/bin:/usr/bin:/bin" \
    HOME=/root \
    FAKE_STATE="$state" \
    FAKE_PROC_GROUPS="$proc_groups" \
    FAKE_GROUPADD_FAIL="$groupadd_fail" \
    ${socket_gid:+DOCKER_SOCKET_GID="$socket_gid"} \
    bash "$repo_root/orchestrator/entrypoint.sh" dune daemon "two words" \
    >"$state/stdout" 2>&1
}

drop="$tmpdir/state/drop"

note "Docker: a non-zero socket group survives the drop"
run_entrypoint 992 "0 992" 0
assert_line "$drop" "arg: --reuid=1000" "drop targets dune's uid"
assert_line "$drop" "arg: --regid=1000" "drop targets dune's primary gid"
assert_line "$drop" "arg: --groups=992,1000" "socket group and dune's own group are both kept"
assert_line "$drop" "arg: --inh-caps=-all" "inheritable capabilities are dropped"
assert_no_line "$drop" "arg: --groups=0,992,1000" "root is not carried across when the socket does not need it"

note "the command and its argument boundaries survive the drop"
assert_line "$drop" "arg: dune" "first argument is passed through"
assert_line "$drop" "arg: daemon" "second argument is passed through"
assert_line "$drop" "arg: two words" "an argument containing a space stays one argument"

note "the drop reproduces the login environment runuser used to provide"
assert_line "$drop" "HOME=/home/dune" "HOME points at dune's home, where the Steam tree is mounted"
assert_line "$drop" "USER=dune" "USER names the runtime user"
assert_line "$drop" "LOGNAME=dune" "LOGNAME names the runtime user"

note "Podman: the rootful socket's group 0 survives the drop"
# The regression this whole file exists for. GID 0 cannot be recreated as a
# named group, so nothing puts it in dune's /etc/group memberships and every
# initgroups()-based drop silently discards it.
run_entrypoint 0 "0" 0
assert_line "$drop" "arg: --groups=0,1000" "rootful Podman's socket group is kept"

note "Podman with a SocketGroup= drop-in behaves like Docker"
run_entrypoint 974 "0 974" 0
assert_line "$drop" "arg: --groups=974,1000" "a named socket group is kept"
assert_no_line "$drop" "arg: --groups=0,974,1000" "root is not carried across for a named socket group"

note "an operator's extra --group-add is not dropped either"
run_entrypoint 992 "0 992 1500" 0
assert_line "$drop" "arg: --groups=992,1000,1500" "an inherited group the image knows nothing about is kept"

note "a groupadd collision no longer costs socket access"
# groupadd fails when the GID is already taken by another name. The old code
# then skipped usermod and dune quietly lost the socket on Docker too.
run_entrypoint 992 "0 992" 1
assert_line "$drop" "arg: --groups=992,1000" "the socket group is kept even when groupadd fails"

note "nothing reaches for a hardcoded docker group any more"
if grep -Eq 'usermod[^\n]*-aG[[:space:]]+docker[[:space:]]' "$repo_root/orchestrator/entrypoint.sh"; then
  fail "entrypoint still adds dune to a literal docker group"
fi
ok "entrypoint has no literal docker group membership"
if grep -v '^[[:space:]]*#' "$repo_root/orchestrator/Dockerfile" \
  | grep -Eq '(^|[[:space:]])docker\.io([[:space:]]|\\|$)'; then
  fail "orchestrator image still installs the docker.io package"
fi
ok "orchestrator image installs a client, not a second engine"

echo "1..$test_no"
note "orchestrator privilege-drop tests completed"
