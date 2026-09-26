# Container Engines: Docker and Podman

**Status:** Current | **Last Updated:** September 2026

This stack runs on **Docker Engine** or on **Podman**. It speaks Docker's
dialect on both: every call site in the repository is spelled `docker`, and a
Podman host satisfies them with the real Docker CLI and the real Compose v2
plugin pointed at Podman's Docker-compatible API socket.

This document is the reference for that decision — what it costs, what it
does not buy, what an operator has to have on the host, and which behaviours
genuinely differ between the two engines. It also records the topology
question that gets re-asked every few months (should everything share one
Podman pod?) and why the answer is no.

Audience: engineers changing anything that talks to the container engine, and
operators deciding which engine to deploy on. For the whole-system picture see
[`SYSTEM-OVERVIEW.md`](SYSTEM-OVERVIEW.md); for day-to-day operation see
[`docs/operator-guide.md`](../operator-guide.md).

---

## 1. The decision: socket-compatibility mode

Podman ships a Docker-compatible REST API. Running the stack on Podman means
pointing the ordinary Docker tooling at that API instead of at `dockerd`:

```
docker CLI  ──┐
              ├──► unix:///var/run/docker.sock ──► podman.service (compat API)
compose v2 ───┘
```

Nothing in the repository is spelled `podman`. There is no `$ENGINE` variable
in front of ~660 call sites, and no second invocation path.

### Why not the two obvious alternatives

**Rewrite every call site to the native `podman` CLI.** Rejected. Around 60
sites parse Docker-shaped JSON out of `docker inspect --format` —
`{{.State.Health}}`, `{{.HostConfig.NetworkMode}}`, `{{.HostConfig.Memory}}`,
`{{index .Config.Labels "…"}}`, `{{.RestartCount}}`. Native `podman inspect`
renders a different shape in several of those places. This turns a socket
change into an audit of every Go template in the repository, and puts the
largest possible regression surface on the engine that already works.

**Install the `podman-docker` shim and change nothing.** Rejected as
insufficient. The shim does not provide `docker compose`, and 39 invocations
across 14 source files need it. It also prints an advisory to stderr on every
call unless `/etc/containers/nodocker` exists, which would contaminate the many
call sites that capture stderr.

### Why socket-compatibility works here specifically

- **The Go templates keep working.** Podman's compat API renders Docker-shaped
  JSON. The documented exceptions are in [§4](#4-where-the-engines-actually-differ).
- **The Compose labels stay right.** `runtime/scripts/compose-project.sh`
  discovers the stack by filtering on `com.docker.compose.project`,
  `.service`, `.container-number` and `.oneoff=False`. Compose v2 applies those
  labels *client-side*, so they are identical whatever engine is behind the
  socket. This is also why `podman-compose` is not an option: it is a different
  implementation that writes `io.podman.compose.*`, and every filter in that
  file would match nothing — silently.
- **The diff is proportional to the real incompatibilities**, not to the number
  of times the token `docker` appears.

### What it does not buy you

Socket compatibility makes the *dialect* uniform. It does not make the *host*
uniform, and the hardest parts of Podman support are host-side rather than in
the call sites: the socket's ownership and the group that can reach it, whether
name resolution exists on the container bridge at all, and whether the systemd
units the scripts generate order themselves against a unit that exists. Those
land in `install.sh` and in the generated units, not in the `docker` commands.

### BuildKit is off on Podman

Compose v2 against the compat socket falls back to the classic builder:
BuildKit needs `/build/cancel` and the session API, which Podman's compat layer
does not implement. Every image in this stack is built locally — upstream
publishes none — so the classic path has to keep working. No Dockerfile here
uses BuildKit-only syntax (no `# syntax=` directive, no heredocs, no
`--mount=type=cache`), so the Podman path forces `DOCKER_BUILDKIT=0` rather
than letting Compose try BuildKit first and fail with an error that reads like
a broken Dockerfile.

---

## 2. The engine seam

`runtime/scripts/lib/engine.sh` is the single description of how the two
engines differ. **Nothing else in the repository branches on the engine by
hand.** If you need a new engine-dependent answer, add it there.

It is POSIX shell — `install.sh` runs under `/bin/sh`, and CI checks it with
both `dash -n` and BusyBox `ash -n` — so it contains no arrays, no `local` and
no other bashisms. It is sourced, never executed. Sourcing runs detection once
and exports the result, so every `DUNE_ENGINE_*` variable is safe to read under
`set -u` without the caller initialising anything, and re-sourcing is free.

`runtime/scripts/runtime-env.sh` sources it, which gives the seam to the 37
scripts that already source `runtime-env.sh`. It also owns the two Bash arrays
the seam cannot express in POSIX shell.

### Detection

In order: an explicit `DUNE_CONTAINER_ENGINE=docker|podman` override; a host
with no Docker CLI at all; the engine's own self-report
(`docker version --format '{{json .Server}}'`, which names "Podman Engine" as a
component); then, for an engine that answers nothing — the state `install.sh`
and `dune doctor` often run in — whether `podman` is installed without
`dockerd`. The fallback is Docker: **an engine that cannot be identified must
behave exactly as it does today.**

### The contract

| Variable | Docker | Podman | Why it differs |
| --- | --- | --- | --- |
| `DUNE_ENGINE_KIND` | `docker` | `podman` | |
| `DUNE_ENGINE_SOCKET` | `/var/run/docker.sock` | `/var/run/docker.sock` via the drop-in, else `/run/podman/podman.sock` | |
| `DUNE_ENGINE_RESTART_POLICY` | `unless-stopped` | `always` | `podman-restart.service` only revives `always` containers |
| `DUNE_ENGINE_SYSTEMD_UNIT` | `docker.service` | `podman.socket` | there is no `docker.service` on a Podman host |
| `DUNE_ENGINE_MOUNT_SUFFIX` | *(empty)* | `z` | SELinux relabelling, shared rather than private |
| `DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE` | `1` | `0` | Podman's `json-file` driver rejects `max-file` |
| `DUNE_ENGINE_IMAGE_PREFIX` | *(empty)* | `localhost/` | locally built images normalise with the prefix |
| `DUNE_ENGINE_SUPPORTS_BUILDER_PRUNE` | `1` | `0` | no `builder prune`, and no compat endpoint for it |

Helpers: `dune_engine_mount SRC DEST [OPTS]` builds a whole `-v` value with the
relabel appended last; `dune_engine_label_disable_args` yields
`--security-opt label=disable`; `dune_engine_normalize_image_ref` and
`dune_engine_normalize_digest` strip the `localhost/` and `sha256:` prefixes;
`dune_engine_systemd_unit_ordering` and `dune_engine_systemd_service_environment`
emit the `[Unit]` and `[Service]` lines for generated units; `dune_in_container`
reports whether this process is containerised on either engine.

The seam's own contract is tested on both legs by
`runtime/tests/test-engine-seam.sh`, using the shared fake in
`tests/lib/fake-engine.sh`.

---

## 3. Security: socket access is root-equivalent

Say this plainly, because the Podman deployment makes it easy to believe
otherwise: **a process that can reach the engine's API socket can become root
on the host.** It can start a container that bind-mounts `/` and runs
privileged. This is true of the `docker` group on a Docker host, and it is
equally true of whatever group is granted access to `podman.socket`. Rootless
Podman does not change it either — a rootless socket confers the full
privileges of the user that owns it.

Grant socket access the way you would grant `sudo` with `NOPASSWD: ALL`,
because the two are equivalent.

---

## 4. Where the engines actually differ

The contract table in section 2 lists what the seam *exports*. This section is
the catalogue of behaviours behind it, including the handful that no variable
can express and that are therefore fixed at the call site.

Almost none of these announce themselves. The container starts either way and
misbehaves later — after a reboot, on an SELinux host, or the first time the
Console asks it a question. That is why they are written down here rather than
left to be rediscovered.

### Lifecycle

**Restart policy.** Docker's daemon restores `unless-stopped` and `always`
containers itself. Podman has no long-running daemon, so `podman-restart.service`
does it at boot — and it revives **only** `always`. An `unless-stopped`
container on a Podman host stays down after a reboot with nothing logged. Every
`--restart` in the repo reads `DUNE_ENGINE_RESTART_POLICY`; the seven
declarative `restart:` keys in the Compose files read
`${DUNE_ENGINE_RESTART_POLICY:-unless-stopped}`, which `install.sh` persists
into `.env` because that is where Compose interpolates from.

**`docker volume create` is not idempotent.** Podman exits 125 on a volume that
already exists, where Docker exits 0. `start-postgres.sh` no longer treats a
non-zero exit as fatal.

**Name filters do not match.** `--filter 'name=^/dune-postgres$'` relies on
Docker's leading slash in container names, which Podman does not produce. The
filter never matches, so a "does it exist" check answers *no* for a container
that is running. `stop-postgres-container.sh` lists names and matches exactly
instead.

**Compose labels are the only stable identity.** Container naming is
engine-dependent; the `com.docker.compose.*` labels are applied client-side by
Compose itself and are identical on both engines. Resolve a service through its
labels, never through a name pattern. This is also why `podman-compose` is
unusable here: it writes `io.podman.compose.*`, so every filter in
`compose-project.sh` would match nothing, silently.

### Storage and SELinux

**Bind mounts need relabelling.** On an SELinux host an unlabelled bind mount is
simply unreadable inside the container. Podman relabels on request; Docker
mostly does not need to be asked. The suffix is **`z`, shared — never `Z`**:
`:Z` assigns a private MCS category pair, and the orchestrator, the spawners and
the game servers all share these paths, so the first container given a private
label locks the others out. Every path-valued `-v` goes through
`dune_engine_mount`.

**The engine socket is never relabelled.** It belongs to the host, not to this
stack; relabelling it would rewrite the context every other client reaches it
through. Containers that mount it get `--security-opt label=disable` instead,
via `dune_engine_label_disable_args`.

**The compat API can report an empty volume mountpoint** for a volume that is
not currently mounted. `init.sh`'s Postgres reset now *exits* on that rather
than warning and proceeding — the tar it takes first is the only copy of the
database that survives the removal after it.

### Logging

Podman's `json-file` driver accepts `max-size` but rejects `max-file`. The
imperative half reads `DUNE_ENGINE_SUPPORTS_LOG_MAX_FILE` and simply omits the
flag. The declarative half is an open gap; see section 6.

### Images and builds

**BuildKit is unavailable through the compat socket**, so the seam sets
`DOCKER_BUILDKIT=0` on Podman. A detached container inherits nothing, so where
one is spawned to run a build the variable travels in the argv.

**Locally built images carry a `localhost/` prefix.** Anything that inspects an
image by the name it was built under needs `DUNE_ENGINE_IMAGE_PREFIX`, and
anything comparing a returned reference needs `dune_engine_normalize_image_ref`.

**Base images must be fully qualified.** Podman resolves a short name against
`unqualified-search-registries`, which is host configuration a build cannot see:
depending on the host it may fail outright, prompt (impossible in a script), or
resolve to a *different* image from a higher-priority registry. Every `FROM` in
the repo names `docker.io/library/…` explicitly.

**`docker builder prune` does not exist**, and `podman system df` has no
`Build Cache` row. `dune doctor` reports the figure only where there is one to
report, rather than printing a vacuous zero.

### Networking

**Bridge name resolution is opt-in.** Docker's default bridge resolves service
names; Podman needs `netavark` with `aardvark-dns`, and the `--dns-enabled` flag
that turns it on has no equivalent in the Docker compat API. Seven services —
Postgres, RabbitMQ, the orchestrator, the director, the text router, the server
gateway and the autoscaler — address each other by name over this bridge, so
`dune_engine_create_network` creates it with the native `podman` CLI first and
only then falls through to the compat call. `dune doctor` asserts that
resolution actually works rather than assuming the flag took.

### Containers and cgroups

**`init: true` needs `catatonit`**, which is a separate package on most distros.

**The default cgroup namespace may be `host`.** The Console's memory balancer
reads `memory.swap.current` from inside a game container, and a host namespace
puts that file at a different path. Two complementary fixes: new containers get
`--cgroupns=private` from `dune_engine_cgroupns_args`, and the in-container
sampler resolves its own cgroup from `/proc/self/cgroup` — which also fixes
Docker hosts deliberately run with `cgroupns=host`.

**`/run/.containerenv`, not `/.dockerenv`.** `dune_in_container` checks both.

**`docker inspect` shapes differ.** Podman's compat inspect returns `.Args`
where Docker returns `.Config.Cmd`, and a **non-nil empty** `.State.Health` for
a container with no healthcheck where Docker returns nil. A template needs both
guards nested — `{{if .State.Health}}{{if .State.Health.Status}}` — or it
nil-dereferences on Docker, or prints a bare `health=` on Podman.

**`docker stats` has no usable CPU figure.** Podman's compat endpoint reports a
delta over a zeroed `precpu` baseline, so the CLI's `CPUPerc` is meaningless
rather than merely imprecise, and the formatted output exposes no raw counters
to difference by hand. The Console reports `N/A` instead of a number; addons
would otherwise read the host as idle. Memory, NetIO and BlockIO are
instantaneous and stay.

### systemd

There is **no `docker.service`** on a Podman host, and systemd treats `After=`
on a unit that does not exist as a **silent no-op** — a generated unit loses its
ordering guarantee with nothing logged anywhere. Generated units also run with a
clean environment, so whatever the shell exported to reach the engine has to be
written into the unit file. Both come from
`dune_engine_systemd_unit_ordering` and
`dune_engine_systemd_service_environment`, and both are empty on Docker so the
units there stay byte for byte what they were.

### Privilege drop

The orchestrator's entrypoint uses `setpriv`, not `runuser`. `runuser -g/-G`
requires a resolvable `/etc/group` entry and fails on the inherited numeric GID
that Podman's socket hands it — which is precisely the case the privilege drop
exists to handle.

---

## 5. Host prerequisites

`install.sh` establishes all of this. The list is here for operators who
provision hosts themselves, and for reading a host that is behaving oddly.

**Packages:** `podman`, `netavark`, `aardvark-dns`, `catatonit`. All four are
named explicitly rather than left to weak dependencies. `podman-plugins` is
deliberately *not* installed: it carries the CNI `dnsname` plugin, Podman 5
dropped CNI altogether, and naming a package that no longer exists fails the
whole transaction.

**Not `podman-docker`.** That package installs a `/usr/bin/docker` shim that
execs `podman`. It satisfies `command -v docker`, so it can shadow the real CLI
and route `docker compose` to `podman compose`, which ignores the Compose plugin
directory entirely. The installer detects the shim by what the client prints and
refuses to finish behind it.

**The Docker CLI and the Compose v2 plugin**, as static builds — CLI 27.5.1 and
Compose 2.29.7, the same versions `console/api/Dockerfile` pins, kept in step by
a cross-file test. Host and console drive one socket; a skew shows up as a
Compose file that parses in one place and not the other. No distro packages
either without Docker Engine, which a Podman host must not have.

Because they land in `/usr/local/bin`, which `sudo`'s `secure_path` excludes,
the installer resolves an absolute `DOCKER_BIN` rather than relying on a bare
command name surviving `env`/`sudo`.

**The socket drop-in**, at
`/etc/systemd/system/podman.socket.d/10-dune-docker-compat.conf`:

```ini
[Socket]
ListenStream=
ListenStream=/var/run/docker.sock
SocketGroup=podman
SocketMode=0660
```

The empty `ListenStream=` is load-bearing: it **clears** the list inherited from
the shipped unit rather than adding to it. `podman system service` accepts
exactly one activation file descriptor and refuses to start with *"wrong number
of file descriptors for socket activation protocol (2 != 1)"* if the socket
hands it two. Replacing the path also means nothing has to traverse
`/run/podman`, which systemd keeps at `0700 root:root`.

Publishing the API *at* `/var/run/docker.sock` is what lets the console, the
orchestrator and every container the orchestrator spawns work unchanged, and it
is why no script in the repo learns a second socket path.

**`systemctl enable podman-restart.service`**, which is what revives `always`
containers at boot.

**A `podman` group**, created `--system`, holding whoever needs engine access.
It is the exact analogue of the `docker` group, including the part where
membership is root-equivalent (section 3). `DOCKER_SOCKET_GID` is read from the
live socket; before the drop-in takes, that socket is `root:root` and the read
returns `0`. The installer stops there; `console.sh` and the `dune` CLI warn and
decline to persist the `0`, because a persisted value is not probed again and
would outlive the fix.

---

## 6. Known gaps on Podman

Honest list. None of these is silent — each either has a `dune doctor` check, a
visible `N/A`, or is inert on a correctly provisioned host.

**Declarative log rotation is not parameterised.** `runtime-env.sh` omits
`--log-opt max-file` on Podman for containers started imperatively, but Compose
interpolates *values*, never *keys*, so `logging.options.max-file` cannot be
made conditional in the Compose files. Solving it needs a
`docker-compose.podman.yml` overlay plus a `-f` at roughly fifteen call sites.
The consequence today is that Compose-managed containers on Podman rotate by
size only, not by file count.

**cAdvisor's `--docker_only` and the metrics label set are unverified.** The
metrics stack's netns and storage directories are parameterised, but whether
cAdvisor emits the same label set against Podman's layout — and therefore
whether `runtime/metrics/rules/containers.yml` matches — cannot be established
without a Podman host. Expect to adjust the recording rules.

**Rootless Podman is not supported.** The stack publishes privileged ports and
bind-mounts host paths across containers. Nothing here is written against
rootless assumptions, and section 3 applies to a rootless socket too: it confers
the full privileges of its owner.

**CI has no Podman runner.** Every Podman behaviour in this document is covered
by tests that run both engine legs against the real scripts with a recording
stub standing in for the engine
(`tests/lib/fake-engine.sh`). That catches a call site that grew its own answer.
It cannot catch an assumption about Podman that is simply wrong — the class of
bug the two items above belong to. First deployment on a real Podman host is
still the first real test.

**Container CPU is reported as `N/A`.** Not a defect to be fixed later; see
section 4. The figure the compat API offers is wrong rather than approximate,
and withholding it is the only honest option available without taking on a
Docker SDK dependency the repo deliberately lacks.

---

## 7. Considered and rejected: one Podman pod for the whole stack

Podman pods give a set of containers one shared network namespace and one
lifecycle. The recurring proposal is to put every container in this stack —
support services, game servers, metrics — into a single `dune-awakening` pod.

**The answer is no,** and the reason worth internalising is that *two of the
three blockers have nothing to do with Podman.* They are properties of this
stack's own topology that any shared network namespace violates. Extending the
pod would not be a port; it would be a redesign of the stack's networking, on
one engine only.

### Blocker 1 — RabbitMQ collides with itself

`start-rabbitmq.sh` runs two containers from the same image. `dune-rmq-admin`
and `dune-rmq-game` listen on *identical* internal ports (5672, 15672, 15692)
and are told apart solely by how the host publishes them. One namespace means
three bind collisions and a second broker that never starts. Fixing it means
either changing the brokers' internal listeners — which means editing generated
`rabbitmq.conf` and every client's expectations — or keeping them in separate
namespaces. This is engine-independent and fatal on its own.

### Blocker 2 — bridge DNS is load-bearing

Twenty container-name references across the stack resolve through the
`dune-net` bridge's DNS: both brokers' entire auth backend, three independent
`dune-postgres` paths, every Prometheus scrape target. A pod with
`--network host` — which is what the game servers require — has no bridge and
therefore no `aardvark-dns`, so none of those names resolve. A *bridged* pod
keeps DNS for its members, but then the game servers cannot join it (they need
the host namespace for the UDP game ports) and you are back to two tiers, which
is what already exists.

### Blocker 3 — the Docker compat API has no pod concept

`--pod` is libpod-only. `HostConfig.NetworkMode` in the Docker API accepts
`bridge`, `host`, `none`, `container:<id>` and a network name — not
`pod:<name>`. Under socket-compatibility mode every spawn goes through the
compat socket, so a pod topology cannot be expressed there at all. The ~65
`docker run` sites would have to fork to native `podman run --pod`,
reintroducing exactly the dual-invocation-path problem this architecture exists
to avoid.

**This is also the direct answer to "does it break Docker?"** It does not break
Docker; it *excludes* it. Pods cannot be expressed on Docker in any form, so
every port number and every peer hostname would become engine-conditional — one
topology for Podman, another for Docker, in the same scripts.

### Secondary problems, each fatal on its own for a bridged pod

- **Dynamic port allocation.** `spawn-server.sh` picks `GAME_PORT`/`IGW_PORT`
  at spawn time, guarded by a free-port probe. A pod's published ports are
  fixed when the pod is created, before any server exists — every future
  server's ports would have to be predicted and pre-published.
- **Free-port probing would target the wrong namespace.** `port_is_free` and
  `ready.sh`'s `check_tcp` probe from the host namespace. Inside a bridged pod
  they would test a namespace nothing binds in, and hand out ports already in
  use.
- **A host-network pod is a security regression.** Postgres, the Director, the
  TextRouter and the admin broker deliberately publish to loopback only today.
  In a host-namespace pod there is no publish step: each process binds per its
  own config, which is `0.0.0.0` for Postgres and RabbitMQ.
- **Privileged helpers could not override pod networking.** The host-systemd
  helpers run `--pid=host --network=host`; a pod member inherits the pod's
  namespaces and cannot opt out per container.
- **It would break the existing hub-and-spoke coupling.**
  `runtime-env.sh`'s `resolve_rmq_game_host()` / `resolve_rmq_admin_host()`
  have host-namespace game servers reach the bridged brokers over published
  loopback ports. A shared namespace removes the publish step the resolver
  depends on, and the resolver's fallback is silent by construction.

### `--network container:<name>` does not rescue it

If a shared namespace is ever genuinely wanted, the runtime-neutral spelling is
`--network container:<name>`, which both engines accept identically and which
needs no pod at all. It is worth knowing about — but it does not rescue this
idea, because blockers 1 and 2 are properties of the topology, not of how the
namespace is requested. Two RabbitMQs still collide; bridge names still stop
resolving.

### The topology to keep, on both engines

| Tier | Members | Networking |
| --- | --- | --- |
| Control plane | orchestrator, console | Host namespace. A pod here is harmless — both are `network_mode: host` anyway, there are exactly two, and their ports do not overlap. It buys a shared lifecycle, not shared networking |
| Support services | postgres, director, gateway, text-router, both brokers | `dune-net` bridge, loopback-published |
| Metrics | prometheus, node-exporter, cadvisor, postgres-exporter | `dune-net` bridge (declared `external: true`) |
| Workload | game servers, autoscaler, coordinator, privileged helpers | Plain host namespace, no pod |

**What the pod idea is pointing at is real, and it is not networking.** The
thing genuinely missing is a shared *lifecycle* — one unit to start, stop and
order the whole stack. Pursue that through systemd ordering instead: it
delivers the actual benefit without touching networking, and it works
identically on both engines.

---

## Related documents

- [`SYSTEM-OVERVIEW.md`](SYSTEM-OVERVIEW.md) — the whole-system component map
  this document's engine decisions sit underneath.
- [`../runtime/CONTAINER-HARDENING.md`](../runtime/CONTAINER-HARDENING.md) —
  the hardening applied to these containers on both engines.
- [`../operator-guide.md`](../operator-guide.md) — operator-facing walkthrough.
