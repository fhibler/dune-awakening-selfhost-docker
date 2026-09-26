#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

bin_dir="$test_root/bin"
mkdir -p "$bin_dir" "$test_root/runtime/scripts/lib"
cp runtime/scripts/lib/engine.sh "$test_root/runtime/scripts/lib/engine.sh"
cp runtime/scripts/env-file.sh "$test_root/runtime/scripts/env-file.sh"
cp runtime/scripts/host-file-ownership.sh "$test_root/runtime/scripts/host-file-ownership.sh"

cat > "$bin_dir/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_DOCKER_LOG"

case "${1:-} ${2:-}" in
  "ps --format")
    printf '%s\n' dune-postgres
    ;;
  "exec dune-postgres")
    shift 2
    case "${1:-}" in
      psql)
        printf '%s\n' "${MOCK_PARTITION_COUNT:-30}"
        ;;
      pg_dump)
        ;;
      pg_restore)
        if [ "${2:-}" = "-U" ]; then
          maintenance_file="${DUNE_DB_RESTORE_MAINTENANCE_FILE:-runtime/generated/db-restore-maintenance}"
          if [ ! -f "$maintenance_file" ]; then
            echo "database restore ran without Console maintenance protection" >&2
            exit 97
          fi
          if [ "${MOCK_RESTORE_FAIL:-0}" = "1" ]; then
            echo "mock restore failure" >&2
            exit 42
          fi
        fi
        if [ "${MOCK_ARCHIVE_VALID:-1}" = "1" ]; then
          cat <<'TOC'
5; 2615 16385 SCHEMA - dune dune
212; 1259 16432 TABLE dune world_partition dune
3872; 0 16432 TABLE DATA dune world_partition dune
TOC
        else
          printf '%s\n' '1; 1262 12345 DATABASE - dune postgres'
        fi
        ;;
      rm)
        ;;
    esac
    ;;
  "cp dune-postgres:"*)
    destination="${3:-}"
    mkdir -p "$(dirname "$destination")"
    printf '%s\n' mock-custom-archive > "$destination"
    ;;
  "cp "*)
    ;;
esac
EOF
chmod +x "$bin_dir/docker"

run_backup_case() {
  local name="$1"
  local partition_count="$2"
  local archive_valid="$3"
  local expected_exit="$4"
  local case_root="$test_root/$name"
  local output="$case_root/output.log"
  local docker_log="$case_root/docker.log"

  mkdir -p "$case_root/work/runtime/generated" "$case_root/backups"
  cp runtime/scripts/db.sh "$case_root/work/db.sh"

  set +e
  (
    cd "$case_root/work"
    PATH="$bin_dir:$PATH" \
      MOCK_DOCKER_LOG="$docker_log" \
      MOCK_PARTITION_COUNT="$partition_count" \
      MOCK_ARCHIVE_VALID="$archive_valid" \
      bash ./db.sh backup "$case_root/backups"
  ) > "$output" 2>&1
  local actual_exit=$?
  set -e

  if [ "$actual_exit" -ne "$expected_exit" ]; then
    echo "FAIL $name: expected exit $expected_exit, got $actual_exit"
    cat "$output"
    exit 1
  fi

  if [ "$expected_exit" -eq 0 ]; then
    [ "$(find "$case_root/backups" -maxdepth 1 -name '*.backup' | wc -l)" -eq 1 ]
    [ "$(find "$case_root/backups" -maxdepth 1 -name '*.backup.yaml' | wc -l)" -eq 1 ]
  else
    if find "$case_root/backups" -maxdepth 1 -type f | grep -q .; then
      echo "FAIL $name: rejected backup left a published or partial artifact"
      find "$case_root/backups" -maxdepth 1 -type f -print
      exit 1
    fi
  fi

  echo "PASS $name"
}

run_backup_case valid-dune-backup 30 1 0
run_backup_case empty-live-database 0 1 1
run_backup_case missing-dune-archive 30 0 1

restore_root="$test_root/invalid-restore"
mkdir -p "$restore_root/work/runtime/generated"
cp runtime/scripts/db.sh "$restore_root/work/db.sh"
printf '%s\n' mock-empty-database-archive > "$restore_root/empty.backup"

set +e
(
  cd "$restore_root/work"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$restore_root/docker.log" \
    MOCK_PARTITION_COUNT=30 \
    MOCK_ARCHIVE_VALID=0 \
    DUNE_DB_ASSUME_YES=1 \
    bash ./db.sh restore "$restore_root/empty.backup" --no-safety-backup
) > "$restore_root/output.log" 2>&1
restore_exit=$?
set -e

if [ "$restore_exit" -eq 0 ]; then
  echo "FAIL invalid-restore: empty archive was accepted"
  cat "$restore_root/output.log"
  exit 1
fi
grep -q 'Restore aborted before any database changes were made' "$restore_root/output.log"
if grep -Eq 'drop database|start-all|stop-all' "$restore_root/docker.log"; then
  echo "FAIL invalid-restore: destructive work ran after validation failure"
  cat "$restore_root/docker.log"
  exit 1
fi
echo "PASS invalid-restore-aborts-before-database-changes"

identity_root="$test_root/identity-choice"
mkdir -p "$identity_root/runtime/scripts/lib" "$identity_root/runtime/generated" "$identity_root/runtime/secrets"
cp runtime/scripts/db.sh runtime/scripts/env-file.sh runtime/scripts/host-file-ownership.sh "$identity_root/runtime/scripts/"
cp runtime/scripts/lib/engine.sh "$identity_root/runtime/scripts/lib/engine.sh"
printf '%s\n' mock-valid-archive > "$identity_root/manual.backup"
cat > "$identity_root/manual.backup.yaml" <<'EOF'
backup_origin: manual
battlegroup_id: sh-bbbbbbbbbbbbbbbb-original
EOF
printf 'BATTLEGROUP_ID=sh-aaaaaaaaaaaaaaaa-current\n' > "$identity_root/runtime/generated/battlegroup.env"

set +e
(
  cd "$identity_root"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$identity_root/no-choice-docker.log" \
    MOCK_ARCHIVE_VALID=1 \
    DUNE_DB_ASSUME_YES=1 \
    bash runtime/scripts/db.sh restore "$identity_root/manual.backup" --no-safety-backup
) > "$identity_root/no-choice.log" 2>&1
no_choice_exit=$?
set -e
[ "$no_choice_exit" -ne 0 ] || fail "mismatched manual backup restored without an explicit identity choice"
grep -Fq 'choose --adopt-backup-battlegroup or --keep-current-battlegroup' "$identity_root/no-choice.log" \
  || fail "mismatched manual backup did not explain the required identity choice"
if grep -Eq 'drop database|create database|rm -f dune-server' "$identity_root/no-choice-docker.log"; then
  fail "identity-choice failure allowed destructive restore work"
fi
echo "PASS manual-backup-mismatch-fails-before-changes-without-explicit-choice"

TOKEN_HOST_ID="aaaaaaaaaaaaaaaa" python3 - "$identity_root/runtime/secrets/funcom-token.txt" <<'PY'
import base64
import json
import os
import sys

payload = base64.urlsafe_b64encode(json.dumps({"HostId": os.environ["TOKEN_HOST_ID"]}).encode()).decode().rstrip("=")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"header.{payload}.signature\n")
PY

set +e
(
  cd "$identity_root"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$identity_root/wrong-token-docker.log" \
    MOCK_ARCHIVE_VALID=1 \
    DUNE_DB_ASSUME_YES=1 \
    bash runtime/scripts/db.sh restore "$identity_root/manual.backup" --no-safety-backup --adopt-backup-battlegroup
) > "$identity_root/wrong-token.log" 2>&1
wrong_token_exit=$?
set -e
[ "$wrong_token_exit" -ne 0 ] || fail "backup Battlegroup adoption accepted an incompatible Funcom token"
grep -Fq 'current Funcom token does not belong to backup Battlegroup' "$identity_root/wrong-token.log" \
  || fail "incompatible-token rejection was not explained"
if grep -Eq 'drop database|create database|rm -f dune-server' "$identity_root/wrong-token-docker.log"; then
  fail "token-validation failure allowed destructive restore work"
fi
echo "PASS backup-adoption-rejects-incompatible-token-before-changes"

TOKEN_HOST_ID="bbbbbbbbbbbbbbbb" python3 - "$identity_root/runtime/secrets/funcom-token.txt" <<'PY'
import base64
import json
import os
import sys

payload = base64.urlsafe_b64encode(json.dumps({"HostId": os.environ["TOKEN_HOST_ID"]}).encode()).decode().rstrip("=")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(f"header.{payload}.signature\n")
PY
printf 'BATTLEGROUP_ID=sh-aaaaaaaaaaaaaaaa-current\nSERVER_TITLE="Identity Test"\n' > "$identity_root/runtime/generated/battlegroup.env"
printf 'y\nn\n' | (
  cd "$identity_root"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$identity_root/adopt-docker.log" \
    MOCK_ARCHIVE_VALID=1 \
    bash runtime/scripts/db.sh restore "$identity_root/manual.backup" --no-safety-backup --adopt-backup-battlegroup
) > "$identity_root/adopt.log" 2>&1
grep -Fq 'BATTLEGROUP_ID=sh-bbbbbbbbbbbbbbbb-original' "$identity_root/runtime/generated/battlegroup.env" \
  || fail "explicit adoption did not preserve the backup Battlegroup identity"
grep -Fq 'PREVIOUS_BATTLEGROUP_ID=sh-aaaaaaaaaaaaaaaa-current' "$identity_root/runtime/generated/battlegroup-restore-point.env" \
  || fail "explicit adoption did not create a rollback point"
grep -Fq 'Database import finished.' "$identity_root/adopt.log" \
  || fail "compatible explicit adoption did not finish the mocked restore"
[ ! -e "$identity_root/runtime/generated/db-restore-maintenance" ] \
  || fail "successful restore left Console database maintenance enabled"
echo "PASS compatible-explicit-adoption-preserves-identity-and-rollback"

rm -f "$identity_root/runtime/generated/battlegroup-restore-point.env"
printf 'BATTLEGROUP_ID=sh-aaaaaaaaaaaaaaaa-current\nSERVER_TITLE="Identity Test"\n' > "$identity_root/runtime/generated/battlegroup.env"
printf 'y\nn\n' | (
  cd "$identity_root"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$identity_root/keep-docker.log" \
    MOCK_ARCHIVE_VALID=1 \
    bash runtime/scripts/db.sh restore "$identity_root/manual.backup" --no-safety-backup --keep-current-battlegroup
) > "$identity_root/keep.log" 2>&1
grep -Fq 'BATTLEGROUP_ID=sh-aaaaaaaaaaaaaaaa-current' "$identity_root/runtime/generated/battlegroup.env" \
  || fail "explicit keep-current restore changed the current Battlegroup identity"
[ ! -e "$identity_root/runtime/generated/battlegroup-restore-point.env" ] \
  || fail "keep-current restore created an adoption rollback point"
grep -Fq 'Characters associated with sh-bbbbbbbbbbbbbbbb-original may not appear in game.' "$identity_root/keep.log" \
  || fail "keep-current restore did not warn about character visibility"
echo "PASS explicit-keep-current-preserves-current-identity"

set +e
(
  cd "$identity_root"
  PATH="$bin_dir:$PATH" \
    MOCK_DOCKER_LOG="$identity_root/failed-restore-docker.log" \
    MOCK_ARCHIVE_VALID=1 \
    MOCK_RESTORE_FAIL=1 \
    DUNE_DB_ASSUME_YES=1 \
    bash runtime/scripts/db.sh restore "$identity_root/manual.backup" --no-safety-backup --keep-current-battlegroup
) > "$identity_root/failed-restore.log" 2>&1
failed_restore_exit=$?
set -e
[ "$failed_restore_exit" -ne 0 ] || fail "mocked pg_restore failure was accepted"
[ ! -e "$identity_root/runtime/generated/db-restore-maintenance" ] \
  || fail "failed restore left Console database maintenance enabled"
grep -Fq 'mock restore failure' "$identity_root/failed-restore.log" \
  || fail "mocked pg_restore failure was not preserved"
echo "PASS failed-restore-clears-console-database-maintenance"
