#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

mkdir -p "$test_root/project/runtime/scripts/lib" "$test_root/bin" "$test_root/state"
cp "$repo_root/runtime/scripts/update.sh" "$test_root/project/runtime/scripts/update.sh"
cp "$repo_root/runtime/scripts/doctor.sh" "$test_root/project/runtime/scripts/doctor.sh"
cp "$repo_root/runtime/scripts/runtime-env.sh" "$test_root/project/runtime/scripts/runtime-env.sh"
cp "$repo_root/runtime/scripts/host-file-ownership.sh" "$test_root/project/runtime/scripts/host-file-ownership.sh"
cp "$repo_root/runtime/scripts/env-file.sh" "$test_root/project/runtime/scripts/env-file.sh"
cp "$repo_root/runtime/scripts/memory-swap-common.sh" "$test_root/project/runtime/scripts/memory-swap-common.sh"
cp "$repo_root/runtime/scripts/compose-project.sh" "$test_root/project/runtime/scripts/compose-project.sh"
cp "$repo_root/runtime/scripts/steamcmd-signals.sh" "$test_root/project/runtime/scripts/steamcmd-signals.sh"
cp "$repo_root/runtime/scripts/fls-signals.sh" "$test_root/project/runtime/scripts/fls-signals.sh"
# runtime-env.sh sources this as of the age-based secrets library
# Stage 2 rollout
cp "$repo_root/runtime/scripts/lib/engine.sh" "$test_root/project/runtime/scripts/lib/engine.sh"
cp "$repo_root/runtime/scripts/lib/secrets.sh" "$test_root/project/runtime/scripts/lib/secrets.sh"
cp "$repo_root/runtime/scripts/lib/secrets_aead.py" "$test_root/project/runtime/scripts/lib/secrets_aead.py"

cat > "$test_root/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
command_name="${1:-}"
unit="${2:-}"
case "$command_name" in
  show)
    property=""
    for argument in "$@"; do
      case "$argument" in
        --property=*) property="${argument#--property=}" ;;
      esac
    done
    case "$property" in
      LoadState) echo loaded ;;
      WorkingDirectory) echo "${MOCK_WORKDIR:?}" ;;
      ExecStart)
        case "${MOCK_EXEC_STYLE:-current}" in
          current) echo "{ path=${MOCK_WORKDIR:?}/runtime/scripts/update.sh ; argv[]=${MOCK_WORKDIR:?}/runtime/scripts/update.sh auto run ; }" ;;
          legacy) echo "{ path=${MOCK_WORKDIR:?}/runtime/scripts/dune ; argv[]=${MOCK_WORKDIR:?}/runtime/scripts/dune update --yes ; }" ;;
          outside) echo "{ path=/home/old/dune/runtime/scripts/update.sh ; argv[]=/home/old/dune/runtime/scripts/update.sh auto run ; }" ;;
        esac
        ;;
    esac
    ;;
  is-active) echo active ;;
  is-enabled) echo enabled ;;
  list-timers) echo "mock timer listing for $unit" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$test_root/bin/systemctl"

cat > "$test_root/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "image inspect") exit 0 ;;
esac
[ "${1:-}" = "run" ] && exit 0
exit 1
EOF
chmod +x "$test_root/bin/docker"

cat > "$test_root/project/runtime/scripts/repair-host-runtime-permissions.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(dirname "${DUNE_AUTO_UPDATE_STATE_FILE:?}")"
chmod u+rwx "$state_dir"
[ ! -e "$DUNE_AUTO_UPDATE_STATE_FILE" ] || chmod u+rw "$DUNE_AUTO_UPDATE_STATE_FILE"
EOF
chmod +x "$test_root/project/runtime/scripts/repair-host-runtime-permissions.sh"

state_file="$test_root/state/update-auto.env"
cat > "$state_file" <<'EOF'
DUNE_AUTO_UPDATE_ENABLED=0
DUNE_AUTO_UPDATE_INTERVAL_MINUTES=60
DUNE_AUTO_UPDATE_TIMER_INSTALLED=1
EOF

run_status() {
  (
    cd "$test_root/project"
    PATH="$test_root/bin:$PATH" \
      MOCK_WORKDIR="$1" \
      MOCK_EXEC_STYLE="${2:-current}" \
      DUNE_HOST_REPO_ROOT="$test_root/project" \
      DUNE_AUTO_UPDATE_STATE_FILE="$state_file" \
      bash runtime/scripts/update.sh auto status
  )
}

output="$(run_status "$test_root/project")"
grep -Fq "Systemd timer: active" <<<"$output"
grep -Fq "WARN Auto-update timer is active while auto updates are disabled in this checkout." <<<"$output"
if grep -Fq "Auto update time:" <<<"$output"; then
  printf 'Interval-based status still displayed the legacy daily update time:\n%s\n' "$output" >&2
  exit 1
fi

sed -i 's/DUNE_AUTO_UPDATE_ENABLED=0/DUNE_AUTO_UPDATE_ENABLED=1/' "$state_file"
output="$(run_status /home/old/dune-work/e2e-ops-health outside)"
grep -Fq "Systemd timer: active" <<<"$output"
grep -Fq "WARN Auto-update service uses WorkingDirectory=/home/old/dune-work/e2e-ops-health; expected $test_root/project." <<<"$output"
grep -Fq "WARN Auto-update service ExecStart points outside the current checkout: $test_root/project." <<<"$output"

output="$(run_status "$test_root/project" legacy)"
grep -Fq "WARN Auto-update service uses the legacy update command from the current checkout." <<<"$output"
grep -Fq "Repair: dune update auto enable 60 1 1 15,10,5,1 0 360" <<<"$output"

set +e
doctor_output="$(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" \
    MOCK_WORKDIR="$test_root/project" \
    MOCK_EXEC_STYLE=legacy \
    DUNE_HOST_REPO_ROOT="$test_root/project" \
    bash runtime/scripts/doctor.sh 2>&1
)"
set -e
grep -Fq "WARN Auto-update timer uses the legacy update command from the current checkout" <<<"$doctor_output"
grep -Fq "Repair: dune update auto enable 60 1 1 15,10,5,1 0 360" <<<"$doctor_output"

output="$(run_status "$test_root/project")"
if grep -q '^WARN ' <<<"$output"; then
  printf 'Healthy timer unexpectedly reported a warning:\n%s\n' "$output" >&2
  exit 1
fi

chmod u-w "$test_root/state"
repair_output="$(
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" \
    MOCK_WORKDIR="$test_root/project" \
    DUNE_HOST_REPO_ROOT="$test_root/project" \
    DUNE_AUTO_UPDATE_STATE_FILE="$state_file" \
    bash runtime/scripts/update.sh auto enable 60 1 1 20,10,5,1 0 360
)"
grep -Fq "Host runtime state is not writable; repairing host-managed runtime ownership..." <<<"$repair_output"
grep -Fq "Host runtime ownership repaired." <<<"$repair_output"
grep -Fq "DUNE_AUTO_UPDATE_ENABLED=1" "$state_file"
grep -Fq "DUNE_AUTO_UPDATE_NOTIFY_MINUTES=20,10,5,1" "$state_file"

if (
  cd "$test_root/project"
  PATH="$test_root/bin:$PATH" \
    DUNE_HOST_REPO_ROOT="$test_root/project" \
    DUNE_AUTO_UPDATE_STATE_FILE="$state_file" \
    bash runtime/scripts/update.sh auto enable 60 1 1 15,40,10,5 0 360
) >/dev/null 2>&1; then
  echo "Out-of-order automatic-update warning times were unexpectedly accepted." >&2
  exit 1
fi

echo "auto-update status detects disabled, legacy, and stale systemd timers and repairs state ownership"
