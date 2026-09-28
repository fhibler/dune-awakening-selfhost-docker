#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v age >/dev/null 2>&1 || { echo "SKIP: age not found on PATH -- install via 'apt install age' (see https://github.com/FiloSottile/age)"; exit 0; }
command -v age-keygen >/dev/null 2>&1 || { echo "SKIP: age-keygen not found on PATH"; exit 0; }
python3 -c "from cryptography.hazmat.primitives.ciphers.aead import AESGCM" >/dev/null 2>&1 || {
  echo "SKIP: python3's 'cryptography' package not installed"
  exit 0
}

# Regression coverage for Stage 2 of the age-based secrets library
# rollout: the two modified resolver functions in runtime-env.sh
# (resolve_server_login_password_secret / resolve_username_server_login_secret)
# and the CLI wrapper in secrets-cli.sh. Follows the exact same
# self-contained pattern as test-secrets-lib.sh -- generates its own
# throwaway age identity/KEK inside a disposable temp directory, never
# touching this repo's actual runtime/secrets/ or any live deployment.
# This is a deliberate choice: a manual/documentation-only testing
# bridge was considered and rejected as unnecessary once it was
# confirmed CI already has everything needed for this to be fully
# automated.

test_root="$(mktemp -d)"
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

identity_path="$test_root/age-identity.txt"
wrong_identity_path="$test_root/wrong-identity.txt"
kek_path="$test_root/kek.age"

age-keygen -o "$identity_path" >/dev/null 2>&1
public_key="$(age-keygen -y "$identity_path")"
age-keygen -o "$wrong_identity_path" >/dev/null 2>&1

# shellcheck disable=SC1091
source "$repo_root/runtime/scripts/lib/secrets.sh"

kek_hex="$(dune_secrets_generate_dek)"
printf '%s' "$kek_hex" | age --encrypt -r "$public_key" -o "$kek_path"

# Copy runtime-env.sh's direct dependencies into the disposable
# test_root so it can be sourced there exactly as it would be from
# the real repo root, without touching the real repo's own
# runtime/secrets/ or runtime/generated/.
mkdir -p "$test_root/runtime/scripts/lib" "$test_root/runtime/generated" "$test_root/runtime/secrets"
cp "$repo_root/runtime/scripts/runtime-env.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/memory-swap-common.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/env-file.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/host-file-ownership.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/compose-project.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/secrets-cli.sh" "$test_root/runtime/scripts/"
cp "$repo_root/runtime/scripts/lib/secrets.sh" "$test_root/runtime/scripts/lib/"
cp "$repo_root/runtime/scripts/lib/secrets_aead.py" "$test_root/runtime/scripts/lib/"
cp "$repo_root/runtime/scripts/lib/engine.sh" "$test_root/runtime/scripts/lib/"

cd "$test_root"

# --- Test 1 (Deliverable #1/#6): fresh install, backend not
# configured, is byte-for-byte identical to pre-Stage-2 behavior ---
unset DUNE_KEK_FILE DUNE_AGE_IDENTITY_FILE 2>/dev/null || true
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  value1="$(resolve_server_login_password_secret)"
  value2="$(resolve_server_login_password_secret)"
  [ "$value1" = "$value2" ] || fail "Test 1: resolver value changed across calls with backend not configured"
  [ -f runtime/secrets/server-login-password-secret.txt ] || fail "Test 1: legacy file was not created"
  [ "$(stat -c '%a' runtime/secrets/server-login-password-secret.txt)" = "600" ] || fail "Test 1: legacy file mode is not 600"
  # Proves "no new binary on the critical path," not just "same
  # output" -- shadow `age` with a failing stub; the resolver must
  # never invoke it when the backend isn't configured.
  mkdir -p "$PWD/fake-bin"
  cat > "$PWD/fake-bin/age" <<'STUB'
#!/bin/sh
echo "age should not have been called" >&2
exit 1
STUB
  chmod +x "$PWD/fake-bin/age"
  PATH="$PWD/fake-bin:$PATH" resolve_server_login_password_secret >/dev/null
)
echo "PASS: Test 1 (fresh install / preservation when not configured)"

# --- Test 2 (Deliverable #2): plaintext migration via secrets-cli.sh ---
rm -rf runtime/secrets runtime/generated
mkdir -p runtime/secrets runtime/generated
export DUNE_KEK_FILE="$kek_path"
export DUNE_AGE_IDENTITY_FILE="$identity_path"
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  legacy_value="$(resolve_server_login_password_secret)"
  echo "$legacy_value" > /tmp/expected-value.$$
)
expected_value="$(cat /tmp/expected-value.$$)"
rm -f /tmp/expected-value.$$

bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret >/dev/null
[ -f runtime/secrets/server-login-password-secret.enc ] || fail "Test 2: .enc file was not created by migrate"
[ -f runtime/generated/.secrets-migrated/server-login-password-secret.done ] || fail "Test 2: migration marker was not created"
legacy_after="$(cat runtime/secrets/server-login-password-secret.txt)"
[ "$legacy_after" = "$expected_value" ] || fail "Test 2: migrate mutated the legacy file"

(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  post_migrate_value="$(resolve_server_login_password_secret)"
  [ "$post_migrate_value" = "$expected_value" ] || fail "Test 2: resolver did not return the original value after migration"
)
echo "PASS: Test 2 (plaintext migration)"

# --- Test 3 (Deliverable #3): wrong age identity is a hard stop once
# migrated, propagated all the way through the resolver ---
# NOTE: runtime-env.sh has its own `set -euo pipefail` at its top,
# which persists in the calling shell once sourced (source, unlike
# exec, doesn't get its own options scope) -- `set +e` must be
# reapplied AFTER sourcing it, immediately before the call expected to
# fail, or that call's non-zero exit aborts this entire test script
# under the reinstated `set -e`, even inside a `(...)` subshell.
(
  # Deliberately scoped to this subshell only (SC2030).
  # shellcheck disable=SC2030
  export DUNE_AGE_IDENTITY_FILE="$wrong_identity_path"
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  set +e
  resolve_server_login_password_secret >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" != "0" ] || fail "Test 3: resolver succeeded with the wrong age identity after migration"
)
echo "PASS: Test 3 (missing/incorrect age identity is a hard stop)"

# --- Regression: migration history is based on artifact existence, not
# readability. If both signals suffer permission drift while a stale
# plaintext still exists, the resolver must fail instead of returning it.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: Test 3b (root bypasses chmod 000; exercised by non-root CI)"
else
  marker_path="runtime/generated/.secrets-migrated/server-login-password-secret.done"
  chmod 000 runtime/secrets/server-login-password-secret.enc "$marker_path"
  set +e
  (
    # shellcheck disable=SC1091
    source runtime/scripts/runtime-env.sh
    resolve_server_login_password_secret >/dev/null 2>/dev/null
  )
  unreadable_rc=$?
  set -e
  # shellcheck disable=SC2031
  chmod 600 runtime/secrets/server-login-password-secret.enc "$marker_path"
  [ "$unreadable_rc" != "0" ] || fail "Test 3b: resolver fell back to plaintext when both migration artifacts were unreadable"
  echo "PASS: Test 3b (both unreadable migration artifacts fail closed)"
fi

# --- Regression: cleanup removes the legacy file, so its absence cannot
# distinguish a migrated secret from a fresh install. A wrong identity or
# lost backend configuration must not mint a replacement plaintext secret.
bash runtime/scripts/secrets-cli.sh cleanup-legacy server-login-password-secret >/dev/null
[ ! -e runtime/secrets/server-login-password-secret.txt ] || fail "Test 3c: cleanup did not remove the legacy file"
(
  # shellcheck disable=SC2030,SC2031
  export DUNE_AGE_IDENTITY_FILE="$wrong_identity_path"
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  set +e
  resolve_server_login_password_secret >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" != "0" ] || fail "Test 3c: resolver succeeded after cleanup with a wrong identity"
  [ ! -e runtime/secrets/server-login-password-secret.txt ] || fail "Test 3c: resolver generated replacement plaintext after decryption failure"
)
(
  unset DUNE_KEK_FILE DUNE_AGE_IDENTITY_FILE
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  set +e
  resolve_server_login_password_secret >/dev/null 2>/dev/null
  rc=$?
  [ "$rc" != "0" ] || fail "Test 3c: resolver succeeded after migration with backend configuration missing"
  [ ! -e runtime/secrets/server-login-password-secret.txt ] || fail "Test 3c: resolver generated plaintext after backend configuration was lost"
)
printf '%s\n' "$expected_value" > runtime/secrets/server-login-password-secret.txt
chmod 600 runtime/secrets/server-login-password-secret.txt
echo "PASS: Test 3c (post-cleanup failures never recreate plaintext)"

# --- Test 5 (Deliverable #5): recovery and rollback -- deleting the
# .enc file returns the resolver to the original legacy value,
# unchanged, not a newly-generated one ---
rm -f runtime/secrets/server-login-password-secret.enc
rm -f runtime/generated/.secrets-migrated/server-login-password-secret.done
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  rollback_value="$(resolve_server_login_password_secret)"
  [ "$rollback_value" = "$expected_value" ] || fail "Test 5: rollback did not return the original legacy value"
)
echo "PASS: Test 5 (recovery and rollback)"

# --- Test 7 (Deliverable #7): cleanup-legacy adversarial case --
# corrupt the .enc file's ciphertext (without touching the marker),
# confirm cleanup-legacy REFUSES and the legacy file survives ---
bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret >/dev/null
# Corrupt: flip bytes in the ciphertext portion of the enc:v2: line.
enc_line="$(cat runtime/secrets/server-login-password-secret.enc)"
corrupted_line="${enc_line}CORRUPTED"
printf '%s' "$corrupted_line" > runtime/secrets/server-login-password-secret.enc
set +e
bash runtime/scripts/secrets-cli.sh cleanup-legacy server-login-password-secret >/tmp/cleanup-out.$$ 2>&1
cleanup_rc=$?
set -e
[ "$cleanup_rc" != "0" ] || fail "Test 7: cleanup-legacy succeeded against a corrupted .enc file"
[ -f runtime/secrets/server-login-password-secret.txt ] || fail "Test 7: legacy file was deleted despite verification failure"
rm -f /tmp/cleanup-out.$$
echo "PASS: Test 7 (cleanup-legacy adversarial case)"

# --- Test 7b (CRITICAL fix found during implementation review):
# permission-drift scenario -- the .enc file exists but is NOT
# readable by the current user (marker IS readable). Both `dune
# secrets verify` and the resolver must fail closed here, NOT silently
# report success/fall back to legacy -- this is the exact bug an
# earlier version of dune_secrets_read_secret had: it only checked
# .enc-file readability, so an unreadable-but-present .enc file was
# indistinguishable from "never migrated," silently returning stale
# legacy plaintext with exit 0. `cleanup-legacy`'s own "re-verify
# immediately before deleting" step used the same silently-succeeding
# call, meaning it could delete the last good (legacy) copy while the
# real .enc file sat there broken and unreadable. This test only runs
# meaningfully as a genuinely unprivileged user -- root bypasses
# `chmod` readability restrictions entirely, so this reproduction is
# skipped when running as root (the exact same, already-documented
# constraint test-secrets-lib.sh's own Test 8 already accepts). Real
# CI (GitHub Actions) runs as a non-root user, where this test is
# fully meaningful.
if [ "$(id -u)" = "0" ]; then
  echo "SKIP: Test 7b (running as root -- chmod 000 does not block root from reading, so this permission-drift simulation cannot work; exercised in CI, which runs non-root)"
else
  # Fresh migrate to get back to a known-good, uncorrupted state.
  rm -f runtime/secrets/server-login-password-secret.enc
  bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret >/dev/null
  chmod 000 runtime/secrets/server-login-password-secret.enc
  set +e
  verify_out="$(bash runtime/scripts/secrets-cli.sh verify server-login-password-secret 2>&1)"
  verify_rc=$?
  set -e
  chmod 600 runtime/secrets/server-login-password-secret.enc
  [ "$verify_rc" != "0" ] || fail "Test 7b: verify reported success against an unreadable .enc file (marker present) -- CRITICAL fail-closed regression"
  if printf '%s' "$verify_out" | grep -qi "^server-login-password-secret: OK"; then
    fail "Test 7b: verify printed OK against an unreadable .enc file"
  fi
  echo "PASS: Test 7b (verify fails closed on an unreadable-but-present .enc file, marker notwithstanding)"

  chmod 000 runtime/secrets/server-login-password-secret.enc
  set +e
  bash runtime/scripts/secrets-cli.sh cleanup-legacy server-login-password-secret >/tmp/cleanup7b-out.$$ 2>&1
  cleanup7b_rc=$?
  set -e
  chmod 600 runtime/secrets/server-login-password-secret.enc
  [ "$cleanup7b_rc" != "0" ] || fail "Test 7b: cleanup-legacy succeeded against an unreadable .enc file -- would have deleted the last good copy"
  [ -f runtime/secrets/server-login-password-secret.txt ] || fail "Test 7b: legacy file was deleted despite the .enc file being unreadable"
  rm -f /tmp/cleanup7b-out.$$
  echo "PASS: Test 7b (cleanup-legacy refuses when the .enc file is unreadable, even though the marker is present)"
fi

# --- Test 8 (Deliverable #8): migrate is idempotent-in-effect on a
# second run -- always re-encrypts from the source plaintext, never
# double-wraps ---
rm -rf runtime/secrets runtime/generated
mkdir -p runtime/secrets runtime/generated
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  unset DUNE_KEK_FILE DUNE_AGE_IDENTITY_FILE
  resolve_server_login_password_secret >/dev/null
)
export DUNE_KEK_FILE="$kek_path"
# Intentional: re-establishing the outer scope's env vars after the
# subshell above deliberately unset them for its own isolated
# fresh-install test (SC2031).
# shellcheck disable=SC2031
export DUNE_AGE_IDENTITY_FILE="$identity_path"
bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret >/dev/null
first_enc="$(cat runtime/secrets/server-login-password-secret.enc)"
bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret >/dev/null
second_enc="$(cat runtime/secrets/server-login-password-secret.enc)"
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  after_second_migrate="$(resolve_server_login_password_secret)"
  original_legacy="$(cat runtime/secrets/server-login-password-secret.txt)"
  [ "$after_second_migrate" = "$original_legacy" ] || fail "Test 8: resolver value incorrect after second migrate"
)
echo "PASS: Test 8 (migrate re-run idempotency; ciphertext bytes differ=$([ "$first_enc" != "$second_enc" ] && echo yes || echo no), value stable)"

# --- Test: status command runs cleanly and never prints a secret value ---
status_out="$(bash runtime/scripts/secrets-cli.sh status server-login-password-secret 2>&1)"
echo "$status_out" | grep -qi "migrated" || fail "status output missing expected state text"
if echo "$status_out" | grep -qE '[0-9a-f]{20,}'; then
  fail "status output appears to contain a raw secret/hex value"
fi
echo "PASS: Test (status never prints a secret value)"

# --- Test: dune secrets migrate rejects an out-of-scope name --
# Postgres/Funcom/RMQ must never be reachable through this stage's
# CLI, even though the library's own generic name-validator would
# accept the string ---
set +e
bash runtime/scripts/secrets-cli.sh migrate postgres-password >/tmp/scope-out.$$ 2>&1
scope_rc=$?
set -e
[ "$scope_rc" != "0" ] || fail "Test (scope): migrate accepted an out-of-scope secret name"
grep -qi "not in scope" /tmp/scope-out.$$ || fail "Test (scope): rejection message did not explain why"
rm -f /tmp/scope-out.$$
echo "PASS: Test (out-of-scope secret name rejected)"

# --- Test: --dry-run makes no filesystem changes ---
rm -rf runtime/secrets runtime/generated
mkdir -p runtime/secrets runtime/generated
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  unset DUNE_KEK_FILE DUNE_AGE_IDENTITY_FILE
  resolve_username_server_login_secret >/dev/null
)
export DUNE_KEK_FILE="$kek_path"
export DUNE_AGE_IDENTITY_FILE="$identity_path"
bash runtime/scripts/secrets-cli.sh migrate username-server-login-secret --dry-run >/dev/null
[ -f runtime/secrets/username-server-login-secret.enc ] && fail "--dry-run created a real .enc file"
[ -f runtime/generated/.secrets-migrated/username-server-login-secret.done ] && fail "--dry-run created a real migration marker"
echo "PASS: Test (--dry-run makes no filesystem changes)"

# --- Test: CLI wrapper propagates failure without printing a false
# success message. secrets-cli.sh is always invoked as a real
# subprocess (bash runtime/scripts/secrets-cli.sh ...), matching this
# repo's own established pattern for every comparable CLI script
# (db.sh, storage.sh both use the identical `cd "$(dirname "$0")/../.."`
# idiom, which only resolves correctly when run this way, not sourced)
# -- so this test forces a real failure by pointing DUNE_KEK_FILE at a
# KEK the configured identity cannot decrypt, rather than sourcing the
# script and stubbing a function, which would exercise a code path
# real callers never take.
rm -rf runtime/secrets runtime/generated
mkdir -p runtime/secrets runtime/generated
(
  # shellcheck disable=SC1091
  source runtime/scripts/runtime-env.sh
  unset DUNE_KEK_FILE DUNE_AGE_IDENTITY_FILE
  resolve_server_login_password_secret >/dev/null
)
other_kek_path="$test_root/other-kek.age"
other_identity_path="$test_root/other-identity.txt"
age-keygen -o "$other_identity_path" >/dev/null 2>&1
other_public_key="$(age-keygen -y "$other_identity_path")"
printf '%s' "$(dune_secrets_generate_dek)" | age --encrypt -r "$other_public_key" -o "$other_kek_path"
export DUNE_KEK_FILE="$other_kek_path"
export DUNE_AGE_IDENTITY_FILE="$identity_path"
set +e
migrate_out="$(bash runtime/scripts/secrets-cli.sh migrate server-login-password-secret 2>&1)"
migrate_rc=$?
set -e
export DUNE_KEK_FILE="$kek_path"
[ "$migrate_rc" != "0" ] || fail "Test (failure propagation): migrate succeeded with a KEK the identity cannot decrypt"
if printf '%s' "$migrate_out" | grep -qi "^server-login-password-secret: migrated\."; then
  fail "Test (failure propagation): printed a success message despite the underlying write failing"
fi
echo "PASS: Test (CLI wrapper propagates underlying failure)"

echo "All Stage 2 secrets tests passed."
