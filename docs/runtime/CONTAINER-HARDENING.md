## Container Hardening — Change Summary

**Status:** Current | **Last Updated:** September 2026

### Overview

This PR hardens the console and orchestrator containers to run with reduced
privileges where the host installation permits it. The console maps its runtime
UID/GID to the repository owner; this is non-root for normal user-owned installs,
while intentionally root-owned installs remain UID 0 for compatibility. The
orchestrator runs as root briefly for volume permission repair and Docker socket
access, then drops to the `dune` user.

### Files Changed (10 files, +415/-12 lines)

| File | Change | Purpose |
|------|--------|---------|
| `console/api/Dockerfile` | +8 | Create `dune` user, set `USER dune`, 755 perms on `/app` |
| `console/api/entrypoint.sh` | +17 (new) | Verify `/repo` writability, fail fast with clear error |
| `docker-compose.web.yml` | +2 | Pass `DUNE_HOST_UID`/`DUNE_HOST_GID` to container env |
| `docker-compose.yml` | +4/-1 | Add `group_add` for Docker socket, run orchestrator as `dune` |
| `orchestrator/Dockerfile` | +12/-2 | Create `dune` user, add entrypoint, fix COPY paths |
| `orchestrator/dune_orchestrator.py` | +27/-5 | Conditionally chown volumes (skip if already running as dune) |
| `orchestrator/entrypoint.sh` | +50 (new) | Repair root-owned volumes, handle Docker socket group, drop to dune |
| `runtime/scripts/init.sh` | +10 | Auto-detect `DUNE_HOST_UID`/`DUNE_HOST_GID` from host |
| `tests/container-lifecycle-test.sh` | +143 (new) | 10 container lifecycle tests |

---

### Design Decisions & Rationale

#### 1. Console uses the host repository owner's UID/GID

**What**: The Dockerfile creates a `dune` user and sets `USER dune` as the image
default. Compose overrides the runtime UID/GID with the detected owner of the
host repository. The entrypoint only checks `/repo` writability; it performs no
`chown`, `useradd`, or `groupadd` operations.

For normal user-owned installs this runs the console as a non-root numeric UID.
If the installation is intentionally owned and operated by root, the detected
UID/GID is `0:0` and Compose keeps the console running as root so existing
installations continue to work. Because the console mounts the Docker socket,
administrators must treat it as a trusted, root-equivalent management service
regardless of its process UID. This holds on Podman as well: the console mounts
Podman's Docker-compatible API socket at the same path, and membership in the
`podman` group is root-equivalent exactly as the `docker` group is. See
[`docs/architecture/CONTAINER-ENGINES.md`](../architecture/CONTAINER-ENGINES.md).

**Why**: Docker's own best practices state: *"Avoid running applications as
root. Even if the container is designed to be run as root, consider adding
a non-root user."* When a container breakout occurs (CVE-2024-21626, runc),
the attacker inherits the container's privileges. Running as non-root limits
damage to the container's filesystem only.

**Sources**:
- [Dockerfile best practices — USER](https://docs.docker.com/develop/develop-images/dockerfile_best-practices/#user)
- [CIS Docker Benchmark 4.1](https://www.cisecurity.org/benchmark/docker): "Ensure that a user for the container has been created"
- [NIST SP 800-190](https://csrc.nist.gov/publications/detail/sp/800-190/final): Container runtime privilege reduction
- [OWASP Docker Security Cheat Sheet — Rule #7](https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html#rule-7-run-as-a-non-root-user)

#### 2. Dynamic UID/GID — no hardcoded 1000

**What**: Removed `useradd -u 1000`. The `dune` user gets a system-assigned UID.
Compose `user:` field maps the host UID to the container at runtime.
`init.sh` auto-detects host UID/GID via `$(id -u)` and `$(id -g)`.

**Why**: Hardcoding UID 1000 assumes every host has a user at that ID.
Real deployments use arbitrary UIDs (LDAP, enterprise, shared servers).
Docker maps by numeric UID, not by name — the container doesn't need
a host user called `dune`.

**Sources**:
- [Docker run reference — user](https://docs.docker.com/reference/cli/docker/container/run/#user): "The user can be specified by UID or username"
- [Linux namespaces man page](https://man7.org/linux/man-pages/man7/user_namespaces.7.html): UID mapping is numeric, not name-based

#### 3. Upgrade path and repository writability

**What**: The entrypoint checks `/repo` writability via a `touch` test. If the
configured runtime UID/GID cannot write to the host directory, the container
exits with a clear error message telling the administrator how to correct the
ownership or UID/GID configuration.

The console container does not automatically `chown` the repository. The
installer can migrate repository ownership on the host when moving an existing
installation to a non-root owner. Intentionally root-owned installations retain
UID/GID `0:0` and are not rejected solely because they are owned by root.

**Sources**:
- [CIS Docker Benchmark 5.1](https://www.cisecurity.org/benchmark/docker): "Ensure that, if applicable, an AppArmor or SELinux profile is enabled"
- Principle of least privilege: the container should not have permission to
  modify host filesystem ownership

#### 4. Orchestrator runs as root briefly — legitimate need

**What**: Orchestrator entrypoint runs as root, repairs volume ownership,
configures engine socket group access, then drops to `dune` via `setpriv`.

**Why**: The orchestrator manages containers (needs socket access)
and game server volumes (needs write access). These operations require root.
The orchestrator entrypoint uses the privilege drop chain: `setpriv` →
`runuser` → `gosu` → `su` — each preserving argument boundaries.

**Sources**:
- [Docker socket security](https://docs.docker.com/engine/security/#docker-daemon-attack-surface): "Giving someone access to the Docker socket is equivalent to giving them root"
- [setpriv man page](https://man7.org/linux/man-pages/man1/setpriv.1.html): Argument-preserving privilege drop tool

#### 5. Argument-preserving privilege drop

**What**: Replaced `su - dune -c "exec $*"` with `runuser -u dune -- "$@"`.
The old form loses argument boundaries (spaces, quotes). The new form
preserves them via proper shell argument forwarding.

**Sources**:
- [Shell parameter expansion](https://www.gnu.org/software/bash/manual/html_node/Special-Parameters.html): `$*` vs `$@` — `$@` preserves argument boundaries
- [runuser man page](https://man7.org/linux/man-pages/man1/runuser.1.html): Designed to replace `su` for service management

#### 6. The privilege drop carries the socket's group explicitly

**What**: The entrypoint computes the supplementary group set itself — dune's
own memberships, plus every non-zero group inherited from the container's
process, plus `DOCKER_SOCKET_GID` — and hands it to `setpriv --groups`. Group 0
is carried only when the socket's GID actually is 0.

**Why**: `group_add` in `docker-compose.yml` delivers the socket's group to the
entrypoint *process*, not to `/etc/group`. `runuser`, `su` and `gosu` all call
`initgroups()`, which replaces the process group set with dune's `/etc/group`
memberships and silently discards the inherited one. On Docker that is masked:
the socket's GID is non-zero, so the entrypoint recreates it as a real group
and dune genuinely belongs to it. Rootful Podman's socket is `root:root 0660`,
no named group can be created for GID 0, and the orchestrator would drop to a
user that cannot open the one socket its entire job is to drive — every engine
call failing with `EACCES` and nothing saying why.

`setpriv` leads the chain because it is the only one of the four that accepts
raw numeric GIDs: `runuser -G` rejects a GID with no `/etc/group` entry, which
is exactly what an inherited `group_add` value is. The three fallbacks cannot
carry an inherited group and remain only for an image without util-linux.
`setpriv` also leaves the environment untouched, so `HOME`, `USER` and
`LOGNAME` are set explicitly to the values `runuser` would have written —
dune's SteamCMD tree lives under its `HOME`.

Covered by `tests/orchestrator-privilege-drop-test.sh`, which runs the shipped
entrypoint's drop against both a non-zero and a zero socket GID.

**Sources**:
- [setpriv man page](https://man7.org/linux/man-pages/man1/setpriv.1.html): `--groups` takes numeric GIDs
- [initgroups(3)](https://man7.org/linux/man-pages/man3/initgroups.3.html): replaces the supplementary group list from `/etc/group`

---

### Test Results (10 scenarios, 11 pass)

```
$ bash tests/container-lifecycle-test.sh
=============================================
  Container Lifecycle Tests
=============================================

1. Dockerfile builds successfully
  ✓ Dockerfile builds

2. Container runs as non-root user
  ✓ container runs as UID 1001 (non-root)

3. Container user is 'dune'
  ✓ user is dune

4. Root-owned /repo blocks writes (upgrade simulation)
  ✓ entrypoint detects root-owned /repo and fails

5. Host-owned /repo allows writes
  ✓ entrypoint allows writable /repo

6. Custom UID via --user flag
  ✓ runs as UID 5678 with --user

7. Entrypoint preserves command arguments
  ✓ entrypoint runs CMD correctly

8. Compose config validates
  ✓ compose config valid

9. Entrypoint shell syntax
  ✓ syntax OK: entrypoint.sh
  ✓ syntax OK: entrypoint.sh

10. Orchestrator Dockerfile builds
  ✓ orchestrator Dockerfile builds

=============================================
  RESULTS: 11 pass, 0 fail
=============================================
```

---

### CI Status

All 4 upstream CI checks pass on every push:
- `api-tests` — full test suite
- `metrics-unit` — metrics stack tests
- `security-checks` — gitleaks, trivy, shellcheck, whitespace
- `api-dependency-audit` — npm audit
