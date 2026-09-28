#!/usr/bin/env bash
# The judgement of tests/podman-host-gate.sh, driven against a fake host.
#
# The gate harness only ever runs by hand, on a disposable enforcing AlmaLinux
# VM with Podman. No CI runner is that host and none ever will be, so the one
# thing about it that can rot unnoticed is its judgement: the mapping from what
# the host said to ANSWERED / BLOCKER / INCONCLUSIVE, the order the probes run
# in, and the exit status the operator's `&&` chain reads.
#
# The property under test throughout is the branch's own rule that a check
# either asserts something or says it could not. A gate that printed ANSWERED
# for a probe whose precondition was absent would close a release on evidence
# nobody gathered, and a vacuous pass looks exactly like a clean run. That is
# the first scenario below and the most important one.
#
# The harness is exercised as shipped, never re-implemented. Every scenario
# builds a throwaway checkout under mktemp with tests/podman-host-gate.sh
# symlinked into it, so the harness's own `cd "$(dirname "$0")/.."` lands
# inside the fixture and every relative path it touches (runtime/game/*/Saved,
# runtime/scripts/lib/engine.sh, runtime/scripts/metrics-stack.sh) resolves
# there rather than in the working tree. `docker` comes from
# tests/lib/fake-engine.sh; the host tools the harness reaches through PATH are
# one-off stubs; and PATH is otherwise cut down to a tree that provably carries
# no container engine, which is what makes the vacuity scenario honest on a
# GitHub runner that ships both docker and podman.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

HARNESS="$REPO_ROOT/tests/podman-host-gate.sh"
if [ ! -s "$HARNESS" ]; then
  echo "FAIL: $HARNESS is missing" >&2
  exit 1
fi
bash -n "$HARNESS"

# Captured before PATH is rewritten: the stub below delegates to the real one.
REAL_STAT="$(command -v stat)"

failures=0

check() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s\n      expected: %s\n      actual:   %s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" description="$3"
  if ! grep -qF -- "$needle" <<<"$haystack"; then
    printf 'FAIL: %s\n      expected to find: %s\n' "$description" "$needle" >&2
    awk '{ print "      " $0 }' <<<"$haystack" >&2
    failures=$((failures + 1))
  fi
}

# ---------------------------------------------------------------------------
# A PATH with no container engine on it
# ---------------------------------------------------------------------------

# The vacuity scenario has to run on a host that genuinely has no engine, and
# the GitHub runner ships docker and podman both. Rather than guess which
# coreutils the harness needs, mirror every directory of the real PATH into one
# tree and leave out only the host tooling the probes read the host through.
# What remains is an ordinary working shell that cannot answer a single probe.
SANDBOX_ROOT="$(mktemp -d)"
cleanup() {
  if [ -n "${FAKE_ENGINE_DIR:-}" ]; then
    fake_engine_stop
  fi
  rm -rf "$SANDBOX_ROOT"
}
trap cleanup EXIT

BARE_PATH="$SANDBOX_ROOT/bare-path"
mkdir -p "$BARE_PATH"
withheld=" docker docker-compose podman podman-compose buildah skopeo \
getenforce selinuxenabled sestatus ausearch auditctl curl wget getent \
systemctl systemd-run "
IFS=':' read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
  [ -d "$dir" ] || continue
  for tool in "$dir"/*; do
    [ -e "$tool" ] || continue
    base="${tool##*/}"
    case "$withheld" in
      *" $base "*) continue ;;
    esac
    if [ ! -e "$BARE_PATH/$base" ]; then
      ln -s "$tool" "$BARE_PATH/$base" 2>/dev/null || true
    fi
  done
done
for needed in bash env grep sed awk mktemp date hostname uname git; do
  if [ ! -e "$BARE_PATH/$needed" ]; then
    echo "FAIL: the cut-down PATH lost $needed; the fixture could not run" >&2
    failures=$((failures + 1))
  fi
done
for gone in docker podman getenforce ausearch curl; do
  if [ -e "$BARE_PATH/$gone" ]; then
    echo "FAIL: the cut-down PATH still offers $gone; vacuity would not be tested" >&2
    failures=$((failures + 1))
  fi
done

# G0-5 reads /etc/containers, which is the one input no fixture can shadow: a
# host whose own containers.conf remaps namespaces would send G0-5 down the
# config branch before any of the evidence below is reached. Say so plainly
# rather than let that surface as a mystified verdict mismatch.
if grep -rEq "^[[:space:]]*userns[[:space:]]*=[[:space:]]*[\"']?(auto|keep-id|nomap)" \
  /etc/containers/containers.conf /etc/containers/containers.conf.d/ \
  /usr/share/containers/containers.conf 2>/dev/null; then
  echo "FAIL: this host's containers.conf remaps user namespaces, so G0-5 answers" >&2
  echo "      from configuration and the ownership scenarios below cannot run" >&2
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

FIXTURE=""
STUB_BIN=""

# Write an executable stub. Body on stdin.
stub() {
  local path="$1"
  cat >"$path"
  chmod +x "$path"
}

# runtime/scripts/metrics-stack.sh is the one shipped script G0-3 actually
# executes, and this test brings no metrics stack up. Everything else under
# runtime/ is the real file, because the harness reads its production seams
# (lib/engine.sh, runtime-env.sh) out of there.
metrics_stack_exits() {
  stub "$FIXTURE/runtime/scripts/metrics-stack.sh" <<STUB
#!/usr/bin/env bash
printf 'metrics-stack.sh %s\n' "\$*"
exit $1
STUB
}

new_fixture() {
  FIXTURE="$(mktemp -d "$SANDBOX_ROOT/fixture.XXXXXX")"
  STUB_BIN="$FIXTURE/stub-bin"
  mkdir -p "$FIXTURE/tests" "$FIXTURE/runtime/scripts" \
    "$FIXTURE/runtime/game/hagga-basin/Saved" "$STUB_BIN"
  ln -s "$HARNESS" "$FIXTURE/tests/podman-host-gate.sh"
  local entry
  for entry in "$REPO_ROOT"/runtime/scripts/*; do
    ln -s "$entry" "$FIXTURE/runtime/scripts/${entry##*/}"
  done
  rm -f "$FIXTURE/runtime/scripts/metrics-stack.sh"
  metrics_stack_exits 1
  unset DUNE_CONTAINER_ENGINE DUNE_ENGINE_READY DOCKER_HOST
  PATH="$STUB_BIN:$BARE_PATH"
  export PATH
}

# `podman` answers the probes that go round the compat socket to the engine's
# own CLI: G0-5's IDMappings read, G0-4's cgroup manager, P2's builder prune
# and P7's two short-name runs.
stub_podman() {
  stub "$STUB_BIN/podman" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "info --format {{.Host.IDMappings}}") echo "[{ContainerID:0 HostID:0 Size:1}]" ;;
  "info --format "*) echo "2 systemd" ;;
  "builder prune --help") echo "Remove build cache" ;;
  *) echo "podman $*" ;;
esac
exit 0
STUB
}

# `stat` reports the ownership of runtime/game/*/Saved, which is G0-5's ground
# truth once containers.conf turns out not to be decisive. Only the gate's own
# `-c '%u:%g %n'` spelling is faked; anything else goes to the real binary.
stub_stat_uid() {
  stub "$STUB_BIN/stat" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = "-c" ] && [ "\${2:-}" = '%u:%g %n' ]; then
  shift 2
  for target in "\$@"; do
    printf '$1:$1 %s\n' "\$target"
  done
  exit 0
fi
exec $REAL_STAT "\$@"
STUB
}

# `curl` is G0-3's only window on cAdvisor: one reachability probe that wants
# an HTTP code, then two scrapes of the metric text.
stub_curl_metrics() {
  stub "$STUB_BIN/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *-w*) printf '200\n' ;;
  *) printf '%s\n' '$1' ;;
esac
exit 0
STUB
}

# Run the shipped harness inside the current fixture. stdout is captured on its
# own: the contract puts progress, warnings and errors on stderr so that a
# `> gate.md` redirect stays paste-able.
GATE_OUT=""
GATE_STATUS=0
run_gate() {
  local errfile
  errfile="$(mktemp "$SANDBOX_ROOT/stderr.XXXXXX")"
  GATE_STATUS=0
  GATE_OUT="$(DUNE_GATE_SETTLE_SECONDS=0 bash "$FIXTURE/tests/podman-host-gate.sh" "$@" 2>"$errfile")" \
    || GATE_STATUS=$?
  rm -f "$errfile"
}

# The probe IDs of the `## <ID> — …` section headings, in the order printed.
# `## Summary` carries no ID and does not match.
sections() {
  sed -n 's/^## \([A-Za-z0-9-]\{1,\}\) —.*/\1/p' <<<"$GATE_OUT" | tr '\n' ' ' | sed 's/ $//'
}

# The verdict token of one probe's section.
verdict_of() {
  awk -v probe="$1" '
    $0 ~ "^## " probe " " { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^\*\*Verdict:\*\* / { print $2; exit }
  ' <<<"$GATE_OUT"
}

# One probe's whole verdict line, token and consequence text.
verdict_text_of() {
  awk -v probe="$1" '
    $0 ~ "^## " probe " " { inside = 1; next }
    /^## / { inside = 0 }
    inside && /^\*\*Verdict:\*\* / { print; exit }
  ' <<<"$GATE_OUT"
}

count_matching() {
  grep -c -- "$1" <<<"$GATE_OUT" || true
}

# ---------------------------------------------------------------------------
# 1. The vacuity invariant: no engine, no stack, nothing claimed
# ---------------------------------------------------------------------------

# A host with no container engine can answer none of the twelve questions. The
# harness must say so twelve times and exit 2. If any probe here reported
# ANSWERED it would be inferring a result from the absence of evidence, which
# is the failure this whole file exists to catch.
new_fixture
run_gate

check "an empty host answers nothing, so the gate exits 2" 2 "$GATE_STATUS"
check "every probe on an empty host is INCONCLUSIVE" 12 "$(count_matching '^\*\*Verdict:\*\* INCONCLUSIVE ')"
check "no probe passes vacuously" 0 "$(count_matching 'ANSWERED')"
check "and nothing is called a blocker either" 0 "$(count_matching 'BLOCKER')"
assert_contains "$GATE_OUT" '12 probes: 0 answered, 0 blockers, 12 inconclusive.' \
  "the tally counts what the sections said"

# Ordering. G0-5 runs first because it is the only probe that can quietly
# corrupt data and it wants a host nothing has written to yet; G0-2 second
# because it changes host configuration everything after it runs against. The
# gate document mandates both, so the whole sequence is pinned here.
check "probes run in the declared order, G0-5 then G0-2 then the rest" \
  "G0-5 G0-2 G0-1 G0-3 G0-4 P1 P2 P3 P4 P5 P6 P7" "$(sections)"

# Transcript shape: one verdict per section, and a summary row per probe. Both
# are what makes the output paste-able into a PR body unedited.
check "each section carries exactly one verdict line" "" \
  "$(awk '
     /^## / { if (probe != "" && seen != 1) printf "%s has %d verdicts; ", probe, seen
              probe = ($2 == "Summary" ? "" : $2); seen = 0; next }
     /^\*\*Verdict:\*\* / { seen++ }
     END { if (probe != "" && seen != 1) printf "%s has %d verdicts; ", probe, seen }
   ' <<<"$GATE_OUT")"
check "the summary table lists every selected probe" 12 \
  "$(count_matching '^| \(G0-[1-5]\|P[1-7]\) | ')"

# An inconclusive probe says what is missing and what to do about it, or the
# operator has a transcript they cannot act on.
assert_contains "$(verdict_text_of G0-5)" 'Re-run on the Podman host with' \
  "G0-5 names the host it needs when it cannot reach an engine"

# ---------------------------------------------------------------------------
# 2. G0-1, both sides: the gate that can turn A4 into a P0
# ---------------------------------------------------------------------------

# shellcheck source=/dev/null
. "$REPO_ROOT/tests/lib/fake-engine.sh"

# fake_engine_start installs its own EXIT trap, so this file's has to be put
# back after every start.
use_fake_engine() {
  fake_engine_start podman
  trap cleanup EXIT
}

# `--log-opt max-file` accepted by both the direct run and the Compose one:
# A4 stays a three-sentence doc fix, and a run with nothing else in it exits 0.
new_fixture
use_fake_engine
run_gate --only G0-1
check "max-file accepted answers G0-1" ANSWERED "$(verdict_of G0-1)"
assert_contains "$(verdict_text_of G0-1)" 'A4 branch (a)' \
  "the accepted branch names A4 branch (a)"
check "a run where every probe answered exits 0" 0 "$GATE_STATUS"
fake_engine_stop

# The direct run rejected. This is the release-blocking half: `docker compose
# up` would fail at container creation for the orchestrator, the console and
# the public probe, so the verdict is a BLOCKER and the run exits 1.
new_fixture
use_fake_engine
fake_engine_exit_status "run --rm --log-driver" 125
run_gate --only G0-1
check "max-file rejected blocks the release" BLOCKER "$(verdict_of G0-1)"
assert_contains "$(verdict_text_of G0-1)" 're-classify A4 as P0' \
  "the rejection re-classifies A4"
check "a blocker makes the run exit 1" 1 "$GATE_STATUS"
fake_engine_stop

# Exit-status precedence: a blocker outranks an inconclusive. Without that the
# operator's `&&` chain would read 2 and treat a release-blocking answer as a
# host that was merely not ready.
new_fixture
use_fake_engine
fake_engine_exit_status "run --rm --log-driver" 125
run_gate --only G0-1,G0-3
check "a blocker beside an inconclusive still exits 1" 1 "$GATE_STATUS"
check "…with the inconclusive probe reported as such" INCONCLUSIVE "$(verdict_of G0-3)"
fake_engine_stop

# ---------------------------------------------------------------------------
# 3. G0-5, both branches: the probe whose failure is silent and data-shaped
# ---------------------------------------------------------------------------

# Game servers run --privileged with no --user and no --userns and bind the
# live save tree. A save tree owned by a remapped subuid is the evidence that
# this host's default remaps namespaces, and A5 has to pin --userns=host.
new_fixture
stub_podman
stub_stat_uid 100000
use_fake_engine
fake_engine_respond "ps --format {{.Names}}" <<'OUT'
dune-server-gateway
dune-postgres
OUT
fake_engine_respond "inspect -f {{.HostConfig.UsernsMode}}" </dev/null
run_gate --only G0-5
check "a remapped save tree answers G0-5" ANSWERED "$(verdict_of G0-5)"
assert_contains "$(verdict_text_of G0-5)" "A5 branch (b): pin \`--userns=host\`" \
  "a remapped save tree takes the pin-it branch"
assert_contains "$(verdict_text_of G0-5)" 'remapped uid 100000' \
  "…and quotes the uid it read, not a default"
fake_engine_stop

# The same probe against a host-owned tree with UsernsMode unset: the argv is
# already right, and A5 is a doc line plus a doctor warning.
new_fixture
stub_podman
stub_stat_uid 1000
use_fake_engine
fake_engine_respond "ps --format {{.Names}}" <<'OUT'
dune-server-gateway
dune-postgres
OUT
fake_engine_respond "inspect -f {{.HostConfig.UsernsMode}}" </dev/null
run_gate --only G0-5
check "a host-owned save tree answers G0-5" ANSWERED "$(verdict_of G0-5)"
assert_contains "$(verdict_text_of G0-5)" 'A5 branch (a): doc line plus a doctor warning, no argv change' \
  "a host-owned save tree takes the doc-line branch"
fake_engine_stop

# ---------------------------------------------------------------------------
# 4. Selection
# ---------------------------------------------------------------------------

# --only runs the named probes in the harness's declared order, never in the
# order typed: a transcript whose sections move around with the command line is
# one no two runs can be diffed against each other.
new_fixture
use_fake_engine
run_gate --only P3,G0-2,G0-5
check "--only runs exactly the named probes, in declared order" "G0-5 G0-2 P3" "$(sections)"
assert_contains "$GATE_OUT" 'Probes: G0-5 G0-2 P3' \
  "the header lists the selection in the same order"
fake_engine_stop

# An unknown ID is a usage error, and a usage error must not emit half a
# transcript: `tests/podman-host-gate.sh --only G05 > gate.md` has to leave
# gate.md empty rather than misleadingly short.
new_fixture
run_gate --only G0-5,G05
check "an unknown probe ID exits 64" 64 "$GATE_STATUS"
check "…and prints nothing on stdout" "" "$GATE_OUT"

# ---------------------------------------------------------------------------
# 5. A host that can answer
# ---------------------------------------------------------------------------

# The counterpart to the vacuity run: the probes whose classification is a
# straight read of one command's output, on a host that supplies it. Every one
# of them answers, and a transcript with no blocker and no inconclusive exits
# 0. G0-2, P3 and P6 are left out because their answers need a real enforcing
# host, a limit that actually moves and a real published port respectively --
# the three things a stub cannot honestly supply.
new_fixture
stub_podman
metrics_stack_exits 0
stub_curl_metrics 'container_cpu_usage_seconds_total{name="dune-postgres"} 4.2'
use_fake_engine
fake_engine_respond "ps --format {{.Names}}" <<'OUT'
dune-server-gateway
dune-postgres
OUT
fake_engine_respond "ps -a --filter" <<'OUT'
CONTAINER ID   IMAGE       NAMES
0123456789ab   postgres    dune-postgres
OUT
fake_engine_respond "inspect -f {{.HostConfig.CgroupnsMode}}" <<'OUT'
private
private
OUT
fake_engine_respond "exec dune-server-gateway cat" <<'OUT'
0::/
OUT
fake_engine_respond "stats --no-stream --format" <<'OUT'
{"BlockIO":"0B / 0B","CPUPerc":"0.12%","MemUsage":"41MiB / 2GiB","Name":"dune-postgres","NetIO":"1kB / 2kB"}
{"BlockIO":"0B / 0B","CPUPerc":"1.40%","MemUsage":"3GiB / 8GiB","Name":"dune-server-gateway","NetIO":"9kB / 4kB"}
OUT
run_gate --only G0-3,G0-4,P1,P2,P4,P5,P7
check "a host that can answer produces no inconclusive probe" 0 \
  "$(count_matching '^\*\*Verdict:\*\* INCONCLUSIVE ')"
check "…and no blocker" 0 "$(count_matching '^\*\*Verdict:\*\* BLOCKER ')"
check "…so seven probes answered" 7 "$(count_matching '^\*\*Verdict:\*\* ANSWERED ')"
check "…and the run exits 0" 0 "$GATE_STATUS"
fake_engine_stop

# ---------------------------------------------------------------------------
# 6. G0-3 on a host with a metrics stack but no stack to measure
# ---------------------------------------------------------------------------

# cAdvisor naming no `dune-*` container has two causes: `--docker_only` cannot
# see them, or there are none. Only the first answers G0-3, and a host running
# other workloads looks exactly like the second. The probe must abstain rather
# than report C9 as required on the strength of an absent subject.
new_fixture
stub_podman
metrics_stack_exits 0
stub_curl_metrics 'container_cpu_usage_seconds_total{name="paperless-web"} 4.2'
use_fake_engine
fake_engine_respond "ps --format {{.Names}}" <<'OUT'
pterodactyl-panel
paperless-web
OUT
run_gate --only G0-3

check "G0-3 abstains when no dune container is running" "INCONCLUSIVE" "$(verdict_of G0-3)"
assert_contains "$(verdict_text_of G0-3)" "no \`dune-*\` container is running" \
  "…and says the subject was missing, not that C9 is required"
check "…so the run exits 2, not 0" 2 "$GATE_STATUS"
fake_engine_stop

if [ "$failures" -ne 0 ]; then
  echo "podman host gate: $failures failure(s)" >&2
  exit 1
fi
echo "OK: the Podman host gate asserts or abstains, in the mandated order"
