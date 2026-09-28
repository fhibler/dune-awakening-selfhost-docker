#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2016,SC2034,SC2317
# Regression coverage for periodic Sietch state publication. RabbitMQ route
# maintenance must not block Survival state long enough for Director to mark
# otherwise-ready Sietches offline.
set -euo pipefail

cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "$file missing: $pattern"
}

SCRIPT="runtime/scripts/publish-sietch-overrides.sh"
SIETCH_SCRIPT="runtime/scripts/sietches.sh"
AUTOSCALER_SCRIPT="runtime/scripts/autoscaler.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# Published browser state must use the same merged UserEngine identity that the
# game server receives. Reading the legacy JSON mirror here caused scheduled
# restarts and Console updates to republish stale names and empty passwords.
assert_contains "$SCRIPT" 'identity = usersettings.merged_partition_engine_values('
assert_contains "$SCRIPT" 'display_name = str(identity.get("server_display_name") or "").strip()'
assert_contains "$SCRIPT" 'password = str(identity.get("server_login_password") or "")'
if grep -Eq 'display_name = cfg\.get\("display_name"|password = cfg\.get\("password"' "$SCRIPT"; then
  fail "$SCRIPT must not publish identity fields from the legacy Sietch JSON mirror"
fi
assert_contains "$SIETCH_SCRIPT" 'def effective_identity(map_name, pid):'
assert_contains "$SIETCH_SCRIPT" 'identity.get("server_login_password")'
if grep -Fq 'if entry.get("password"):' "$SIETCH_SCRIPT"; then
  fail "$SIETCH_SCRIPT must not restart a Sietch with a password from the legacy JSON mirror"
fi

# Valid cached credentials remain in use until RabbitMQ rejects them. Refreshing
# them solely because they are five minutes old caused the observed cadence.
assert_contains "$SCRIPT" 'if [ -r "$RMQ_CREDS_FILE" ]; then'
assert_contains "$SCRIPT" 'rm -f "$RMQ_CREDS_FILE"'
if grep -Fq 'RMQ_CREDS_TTL_SECONDS' "$SCRIPT"; then
  fail "$SCRIPT must retain valid cached RabbitMQ credentials until a command rejects them"
fi

CACHED_CREDS="$TMP_DIR/cached-rmq-creds"
printf '%s\n' "cached-user" "cached-password" >"$CACHED_CREDS"
touch -d '2 hours ago' "$CACHED_CREDS"

CREDENTIAL_RESULT="$(
  source "$SCRIPT"
  RMQ_CREDS_FILE="$CACHED_CREDS"
  ensure_text_router_log() {
    fail "valid cached credentials unexpectedly triggered a log scan"
  }
  load_rmq_admin_creds
)"

[ "$CREDENTIAL_RESULT" = $'cached-user\ncached-password' ] \
  || fail "expected valid cached credentials to remain usable regardless of age"

SHARED_CREDS="$TMP_DIR/shared-rmq-creds"
MISSING_PRIMARY_CREDS="$TMP_DIR/missing-primary-rmq-creds"
printf '%s\n' "shared-user" "shared-password" >"$SHARED_CREDS"
SHARED_CREDENTIAL_RESULT="$(
  source "$SCRIPT"
  RMQ_CREDS_FILE="$MISSING_PRIMARY_CREDS"
  SHARED_RMQ_CREDS_FILES=("$SHARED_CREDS")
  ensure_text_router_log() {
    fail "valid shared credentials unexpectedly triggered a log scan"
  }
  load_rmq_admin_creds true
)"

[ "$SHARED_CREDENTIAL_RESULT" = $'shared-user\nshared-password' ] \
  || fail "expected the Sietch publisher to reuse a sibling publisher credential cache"

# Routine route verification fails at its first RabbitMQ error and never purges
# the active source queue. A purge is allowed only during initial setup.
assert_contains "$SCRIPT" 'local purge_existing="${1:-false}"'
assert_contains "$SCRIPT" 'if [ "$purge_existing" = "true" ]; then'
assert_contains "$SCRIPT" 'rmq_admin purge queue name="$SOURCE_FILTER_QUEUE" >/dev/null || return 1'
assert_contains "$SCRIPT" 'ensure_route true'
assert_contains "$SCRIPT" 'ensure_route false >>"$LOG_FILE" 2>&1 || true'
assert_contains "$SCRIPT" 'route_refresh_at=$(( $(date +%s) + ROUTE_REFRESH_SECONDS ))'

if grep -Fq 'rmq_admin purge queue name="$SOURCE_FILTER_QUEUE" >/dev/null || true' "$SCRIPT"; then
  fail "$SCRIPT must not ignore a failed initialization purge"
fi

ROUTE_RESULT="$(
  source "$SCRIPT"
  route_calls=""
  rmq_admin() {
    route_calls="${route_calls}|$*"
    [ "$1 $2" != "declare queue" ]
  }
  rmq_delete_binding_exact() {
    route_calls="${route_calls}|delete $*"
  }
  if ensure_route false; then
    fail "failed route declaration unexpectedly succeeded"
  fi
  printf '%s\n' "$route_calls"
)"

case "$ROUTE_RESULT" in
  *"declare exchange"*"declare queue"*) ;;
  *) fail "route verification did not reach the simulated queue failure" ;;
esac
case "$ROUTE_RESULT" in
  *"declare binding"*|*"purge queue"*|*"|delete "*)
    fail "route verification continued after its first failure: $ROUTE_RESULT"
    ;;
esac

# A failed quiet rabbitmqadmin call returns an empty response. It must leave the
# batch loop quietly rather than feeding invalid data to the JSON transformer.
assert_contains "$SCRIPT" 'if ! messages="$(rmq_admin --format=raw_json get queue="$SOURCE_FILTER_QUEUE" count=20 ackmode=ack_requeue_false)"; then'
assert_contains "$SCRIPT" '[ -n "$messages" ] && [ "$messages" != "[]" ] || return 1'

EMPTY_READ_RESULT="$(
  source "$SCRIPT"
  rmq_admin() {
    return 1
  }
  if forward_batch_once 2>&1; then
    fail "failed RabbitMQ read unexpectedly produced a batch"
  fi
)"

[ -z "$EMPTY_READ_RESULT" ] \
  || fail "failed RabbitMQ read emitted output instead of returning quietly: $EMPTY_READ_RESULT"

# A one-shot recovery without a live loop must restore the game's native
# Survival_1 route. Otherwise native states pile up in the source queue and
# the Director alternates the in-game destination between Online and Offline.
ONE_SHOT_RESULT="$(
  source "$SCRIPT"
  loop_running() { return 1; }
  ensure_route() { printf 'ensure:%s\n' "$1"; }
  forward_batch_once() { return 1; }
  publish_snapshot_once() { echo snapshot; }
  restore_route() { echo restore; }
  publish_once
)"

[ "$ONE_SHOT_RESULT" = $'ensure:true\nsnapshot\nrestore' ] \
  || fail "one-shot recovery did not restore the native route: $ONE_SHOT_RESULT"

# A healthy loop owns the filtered route, so an operator's one-shot refresh
# must not take that route away underneath it.
LIVE_LOOP_RESULT="$(
  source "$SCRIPT"
  loop_running() { return 0; }
  ensure_route() { printf 'ensure:%s\n' "$1"; }
  forward_batch_once() { return 1; }
  publish_snapshot_once() { echo snapshot; }
  restore_route() { echo restore; }
  publish_once
)"

[ "$LIVE_LOOP_RESULT" = $'ensure:true\nsnapshot' ] \
  || fail "one-shot recovery disturbed the live loop route: $LIVE_LOOP_RESULT"

# An unexpected loop exit must also fail open before removing its ownership
# files. This covers exits that happen between Autoscaler health scans.
EXIT_RESULT="$(
  source "$SCRIPT"
  PID_FILE="$TMP_DIR/loop.pid"
  LOOP_TOKEN_FILE="$TMP_DIR/loop.token"
  LOG_FILE="$TMP_DIR/loop.log"
  printf '123\n' >"$PID_FILE"
  printf 'current-token\n' >"$LOOP_TOKEN_FILE"
  restore_route() { echo restore; }
  cleanup_loop current-token
  cat "$LOG_FILE"
  [ ! -e "$PID_FILE" ] && [ ! -e "$LOOP_TOKEN_FILE" ] && echo cleaned
)"

[ "$EXIT_RESULT" = $'restore\ncleaned' ] \
  || fail "unexpected loop exit did not restore the native route: $EXIT_RESULT"

# Bash runs the EXIT trap after start_loop's local scope has ended. The token
# therefore has to be embedded into the trap command when it is installed;
# referencing the local variable later fails under set -u and skips cleanup.
assert_contains "$SCRIPT" 'trap "cleanup_loop $(printf '\''%q'\'' "$loop_token")" EXIT'
if grep -Fq 'trap '\''cleanup_loop "$loop_token"'\'' EXIT' "$SCRIPT"; then
  fail "$SCRIPT must not defer expansion of the function-local loop token"
fi

# The publisher normally runs inside the Autoscaler PID namespace while the
# status/stop commands run on the host. Repair the PID file to the process ID
# visible to the caller rather than misclassifying the healthy loop as stale.
PID_NAMESPACE_RESULT="$(
  source "$SCRIPT"
  PID_FILE="$TMP_DIR/namespace.pid"
  printf '999999\n' >"$PID_FILE"
  kill() { return 1; }
  loop_pids() { echo 4242; }
  clear_stale_pidfile
  cat "$PID_FILE"
)"

[ "$PID_NAMESPACE_RESULT" = "4242" ] \
  || fail "publisher PID was not repaired across namespaces: $PID_NAMESPACE_RESULT"

# The Autoscaler owns a foreground publisher child and restarts it after any
# exit. This closes the original unsupervised-daemon failure mode instead of
# relying on a later stale-state scan to notice missing heartbeats.
assert_contains "$AUTOSCALER_SCRIPT" 'supervise_sietch_override_publisher() {'
assert_contains "$AUTOSCALER_SCRIPT" 'runtime/scripts/publish-sietch-overrides.sh loop || true'
assert_contains "$AUTOSCALER_SCRIPT" 'supervise_sietch_override_publisher &'
if grep -Fq 'publish-sietch-overrides.sh start >/dev/null' "$AUTOSCALER_SCRIPT"; then
  fail "$AUTOSCALER_SCRIPT must not launch detached publisher generations from stale-state scans"
fi

echo "PASS: Sietch state publication remains responsive during RabbitMQ maintenance failures"
