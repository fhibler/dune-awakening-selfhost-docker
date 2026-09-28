#!/usr/bin/env bash
# The on-host Podman gate: twelve questions only a real host can answer.
#
# tmp/dune-selfhost-run2/01-gate-g0.md is a checklist an engineer is supposed
# to work through by hand on an enforcing AlmaLinux Podman VM -- five decision
# gates that branch a task and seven premise probes that confirm something a
# task already assumes. Two plans in a row left it undone, and the gate's own
# text says an unrecorded answer is one nobody can audit. This script is that
# checklist, mechanised: it runs every probe in the mandated order and prints a
# Markdown transcript on stdout that goes straight into the PR body.
#
# WHAT IT COSTS TO RUN. This is not a test you run on a workstation. It needs:
#
#   * A disposable VM. AlmaLinux 9 or 10, SELinux enforcing, Podman installed,
#     the branch checked out, the stack already installed and running. The
#     harness never installs or starts anything -- it is a post-install gate,
#     and a probe whose stack is down says so rather than bringing one up.
#   * Root. `ausearch` cannot read the audit log without it and
#     `systemctl restart podman.socket` cannot run without it. There is no
#     `sudo` anywhere in this file: where the harness cannot read, it reports
#     INCONCLUSIVE and says what is missing.
#   * A tolerance for damage, in three places:
#       - G0-2 restarts `podman.socket`. Every client of the compat API,
#         including `docker` itself, loses its connection for the duration.
#       - P5 destroys a running game server. It measures `docker rm -f`, which
#         is how every teardown site in the stack is spelled, and there is no
#         way to time that without actually removing a server.
#       - P3 mutates a running container's memory limits and restores the
#         recorded values afterwards. If the harness is killed between the two
#         it leaves that container at 2g.
#
# THE ONE PROPERTY THAT MATTERS. A probe whose precondition is absent prints
# INCONCLUSIVE, never ANSWERED. Every classification below is decided from a
# command's captured output and exit status; nothing infers an answer from the
# absence of evidence, and nothing falls back to a plausible default. A gate
# that passes vacuously is worse than no gate, because it gets recorded.
#
# TEST SEAMS, not operator knobs:
#
#   DUNE_GATE_SETTLE_SECONDS  Overrides every wait in the harness -- the 120 s
#                             AVC window in G0-2 and the 60 s cAdvisor scrape
#                             wait in G0-3 included. The CI test sets it to 0.
#                             Unset, each wait takes its documented time.
#
# The engine is read through the production seam (runtime/scripts/lib/engine.sh)
# and the loopback probe in P6 through the production function
# (runtime-env.sh's tcp_endpoint_reachable), so DUNE_CONTAINER_ENGINE and
# DOCKER_HOST already work here and are not re-implemented. Every external tool
# is reached through PATH so the CI test can shadow it with a stub.
set -euo pipefail

cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Probe registry
# ---------------------------------------------------------------------------

# G0-5 runs first because it is the only probe here that can quietly corrupt
# data, and it wants a host nothing has written to yet. G0-2 runs second
# because it changes host configuration that everything after it runs against.
# The rest follow the gate document. --only filters this list; it never
# reorders it.
GATE_PROBES=(G0-5 G0-2 G0-1 G0-3 G0-4 P1 P2 P3 P4 P5 P6 P7)

probe_title() {
  case "$1" in
    G0-5) printf '%s' "Does this host's \`containers.conf\` remap user namespaces?" ;;
    G0-2) printf '%s' "Does the stack come up enforcing with the \`label = false\` drop-in?" ;;
    G0-1) printf '%s' "Does Podman reject \`--log-opt max-file\`, or ignore it?" ;;
    G0-3) printf '%s' "Does cAdvisor report anything on Podman with \`--docker_only=true\`?" ;;
    G0-4) printf '%s' "Is the cgroup namespace actually private?" ;;
    P1) printf '%s' "Does the compat layer keep Docker's leading slash in container names?" ;;
    P2) printf '%s' "Does \`podman builder prune\` exist?" ;;
    P3) printf '%s' "Does \`docker update\` move memory limits through the compat endpoint?" ;;
    P4) printf '%s' "What field names and units does \`docker stats\` emit?" ;;
    P5) printf '%s' "How long does \`docker rm -f\` take on a running game server?" ;;
    P6) printf '%s' "Is a \`127.0.0.1\`-published port reachable from the host netns?" ;;
    P7) printf '%s' "Does a short image name resolve under \`short-name-mode = enforcing\`?" ;;
  esac
}

probe_decides() {
  case "$1" in
    G0-5) printf '%s' "A5 — a doc line plus a doctor warning, or pinning \`--userns=host\` in the spawn argv." ;;
    G0-2) printf '%s' "A3 sign-off — whether the SELinux blocker is complete as specified, with §14.11, §14.13 and §14.15 folded in." ;;
    G0-1) printf '%s' "A4 — a three-sentence doc fix, or a Compose overlay (and a P0)." ;;
    G0-3) printf '%s' "C9 — whether \`--docker_only\` must be parameterised, or 4 of 22 alerts go dark." ;;
    G0-4) printf '%s' "C13 — whether the memory balancer reads per-container or host-wide figures." ;;
    P1) printf '%s' "C3's premise, and the already-shipped \`stop-postgres-container.sh\` fix." ;;
    P2) printf '%s' "B2's premise, and \`storage.sh:177-181\`'s comment." ;;
    P3) printf '%s' "The memory balancer's live path (\`memory.sh:342\`, \`memory-swap.sh:96\`)." ;;
    P4) printf '%s' "E7, \`containerHealth.js:34\` and \`memoryBalancer.js:392-429\`." ;;
    P5) printf '%s' "Every \`rm -f\` teardown site, against \`shutdown-protection.service\`'s \`TimeoutStopSec=240\`." ;;
    P6) printf '%s' "\`resolve_rmq_game_host\`'s loopback branch (\`runtime-env.sh:485\`)." ;;
    P7) printf '%s' "Phase D's image-prefix rule — 14 unprefixed sites, or 21 prefixed ones." ;;
  esac
}

# The short label for the summary table's third column when a probe could not
# answer. The ANSWERED and BLOCKER rows use the verdict text's own prefix.
probe_tag() {
  case "$1" in
    G0-5) printf 'A5' ;;
    G0-2) printf 'A3' ;;
    G0-1) printf 'A4' ;;
    G0-3) printf 'C9' ;;
    G0-4) printf 'C13' ;;
    P1) printf 'C3' ;;
    P2) printf 'B2' ;;
    P3) printf 'memory balancer' ;;
    P4) printf 'E7' ;;
    P5) printf 'teardown timing' ;;
    P6) printf 'RMQ loopback' ;;
    P7) printf 'Phase D' ;;
  esac
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Progress, warnings and harness errors go to stderr so that `> gate.md` yields
# a transcript that pastes cleanly into a PR body.
note() {
  printf '%s\n' "$*" >&2
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Every wait in the harness goes through here so the CI test can collapse all
# of them with DUNE_GATE_SETTLE_SECONDS=0.
settle() {
  local seconds="${DUNE_GATE_SETTLE_SECONDS:-$1}"
  case "$seconds" in
    '' | *[!0-9]*) return 0 ;;
  esac
  [ "$seconds" -gt 0 ] || return 0
  note "  … waiting ${seconds}s"
  sleep "$seconds"
}

# Render one argument the way an operator would have typed it, so the
# transcript can be replayed by hand. The character class is the set that needs
# no quoting in any shell.
quote_arg() {
  local arg="$1"
  case "$arg" in
    '') printf "''" ;;
    *[!A-Za-z0-9_@%+=:,./-]*)
      arg="${arg//\'/\'\\\'\'}"
      printf "'%s'" "$arg"
      ;;
    *) printf '%s' "$arg" ;;
  esac
}

emit_block() {
  local display="$1" output="$2" status="$3"
  printf '```console\n'
  printf '$ %s\n' "$display"
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
  printf 'exit=%s\n' "$status"
  printf '```\n\n'
}

RUN_OUT=""
RUN_STATUS=0

# Run something in this shell, capture stdout and stderr together, print the
# block, and leave the result in RUN_OUT/RUN_STATUS for the caller to classify.
# The `if` wrapper is what keeps `set -e` from firing on a probe's own command:
# a non-zero exit is data here, not an error.
run_here() {
  local display="$1"
  shift
  RUN_OUT=""
  if RUN_OUT="$("$@" 2>&1)"; then
    RUN_STATUS=0
  else
    RUN_STATUS=$?
  fi
  emit_block "$display" "$RUN_OUT" "$RUN_STATUS"
}

run() {
  local display="" arg
  for arg in "$@"; do
    display+="${display:+ }$(quote_arg "$arg")"
  done
  run_here "$display" "$@"
}

# For the pipelines the gate document spells out literally. The snippet runs in
# a fresh `bash -c` without pipefail, which is the semantics an operator typing
# it at a prompt would get -- and the semantics the recorded answer has to
# match.
run_shell() {
  run_here "$1" bash -c "$1"
}

PROBE_VERDICT=""
PROBE_TEXT=""

verdict() {
  PROBE_VERDICT="$1"
  PROBE_TEXT="$2"
}

# Does the Docker CLI reach an engine at all? Cached, and deliberately silent:
# this is a precondition, not one of the gate's questions, and a block for it
# in every section would bury the commands that matter.
GATE_ENGINE_UP=""

engine_reachable() {
  if [ -z "$GATE_ENGINE_UP" ]; then
    if have docker && docker info >/dev/null 2>&1; then
      GATE_ENGINE_UP=yes
    else
      GATE_ENGINE_UP=no
    fi
  fi
  [ "$GATE_ENGINE_UP" = yes ]
}

# Print the names of every running container, without a block. Used by the
# probes that have to pick a subject before they can ask their question.
running_names() {
  docker ps --format '{{.Names}}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# G0-5 — user-namespace remapping
# ---------------------------------------------------------------------------

# The failure this prevents is silent and data-shaped. Game servers run
# `--privileged` with no `--user` and no `--userns` (spawn-server.sh:565) and
# bind the live save tree at spawn-server.sh:572. If this host's
# containers.conf defaults to `userns=auto`, everything the server writes there
# lands owned by a remapped subuid, nothing in the spawn argv contradicts it,
# and the stack keeps running. The damage surfaces on a restore, on the next
# ownership repair, or the first time a second container touches the tree.
probe_g0_5() {
  local config_note="" userns_mode="" saved_uid="" saved_line=""

  if have podman; then
    run podman info --format '{{.Host.IDMappings}}'
  else
    note "  G0-5: podman not on PATH; skipping the IDMappings read"
  fi

  run_shell "grep -rn '^[[:space:]]*userns' /etc/containers/containers.conf /etc/containers/containers.conf.d/ /usr/share/containers/containers.conf"
  if printf '%s\n' "$RUN_OUT" | grep -Eq "userns[[:space:]]*=[[:space:]]*[\"']?(auto|keep-id|nomap)"; then
    verdict ANSWERED "A5 branch (b): pin \`--userns=host\` — containers.conf remaps user namespaces by default"
    return 0
  fi
  if printf '%s\n' "$RUN_OUT" | grep -q 'userns'; then
    config_note="containers.conf mentions \`userns\` but not a remapping mode"
  else
    config_note="containers.conf sets no \`userns\` default"
  fi

  # Configuration was not decisive, so the answer has to come from a tree a
  # server has actually written to.
  if ! engine_reachable; then
    verdict INCONCLUSIVE "$config_note, and ground truth needs a running server: the Docker CLI cannot reach an engine here. Re-run on the Podman host with \`--only G0-5\`"
    return 0
  fi

  local server
  server="$(running_names | grep '^dune-server-' | head -n 1 || true)"
  if [ -z "$server" ]; then
    verdict INCONCLUSIVE "$config_note, so ground truth is required: no \`dune-server-*\` container is running. Start one server, then re-run with \`--only G0-5\`"
    return 0
  fi

  run docker inspect -f '{{.HostConfig.UsernsMode}}' "$server"
  userns_mode="$RUN_OUT"

  run_shell "stat -c '%u:%g %n' runtime/game/*/Saved"
  saved_line="$(printf '%s\n' "$RUN_OUT" | grep -E '^[0-9]+:[0-9]+ ' | head -n 1 || true)"
  if [ -z "$saved_line" ]; then
    verdict INCONCLUSIVE "$config_note, and \`$server\` is running, but no \`runtime/game/*/Saved\` tree exists to read ownership from. Let the server write once, then re-run with \`--only G0-5\`"
    return 0
  fi
  saved_uid="${saved_line%%:*}"

  # 65536 is the first uid outside the host's own range under the default
  # /etc/subuid allocation, so anything at or above it was written through a
  # remap.
  if [ "$saved_uid" -ge 65536 ]; then
    verdict ANSWERED "A5 branch (b): pin \`--userns=host\` — the save tree is owned by remapped uid $saved_uid"
    return 0
  fi
  case "$userns_mode" in
    '' | host)
      verdict ANSWERED "A5 branch (a): doc line plus a doctor warning, no argv change — save tree owned by host uid $saved_uid, \`UsernsMode\` is '${userns_mode:-empty}'"
      ;;
    *)
      verdict ANSWERED "A5 branch (b): pin \`--userns=host\` — \`UsernsMode\` is \`$userns_mode\`"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# G0-2 — the stack under enforcing SELinux
# ---------------------------------------------------------------------------

# Runs the same AVC scan twice: once over the settled stack, once after the
# privileged host-systemd helper. Returns non-zero when any AVC names one of
# the three types A3 has to keep quiet, and leaves the scan output in RUN_OUT.
# Classifying on a grep of the captured text rather than on grep's exit status
# matters because ausearch's own stderr is folded into the same stream.
scan_avcs() {
  run_shell "ausearch -m avc -ts recent | grep -E 'container_t|container_file_t|container_runtime_t'"
  ! printf '%s\n' "$RUN_OUT" | grep -qE 'container_t|container_file_t|container_runtime_t'
}

# The failure this prevents is a release signed off as "A3 complete" on a host
# where SELinux was permissive, or where the stack was never up. It also folds
# in §14.11, §14.13 and §14.15, which the gate document puts here because they
# want this same host in this same state.
probe_g0_2() {
  local failures="" avc_line="" helper_image="" net_container="" mode="" group=""
  local -a label_args=()

  if ! have getenforce; then
    verdict INCONCLUSIVE "\`getenforce\` is not on PATH, so this host's SELinux mode is unknown. The gate must run on an enforcing AlmaLinux VM"
    return 0
  fi
  run getenforce
  if [ "$RUN_OUT" != "Enforcing" ]; then
    verdict INCONCLUSIVE "SELinux reports '${RUN_OUT:-nothing}', not Enforcing. A3 can only be signed off against an enforcing host"
    return 0
  fi

  # No sudo here by design: the harness documents that it needs root and says
  # so rather than escalating.
  if [ "$(id -u)" != "0" ]; then
    verdict INCONCLUSIVE "not running as root: \`ausearch\` cannot read the audit log and \`systemctl restart podman.socket\` cannot run. Re-run as root with \`--only G0-2\`"
    return 0
  fi
  if ! have ausearch; then
    verdict INCONCLUSIVE "\`ausearch\` is not on PATH (install \`audit\`); without it no AVC can be observed and a clean result would be vacuous"
    return 0
  fi
  if ! have podman; then
    verdict INCONCLUSIVE "\`podman\` is not on PATH, so §14.13's \`podman network inspect dune-net\` cannot run. This gate must run on the Podman host itself"
    return 0
  fi
  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed); the compat socket has to be up before the stack can be judged"
    return 0
  fi

  local names
  names="$(running_names)"
  if ! printf '%s\n' "$names" | grep -qx 'redblink-dune-docker-console' \
    || ! printf '%s\n' "$names" | grep -qx 'dune-postgres'; then
    verdict INCONCLUSIVE "the stack is not up (\`redblink-dune-docker-console\` and \`dune-postgres\` must both be running). This is a post-install gate: it does not install or start the stack. Install it, then re-run with \`--only G0-2\`"
    return 0
  fi

  run_shell "ausearch -m avc -ts recent --raw | wc -l"
  if printf '%s\n' "$RUN_OUT" | grep -qiE 'permission denied|operation not permitted|must be root|error opening'; then
    verdict INCONCLUSIVE "\`ausearch\` cannot read the audit log on this host, so no AVC scan below would mean anything"
    return 0
  fi

  settle 120

  if ! scan_avcs; then
    avc_line="$(printf '%s\n' "$RUN_OUT" | grep -E 'container_t|container_file_t|container_runtime_t' | head -n 1)"
    verdict BLOCKER "A3 does not close the gap — container AVCs were recorded while the stack ran, quoted in full in the block above. First: $avc_line"
    return 0
  fi

  # The three exec assertions the gate document requires to print. Each one is
  # a different half of A3: the console's bind mount, Prometheus's config bind,
  # and a spawned container reaching the engine socket.
  run docker exec redblink-dune-docker-console ls /repo
  [ "$RUN_STATUS" -eq 0 ] || failures="${failures}the console cannot read /repo; "

  run docker exec dune-prometheus cat /etc/prometheus/prometheus.yml
  [ "$RUN_STATUS" -eq 0 ] || failures="${failures}Prometheus cannot read its config; "

  run docker exec dune-autoscaler docker version
  [ "$RUN_STATUS" -eq 0 ] || failures="${failures}a spawned container cannot reach the engine socket; "

  # §14.11 — one privileged host-systemd helper end to end, spelled exactly as
  # the 17 real sites spell it (db.sh:3616, restart-schedule.sh:288 and the
  # rest). `container_t` reaching `init_t` through chroot is where SELinux
  # objects hardest; under A3 these run unconfined and this is what says so.
  # The label-disable splice mirrors runtime-env.sh:53-55.
  if declare -F dune_engine_label_disable_args >/dev/null 2>&1 \
    && [ -n "$(dune_engine_label_disable_args)" ]; then
    label_args=(--security-opt label=disable)
  fi
  helper_image="${DUNE_SYSTEMD_HELPER_IMAGE:-redblink-dune-docker-console:dev}"
  run docker run --rm --user 0:0 --privileged --pid=host --network=host \
    "${label_args[@]}" \
    -v /:/host \
    --entrypoint bash \
    "$helper_image" -lc 'set -euo pipefail; chroot /host /bin/systemctl --version'
  [ "$RUN_STATUS" -eq 0 ] || failures="${failures}the privileged host-systemd helper (§14.11) failed; "

  if ! scan_avcs; then
    avc_line="$(printf '%s\n' "$RUN_OUT" | grep -E 'container_t|container_file_t|container_runtime_t' | head -n 1)"
    verdict BLOCKER "A3 does not close the gap — the §14.11 host-systemd helper produced a container AVC. First: $avc_line"
    return 0
  fi

  # §14.13 — bridge DNS. Twenty call sites address a peer by container name; on
  # Podman resolution is opt-in per network and the compat API cannot ask for
  # it, so an NXDOMAIN here is a runtime failure with no error at create time.
  run docker network inspect dune-net --format '{{range $name, $c := .Containers}}{{$c.Name}} {{end}}'
  net_container="$(printf '%s\n' "$RUN_OUT" | tr ' ' '\n' | grep -v '^$' | head -n 1 || true)"
  if [ -z "$net_container" ]; then
    failures="${failures}no container is attached to dune-net, so bridge DNS (§14.13) could not be tested; "
  else
    run docker exec "$net_container" getent hosts dune-postgres
    [ "$RUN_STATUS" -eq 0 ] || failures="${failures}dune-postgres does not resolve on dune-net; "
    run docker exec "$net_container" getent hosts dune-text-router
    [ "$RUN_STATUS" -eq 0 ] || failures="${failures}dune-text-router does not resolve on dune-net; "
  fi
  run_shell "podman network inspect dune-net | grep -i dns_enabled"
  if ! printf '%s\n' "$RUN_OUT" | grep -qi 'true'; then
    failures="${failures}dune-net reports dns_enabled other than true; "
  fi

  # §14.15 — A3 drops the ExecStartPost relabel, but SocketGroup and
  # SocketMode=0660 still come from the drop-in and still have to survive a
  # restart. This is the command that takes the live socket down.
  note "  G0-2: restarting podman.socket (§14.15) — every compat-API client drops"
  run systemctl restart podman.socket
  [ "$RUN_STATUS" -eq 0 ] || failures="${failures}systemctl restart podman.socket failed; "
  settle 5
  run ls -ld /var/run/docker.sock
  if [ "$RUN_STATUS" -ne 0 ]; then
    failures="${failures}/var/run/docker.sock is gone after the socket restart; "
  else
    read -r mode _ _ group _ <<<"$RUN_OUT"
    case "$mode" in
      srw-rw----*) ;;
      *) failures="${failures}socket mode is '$mode', not 0660 — SocketMode did not survive the restart; " ;;
    esac
    if [ "$group" = "root" ]; then
      failures="${failures}socket group is root — SocketGroup did not survive the restart; "
    fi
  fi

  if [ -n "$failures" ]; then
    verdict BLOCKER "A3 is not complete as specified: ${failures%; }"
  else
    verdict ANSWERED "A3 complete as specified: no container AVCs, the three exec assertions, §14.11's host-systemd helper, §14.13's bridge DNS and §14.15's socket drop-in all hold"
  fi
}

# ---------------------------------------------------------------------------
# G0-1 — --log-opt max-file
# ---------------------------------------------------------------------------

# The branch asserts three mutually exclusive behaviours for this flag
# (engine.sh:130 "not max-file", CONTAINER-ENGINES.md:124 "rejects",
# CONTAINER-ENGINES.md:380 "rotate by size only" i.e. ignored, and
# operator-guide.md:36 "truncated rather than rolled"). If it is rejected,
# `docker compose up`
# fails at container creation for the orchestrator, the console and the public
# probe -- the three most important Compose-managed containers -- and A4 stops
# being a doc fix.
probe_g0_1() {
  local compose_file direct_status compose_status

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so a non-zero exit here would say nothing about \`max-file\`"
    return 0
  fi

  run docker run --rm --log-driver json-file \
    --log-opt max-size=10m --log-opt max-file=3 \
    docker.io/library/alpine:3.22 true
  direct_status="$RUN_STATUS"

  compose_file="$GATE_TMP/g01.yml"
  cat >"$compose_file" <<'YML'
services:
  probe:
    image: docker.io/library/alpine:3.22
    command: ["true"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
YML
  run docker compose -f "$compose_file" up --abort-on-container-exit
  compose_status="$RUN_STATUS"

  # `up` leaves the project's container behind, and $GATE_TMP goes with the
  # EXIT trap -- so without this the operator is left with a stray container
  # and no compose file to tear it down with. Same reasoning as P3's restore
  # and P6's `rm -f`: the probe puts the host back, and the transcript shows
  # it doing so.
  run docker compose -f "$compose_file" down --remove-orphans
  if [ "$RUN_STATUS" -ne 0 ]; then
    note "  G0-1: WARNING — \`docker compose down\` exited $RUN_STATUS; the probe project may still exist"
  fi

  if [ "$direct_status" -eq 0 ] && [ "$compose_status" -eq 0 ]; then
    verdict ANSWERED "A4 branch (a): \`max-file\` is accepted and ignored — three sentences of doc, no code"
  else
    verdict BLOCKER "A4 branch (b), re-classify A4 as P0: \`max-file\` is rejected (direct exit=$direct_status, compose exit=$compose_status), so \`docker compose up\` fails at container creation for the orchestrator, the console and the public probe"
  fi
}

# ---------------------------------------------------------------------------
# G0-3 — cAdvisor under --docker_only=true
# ---------------------------------------------------------------------------

# cAdvisor with --docker_only asks the Docker daemon for the container list. On
# Podman there is no daemon behind that call in the shape cAdvisor expects, and
# the failure mode is an empty metric set rather than an error: Prometheus
# scrapes happily, and four of the twenty-two alerts simply never fire.
probe_g0_3() {
  local names scrape

  # cAdvisor publishes no host port: docker-compose.metrics.yml puts it on
  # `dune-net` and Prometheus reaches it at dune-cadvisor:8080. The scrape has
  # to come from that network, so it goes through a throwaway BusyBox attached
  # to it. Asking localhost:8080 would fail on Docker too, and a check that
  # cannot pass on either engine answers nothing.
  scrape="docker run --rm --network dune-net docker.io/library/busybox:1.37 wget -qO- http://dune-cadvisor:8080/metrics"

  if [ ! -x runtime/scripts/metrics-stack.sh ]; then
    verdict INCONCLUSIVE "runtime/scripts/metrics-stack.sh is not executable here, so the metrics stack cannot be brought up"
    return 0
  fi
  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed); the metrics stack cannot start"
    return 0
  fi

  run runtime/scripts/metrics-stack.sh up
  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "\`metrics-stack.sh up\` exited $RUN_STATUS, so cAdvisor never started and nothing about \`--docker_only\` was observed"
    return 0
  fi

  settle 60

  # Reachability is asked separately because the two pipelines below swallow
  # wget's exit status, and "cAdvisor reports nothing" and "cAdvisor cannot be
  # reached" are different answers.
  run_shell "$scrape >/dev/null"
  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "cAdvisor's /metrics is not reachable on \`dune-net\` at dune-cadvisor:8080 (exit=$RUN_STATUS); the scrape wait may be too short, the container may have exited, or the BusyBox helper image could not be pulled"
    return 0
  fi

  # A negative result only means something if there was something to name. On a
  # host with no `dune-*` container running, "cAdvisor names none" is a fact
  # about the host, not about `--docker_only`, and reporting C9 as required on
  # that basis would be a vacuous pass.
  if ! running_names | grep -q '^dune-'; then
    verdict INCONCLUSIVE "the metrics stack is up but no \`dune-*\` container is running for cAdvisor to name, so an empty scrape would say nothing about \`--docker_only\`. Bring the stack up and re-run with \`--only G0-3\`"
    return 0
  fi

  run_shell "$scrape | grep -c '^container_cpu_usage_seconds_total'"
  run_shell "$scrape | grep -o 'name=\"dune-[a-z-]*\"' | sort -u"
  names="$RUN_OUT"
  # Only the factory lines, because they carry the whole explanation: cAdvisor
  # registers a Docker factory and a Podman factory, and `--docker_only` keeps
  # the first. A plain tail would bury that under cAdvisor's `Machine:` dump,
  # which is one line several hundred kilobytes wide and would make the
  # transcript unpasteable.
  run_shell "docker logs dune-cadvisor 2>&1 | grep -E 'factory|plugin\.go|Starting cAdvisor' | tail -20"

  if printf '%s\n' "$names" | grep -q 'name="dune-'; then
    verdict ANSWERED "C9 not needed: cAdvisor names the stack's containers under \`--docker_only=true\`"
  else
    verdict ANSWERED "C9 required: \`--docker_only\` must be parameterised, or 4 of 22 alerts go dark — cAdvisor names no \`dune-*\` container"
  fi
}

# ---------------------------------------------------------------------------
# G0-4 — private cgroup namespace
# ---------------------------------------------------------------------------

# The Console's memory balancer reads memory.swap.current from inside a game
# container and treats the number as that container's own. Under a host cgroup
# namespace the same read returns the host root's figures -- a plausible
# number, so the balancer moves memory on host-wide swap and nothing looks
# wrong. §12 rated this the risk most likely to produce a confusing runtime
# failure.
probe_g0_4() {
  local cgroup_line

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so no container's cgroup can be read"
    return 0
  fi

  if have podman; then
    run podman info --format '{{.Host.CgroupsVersion}} {{.Host.CgroupManager}}'
  else
    note "  G0-4: podman not on PATH; skipping the cgroup-manager read"
  fi

  run docker inspect -f '{{.HostConfig.CgroupnsMode}}' dune-server-gateway dune-autoscaler
  run docker exec dune-server-gateway cat /proc/self/cgroup
  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "\`dune-server-gateway\` is not running, so its cgroup path cannot be read. Start the gateway server and re-run with \`--only G0-4\`"
    return 0
  fi
  cgroup_line="$(printf '%s\n' "$RUN_OUT" | grep '^0::' | head -n 1 || true)"
  if [ -z "$cgroup_line" ]; then
    verdict INCONCLUSIVE "\`/proc/self/cgroup\` in \`dune-server-gateway\` has no cgroup-v2 (\`0::\`) line; this host is not on unified cgroups and C13's premise does not apply as written"
    return 0
  fi

  run docker exec dune-server-gateway cat /sys/fs/cgroup/memory.max

  if [ "$cgroup_line" = "0::/" ]; then
    verdict ANSWERED "C13 not needed: the gateway's cgroup namespace is private (\`0::/\`)"
  else
    verdict BLOCKER "C13 required: the gateway sees a host cgroup path (\`$cgroup_line\`), so the memory balancer is reading host-wide figures for that container"
  fi
}

# ---------------------------------------------------------------------------
# P1 — the leading slash
# ---------------------------------------------------------------------------

# §5.6 called this the one item where sources genuinely conflict. C3 and the
# already-shipped stop-postgres-container.sh both assume the compat layer drops
# Docker's leading slash, so `--filter 'name=^/dune-postgres$'` never matches
# and a "does it exist" check answers no for a running container. If the slash
# survives, C3 inverts and the shipped fix is the regression.
probe_p1() {
  local slashed=0 bare=0

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so neither name filter can be evaluated"
    return 0
  fi

  run_shell "docker ps -a --filter 'name=^/dune-postgres\$'"
  if printf '%s\n' "$RUN_OUT" | grep -q 'dune-postgres'; then
    slashed=1
  fi

  run_shell "docker ps -a --filter 'name=^dune-postgres\$'"
  if printf '%s\n' "$RUN_OUT" | grep -q 'dune-postgres'; then
    bare=1
  fi

  if [ "$slashed" -eq 0 ] && [ "$bare" -eq 0 ]; then
    run docker ps -a --format '{{.Names}}'
    verdict INCONCLUSIVE "neither filter matched and no \`dune-postgres\` container exists on this host, so nothing was learned about the leading slash. Start Postgres and re-run with \`--only P1\`"
    return 0
  fi

  if [ "$bare" -eq 1 ] && [ "$slashed" -eq 0 ]; then
    verdict ANSWERED "C3's premise holds: the slash-less filter matches and the slashed one does not"
  elif [ "$slashed" -eq 1 ] && [ "$bare" -eq 0 ]; then
    verdict BLOCKER "C3 inverts and the shipped fix is the regression: the compat layer keeps Docker's leading slash"
  else
    verdict ANSWERED "C3's premise holds: the slash-less filter matches (the slashed spelling matches too, so C3's change is safe either way)"
  fi
}

# ---------------------------------------------------------------------------
# P2 — builder prune
# ---------------------------------------------------------------------------

# storage.sh:177-181 asserts in a comment that `podman builder prune` does not
# exist and that the compat API does not implement /build/prune. B2 says that
# is wrong on current Podman. Whichever way this lands, one of the two comments
# has to stop asserting something false -- which is the whole point of running
# it.
probe_p2() {
  local compat_status

  if ! have podman; then
    verdict INCONCLUSIVE "\`podman\` is not on PATH, so \`podman builder prune --help\` cannot be asked. Re-run on the Podman host with \`--only P2\`"
    return 0
  fi
  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so the compat half of this probe cannot run"
    return 0
  fi

  run docker builder prune --force --all
  compat_status="$RUN_STATUS"

  run podman builder prune --help

  if [ "$RUN_STATUS" -eq 0 ]; then
    verdict ANSWERED "B2 is right: \`podman builder prune\` exists, so \`storage.sh:177-181\`'s comment must stop asserting it does not (compat \`docker builder prune\` exit=$compat_status)"
  else
    verdict ANSWERED "B2 is wrong: \`podman builder prune\` is absent as \`storage.sh:177-181\` says, so B2's claim is what has to change (compat \`docker builder prune\` exit=$compat_status)"
  fi
}

# ---------------------------------------------------------------------------
# P3 — docker update on the compat endpoint
# ---------------------------------------------------------------------------

# Native `podman update` takes these flags; whether the compat endpoint honours
# them is open. memory.sh:342 and memory-swap.sh:96 are on the live path, so a
# silent no-op leaves the memory balancer running, reporting success, and
# moving nothing. Exit status alone cannot tell the two apart, which is why
# this reads the value back.
#
# This probe mutates a running container and restores the recorded values.
probe_p3() {
  local subject before after mem swap reservation

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so no container can be updated"
    return 0
  fi

  subject="$(running_names | grep -v '^dune-server-' | head -n 1 || true)"
  if [ -z "$subject" ]; then
    verdict INCONCLUSIVE "no running non-game container to mutate. Bring the stack up and re-run with \`--only P3\`"
    return 0
  fi

  run docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.MemoryReservation}}' "$subject"
  before="$RUN_OUT"
  read -r mem swap reservation <<<"$before"
  case "${mem:-x}${swap:-x}${reservation:-x}" in
    *[!0-9-]*)
      verdict INCONCLUSIVE "could not read the current memory limits of \`$subject\` ('${before:-nothing}'), so nothing may be mutated — the harness will not change a limit it cannot restore"
      return 0
      ;;
  esac

  run docker update --memory 2g --memory-swap 4g --memory-reservation 2g "$subject"
  local update_status="$RUN_STATUS"

  run docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.MemorySwap}} {{.HostConfig.MemoryReservation}}' "$subject"
  after="$RUN_OUT"

  # Restore whatever happened above, including when the update errored: a
  # partially applied change is exactly the state this probe must not leave.
  run docker update --memory "$mem" --memory-swap "$swap" --memory-reservation "$reservation" "$subject"
  if [ "$RUN_STATUS" -ne 0 ]; then
    note "  P3: WARNING — could not restore the memory limits of $subject; it may still be at 2g"
  fi

  if [ "$update_status" -ne 0 ]; then
    verdict ANSWERED "visible rejection: the compat endpoint refuses \`docker update\` outright (exit=$update_status), so \`memory.sh:342\` and \`memory-swap.sh:96\` surface the error rather than report a move that never happened"
    return 0
  fi
  if [ "$after" = "$before" ]; then
    verdict BLOCKER "silent no-op: the memory balancer reports success and moves nothing — \`docker update\` exited 0 and the limits stayed at '$before' (\`memory.sh:342\`, \`memory-swap.sh:96\`)"
  else
    verdict ANSWERED "the memory balancer's live path holds: \`docker update\` moved the limits from '$before' to '$after'"
  fi
}

# ---------------------------------------------------------------------------
# P4 — docker stats field names
# ---------------------------------------------------------------------------

# E7 covers only CPUPerc. containerHealth.js:34 also reads MemUsage and splits
# it on `/`; memoryBalancer.js:392-429 and manager.sh:806 read .Name; NetIO and
# BlockIO feed the same table. Both JS consumers degrade to an empty table
# instead of erroring, so a renamed field is invisible in production and can
# only be caught here.
probe_p4() {
  local missing="" field lines

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so \`docker stats\` has nothing to report"
    return 0
  fi

  run_shell "docker stats --no-stream --format '{{json .}}'"
  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "\`docker stats\` exited $RUN_STATUS, so no field names were observed"
    return 0
  fi
  lines="$(printf '%s\n' "$RUN_OUT" | grep -c '^{' || true)"
  if [ "$lines" -lt 2 ]; then
    verdict INCONCLUSIVE "\`docker stats\` reported $lines container(s); the probe wants at least two. Bring the stack up and re-run with \`--only P4\`"
    return 0
  fi

  for field in CPUPerc MemUsage NetIO BlockIO Name; do
    if ! printf '%s\n' "$RUN_OUT" | grep -q "\"$field\""; then
      missing="${missing}$field "
    fi
  done

  if [ -n "$missing" ]; then
    verdict BLOCKER "E7 and both JS consumers break silently: \`docker stats\` does not emit ${missing% }"
  else
    verdict ANSWERED "E7's premise holds: CPUPerc, MemUsage, NetIO, BlockIO and Name are all present across $lines containers — units recorded verbatim in the block above"
  fi
}

# ---------------------------------------------------------------------------
# P5 — teardown timing
# ---------------------------------------------------------------------------

# Every teardown in the stack is `rm -f`, never `stop`. Docker SIGKILLs at
# once; Podman has at points honoured the stop timeout first. It diverges in
# the safe direction, but the teardown is per container and
# shutdown-protection.service has TimeoutStopSec=240.
#
# This probe destroys a running game server. There is no way to time `rm -f`
# without removing something.
probe_p5() {
  local server started elapsed real_line

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so no teardown can be timed"
    return 0
  fi

  server="$(running_names | grep '^dune-server-' | head -n 1 || true)"
  if [ -z "$server" ]; then
    verdict INCONCLUSIVE "no \`dune-server-*\` container is running, and this probe measures removing one. Start a game server and re-run with \`--only P5\`"
    return 0
  fi

  note "  P5: destroying game server $server — this is not recoverable"
  started=$SECONDS
  run_shell "time docker rm -f $server"
  elapsed=$((SECONDS - started))
  real_line="$(printf '%s\n' "$RUN_OUT" | grep -E '^real' | head -n 1 || true)"

  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "\`docker rm -f $server\` exited $RUN_STATUS, so the teardown was never completed and nothing was timed"
    return 0
  fi

  if [ "$elapsed" -le 1 ]; then
    verdict ANSWERED "teardown timing is safe: \`rm -f\` returned in under two seconds (${real_line:-no \`time\` line captured}), so any number of servers fits inside \`shutdown-protection.service\`'s \`TimeoutStopSec=240\`"
  else
    verdict ANSWERED "teardown timing: \`rm -f\` took ${elapsed}s (${real_line:-no \`time\` line captured}), so $((240 / elapsed)) servers fit inside \`shutdown-protection.service\`'s \`TimeoutStopSec=240\`"
  fi
}

# ---------------------------------------------------------------------------
# P6 — loopback publish under rootful Podman
# ---------------------------------------------------------------------------

# resolve_rmq_game_host() probes 127.0.0.1 and silently falls back to the bind
# IP. test-rmq-host-resolution.sh:68-71 covers the branch logic; nothing covers
# whether the probe can succeed at all under rootful Podman. If it cannot,
# every host-network game server takes the fallback permanently and nothing
# reports it -- so this sources the shipped probe rather than reimplementing
# it, because a reimplementation would be testing the wrong function.
probe_p6() {
  local container port="" candidate

  if ! engine_reachable; then
    verdict INCONCLUSIVE "the Docker CLI cannot reach an engine (\`docker info\` failed), so no port can be published"
    return 0
  fi
  if [ ! -r runtime/scripts/runtime-env.sh ]; then
    verdict INCONCLUSIVE "runtime/scripts/runtime-env.sh is not readable here, so the shipped \`tcp_endpoint_reachable\` cannot be sourced"
    return 0
  fi
  # shellcheck source=/dev/null
  if ! . runtime/scripts/runtime-env.sh || ! declare -F tcp_endpoint_reachable >/dev/null 2>&1; then
    verdict INCONCLUSIVE "sourcing runtime/scripts/runtime-env.sh did not yield \`tcp_endpoint_reachable\`; reimplementing it here would test the wrong function"
    return 0
  fi
  # tcp_endpoint_reachable needs one of these to connect at all. Without
  # either, it returns 1 for every endpoint and a BLOCKER here would be an
  # artefact of the host's missing tooling, not of the engine.
  if ! have python3 && ! have timeout; then
    verdict INCONCLUSIVE "neither \`python3\` nor \`timeout\` is installed, so \`tcp_endpoint_reachable\` cannot succeed on this host whatever the engine does"
    return 0
  fi

  for _ in 1 2 3 4 5; do
    candidate=$((34000 + RANDOM % 1000))
    if ! tcp_endpoint_reachable 127.0.0.1 "$candidate"; then
      port="$candidate"
      break
    fi
  done
  if [ -z "$port" ]; then
    verdict INCONCLUSIVE "could not find a free loopback port in 34000-34999 after 5 attempts"
    return 0
  fi

  # The listener is BusyBox `nc` looping one connection at a time: the probe
  # needs two connections, the self-check below and tcp_endpoint_reachable's.
  # alpine:3.22 ships neither `httpd` nor `wget`, so `nc` is what this image
  # has -- and tcp_endpoint_reachable is a TCP connect, so a TCP listener is
  # all the question needs. No `--rm`: a container that dies on startup takes
  # its logs with it, and then the transcript cannot say why.
  container="dune-gate-p6-$$"
  run docker run -d --name "$container" -p "127.0.0.1:$port:80" \
    docker.io/library/alpine:3.22 \
    sh -c 'while true; do printf ok | nc -l -p 80; done'
  if [ "$RUN_STATUS" -ne 0 ]; then
    run docker rm -f "$container"
    verdict INCONCLUSIVE "the probe container would not start, so nothing was learned about loopback publishing"
    return 0
  fi

  settle 3

  # Prove the listener exists before blaming the publish. A container that
  # never listened would otherwise read as an unreachable published port.
  run docker exec "$container" nc 127.0.0.1 80
  if [ "$RUN_STATUS" -ne 0 ]; then
    run docker logs "$container"
    run docker rm -f "$container"
    verdict INCONCLUSIVE "the probe container never listened on its own port, so the published mapping was never exercised — its log is in the block above"
    return 0
  fi

  run_here "tcp_endpoint_reachable 127.0.0.1 $port" tcp_endpoint_reachable 127.0.0.1 "$port"
  if [ "$RUN_STATUS" -eq 0 ]; then
    run docker rm -f "$container"
    verdict ANSWERED "the resolver's loopback branch works: a \`127.0.0.1:$port\` publish is reachable from the host netns"
  else
    run docker rm -f "$container"
    verdict BLOCKER "every host-network game server takes the silent fallback permanently: a \`127.0.0.1:$port\` publish is not reachable from the host netns, so \`resolve_rmq_game_host\` never returns 127.0.0.1"
  fi
}

# ---------------------------------------------------------------------------
# P7 — short-name resolution under enforcing
# ---------------------------------------------------------------------------

# Phase D argues the 14 unprefixed sites are safe because they are input
# positions where short-name lookup resolves. That holds only if lookup does
# not error under short-name-mode = enforcing. If it errors, the prefix is
# needed at all 21 sites and D's simplification becomes work.
probe_p7() {
  local conf

  if ! have podman; then
    verdict INCONCLUSIVE "\`podman\` is not on PATH; short-name resolution is podman's own behaviour and cannot be asked through the compat socket. Re-run on the Podman host with \`--only P7\`"
    return 0
  fi

  run podman run --rm docker.io/library/alpine:3.22 true
  if [ "$RUN_STATUS" -ne 0 ]; then
    verdict INCONCLUSIVE "the control run of a fully-qualified image failed (exit=$RUN_STATUS), so a failure under \`enforcing\` would not be attributable to short-name resolution"
    return 0
  fi

  conf="$GATE_TMP/short-name.conf"
  cat >"$conf" <<'CONF'
[engine]
short-name-mode = "enforcing"
CONF

  # No TTY: under `enforcing` podman prompts when it can, and a prompt in a
  # harness is a hang. stdin from /dev/null forces the non-interactive answer,
  # which is the one the 14 call sites will get.
  run_shell "CONTAINERS_CONF=$conf podman run --rm ubuntu:24.04 true </dev/null"

  if [ "$RUN_STATUS" -eq 0 ]; then
    verdict ANSWERED "D's simplification holds: a short name resolves under \`short-name-mode = enforcing\`, so the 14 unprefixed input positions are safe"
  elif printf '%s\n' "$RUN_OUT" | grep -qiE 'short-name|short name|fully.qualified|unqualified-search-registries'; then
    verdict ANSWERED "the prefix is needed at all 21 sites; D becomes work — short-name lookup errors under \`enforcing\`"
  else
    verdict INCONCLUSIVE "podman exited $RUN_STATUS for a reason that does not name short-name resolution (a pull or network failure would look like this), so D's premise is untested"
  fi
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

# Named, not computed from the ID. A `"probe_$id"` indirection would save six
# lines and cost every static checker its view of which probes exist.
dispatch_probe() {
  case "$1" in
    G0-5) probe_g0_5 ;;
    G0-2) probe_g0_2 ;;
    G0-1) probe_g0_1 ;;
    G0-3) probe_g0_3 ;;
    G0-4) probe_g0_4 ;;
    P1) probe_p1 ;;
    P2) probe_p2 ;;
    P3) probe_p3 ;;
    P4) probe_p4 ;;
    P5) probe_p5 ;;
    P6) probe_p6 ;;
    P7) probe_p7 ;;
  esac
}


usage() {
  cat <<'USAGE'
Usage: tests/podman-host-gate.sh [--only ID[,ID...]] [--help]

Runs the on-host Podman gate (tmp/dune-selfhost-run2/01-gate-g0.md) and prints
a Markdown transcript on stdout. Progress and warnings go to stderr, so
`tests/podman-host-gate.sh > gate.md` yields a paste-able PR body.

  --only ID[,ID...]   Run only these probes. They still run in the declared
                      order below, never in the order given.
  --help              Print this and exit.

Probes, in run order:

  G0-5  containers.conf user-namespace remapping   (decides A5)
  G0-2  the stack under enforcing SELinux          (decides A3 sign-off)
  G0-1  --log-opt max-file                         (decides A4)
  G0-3  cAdvisor under --docker_only=true          (decides C9)
  G0-4  private cgroup namespace                   (decides C13)
  P1    the leading slash in container names       (confirms C3)
  P2    builder prune                              (confirms B2)
  P3    docker update on the compat endpoint       (confirms the memory balancer)
  P4    docker stats field names                   (confirms E7)
  P5    teardown timing                            (confirms every rm -f site)
  P6    loopback publish under rootful Podman      (confirms resolve_rmq_game_host)
  P7    short-name resolution under enforcing      (confirms Phase D)

Requires root, an enforcing AlmaLinux 9/10 Podman VM, and the stack already
installed and running. G0-2 restarts podman.socket, P5 destroys a running game
server, and P3 mutates and restores a container's memory limits. Run it on a
disposable host.

Exit status: 0 all answered, 1 a blocker, 2 an inconclusive probe, 64 usage.
USAGE
}

main() {
  local -a selected=()
  local -a requested=()
  local arg id probe
  local answered=0 blockers=0 inconclusive=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help | -h)
        usage
        return 0
        ;;
      --only)
        [ "$#" -ge 2 ] || {
          note "podman-host-gate: --only needs a probe ID"
          return 64
        }
        IFS=',' read -r -a requested <<<"$2"
        shift 2
        ;;
      --only=*)
        IFS=',' read -r -a requested <<<"${1#--only=}"
        shift
        ;;
      *)
        note "podman-host-gate: unknown argument '$1'"
        note "Try 'tests/podman-host-gate.sh --help'."
        return 64
        ;;
    esac
  done

  if [ "${#requested[@]}" -gt 0 ]; then
    for arg in "${requested[@]}"; do
      local known=0
      for probe in "${GATE_PROBES[@]}"; do
        if [ "$arg" = "$probe" ]; then
          known=1
        fi
      done
      if [ "$known" -ne 1 ]; then
        note "podman-host-gate: unknown probe ID '$arg'"
        note "Known IDs: ${GATE_PROBES[*]}"
        return 64
      fi
    done
    # Declared order, not the order the operator typed.
    for probe in "${GATE_PROBES[@]}"; do
      for arg in "${requested[@]}"; do
        if [ "$arg" = "$probe" ]; then
          selected+=("$probe")
          break
        fi
      done
    done
  else
    selected=("${GATE_PROBES[@]}")
  fi

  GATE_TMP="$(mktemp -d)"
  trap 'rm -rf "$GATE_TMP"' EXIT

  # The production seam, so DUNE_CONTAINER_ENGINE and DOCKER_HOST behave here
  # exactly as they do in the runtime scripts. Guarded: a fixture tree that
  # only carries this harness still runs, it just reports the engine as unknown
  # rather than inventing one.
  if [ -r runtime/scripts/lib/engine.sh ]; then
    # shellcheck source=/dev/null
    . runtime/scripts/lib/engine.sh
  fi

  local timestamp hostname_value pretty kernel checkout
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if have hostname; then
    hostname_value="$(hostname 2>/dev/null || printf 'unknown')"
  else
    hostname_value="$(uname -n 2>/dev/null || printf 'unknown')"
  fi
  pretty="unknown OS"
  if [ -r /etc/os-release ]; then
    pretty="$(sed -n 's/^PRETTY_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n 1)"
    pretty="${pretty:-unknown OS}"
  fi
  kernel="$(uname -r 2>/dev/null || printf 'unknown')"
  checkout="not a git checkout"
  if have git; then
    checkout="$(git rev-parse HEAD 2>/dev/null || printf 'not a git checkout')"
  fi

  printf '# Podman host gate — %s\n\n' "$timestamp"
  printf 'Host: %s · %s · kernel %s\n' "$hostname_value" "$pretty" "$kernel"
  printf 'Engine: %s · socket %s\n' "${DUNE_ENGINE_KIND:-unknown}" "${DUNE_ENGINE_SOCKET:-unknown}"
  printf 'Checkout: %s\n' "$checkout"
  printf 'Probes: %s\n' "${selected[*]}"

  local -a summary_ids=() summary_verdicts=() summary_decides=()

  for id in "${selected[@]}"; do
    note "podman-host-gate: $id"
    printf '\n## %s — %s\n\n' "$id" "$(probe_title "$id")"
    printf 'Decides: %s\n\n' "$(probe_decides "$id")"

    PROBE_VERDICT=""
    PROBE_TEXT=""
    # Calling through `if` suspends errexit for the whole probe body, so a
    # probe's own failing command reports itself instead of killing the run.
    if ! dispatch_probe "$id"; then
      note "  $id: probe body exited non-zero"
    fi
    if [ -z "$PROBE_VERDICT" ]; then
      PROBE_VERDICT=INCONCLUSIVE
      PROBE_TEXT="the probe reached its end without recording a verdict; treat this as unanswered"
    fi

    printf '**Verdict:** %s — %s\n' "$PROBE_VERDICT" "$PROBE_TEXT"

    summary_ids+=("$id")
    summary_verdicts+=("$PROBE_VERDICT")
    case "$PROBE_VERDICT" in
      ANSWERED)
        answered=$((answered + 1))
        summary_decides+=("${PROBE_TEXT%%: *}")
        ;;
      BLOCKER)
        blockers=$((blockers + 1))
        summary_decides+=("${PROBE_TEXT%%: *}")
        ;;
      *)
        inconclusive=$((inconclusive + 1))
        summary_decides+=("$(probe_tag "$id") — unanswered")
        ;;
    esac
  done

  printf '\n## Summary\n\n'
  printf '| Probe | Verdict | Decides |\n'
  printf '| --- | --- | --- |\n'
  local i
  for i in "${!summary_ids[@]}"; do
    printf '| %s | %s | %s |\n' "${summary_ids[$i]}" "${summary_verdicts[$i]}" "${summary_decides[$i]}"
  done

  local total="${#summary_ids[@]}"
  local probe_word="probes" blocker_word="blockers"
  if [ "$total" -eq 1 ]; then
    probe_word="probe"
  fi
  if [ "$blockers" -eq 1 ]; then
    blocker_word="blocker"
  fi
  printf '\n%s %s: %s answered, %s %s, %s inconclusive.\n' \
    "$total" "$probe_word" "$answered" "$blockers" "$blocker_word" "$inconclusive"

  if [ "$blockers" -gt 0 ]; then
    return 1
  fi
  if [ "$inconclusive" -gt 0 ]; then
    return 2
  fi
  return 0
}

GATE_TMP=""
gate_status=0
main "$@" || gate_status=$?
exit "$gate_status"
