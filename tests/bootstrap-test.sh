#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

test_root="$(mktemp -d)"
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/release/dune-awakening-selfhost-docker-v9.8.7"
printf '#!/bin/sh\nexit 0\n' >"$test_root/release/dune-awakening-selfhost-docker-v9.8.7/install.sh"
tar -czf "$test_root/release.tar.gz" -C "$test_root/release" dune-awakening-selfhost-docker-v9.8.7

cat >"$test_root/bin/curl" <<'SH'
#!/bin/sh
output=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then
    output="$2"
    shift 2
    continue
  fi
  shift
done
if [ -n "$output" ]; then
  cp "$BOOTSTRAP_FIXTURE_ARCHIVE" "$output"
else
  printf '%s\n' '{"tag_name":"v9.8.7"}'
fi
SH
chmod +x "$test_root/bin/curl"

install_dir="$test_root/disk/dune-awakening-selfhost-docker"
mkdir -p "$test_root/disk"
PATH="$test_root/bin:$PATH" \
BOOTSTRAP_FIXTURE_ARCHIVE="$test_root/release.tar.gz" \
DUNE_BOOTSTRAP_SKIP_INSTALL=1 \
DUNE_INSTALL_DIR="$install_dir" \
  sh bootstrap.sh >/dev/null
test -x "$install_dir/install.sh"
test -z "$(find "$test_root/disk" -maxdepth 1 -name '.dune-*' -print -quit)"

if PATH="$test_root/bin:$PATH" \
  BOOTSTRAP_FIXTURE_ARCHIVE="$test_root/release.tar.gz" \
  DUNE_BOOTSTRAP_SKIP_INSTALL=1 \
  DUNE_INSTALL_DIR="$install_dir" \
    sh bootstrap.sh >"$test_root/retry.out" 2>"$test_root/retry.err"; then
  echo "bootstrap unexpectedly overwrote an existing installation" >&2
  exit 1
fi
grep -q 'already contains Dune Docker' "$test_root/retry.err"

cat >"$test_root/bin/uname" <<'SH'
#!/bin/sh
printf '%s\n' '6.6.87.2-microsoft-standard-WSL2 docker-desktop linuxkit'
SH
chmod +x "$test_root/bin/uname"
if PATH="$test_root/bin:$PATH" DUNE_INSTALL_DIR="$test_root/desktop-target" sh bootstrap.sh \
    >"$test_root/desktop.out" 2>"$test_root/desktop.err"; then
  echo "bootstrap unexpectedly accepted Docker Desktop's internal environment" >&2
  exit 1
fi
grep -q "Docker Desktop's internal Linux environment" "$test_root/desktop.err"

echo "bootstrap stages releases safely and rejects Docker Desktop's internal shell"
