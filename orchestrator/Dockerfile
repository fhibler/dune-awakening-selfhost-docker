FROM docker.io/library/ubuntu:24.04
LABEL io.github.red-blink.dune-selfhost.component="orchestrator"

ENV DEBIAN_FRONTEND=noninteractive

RUN dpkg --add-architecture i386 \
 && apt-get update -y \
 && apt-get install -y \
    ca-certificates \
    curl \
    tar \
    gzip \
    unzip \
    jq \
    git \
    python3 \
    python3-yaml \
    procps \
    util-linux \
    lib32gcc-s1 \
    lib32stdc++6 \
 && rm -rf /var/lib/apt/lists/*

# The orchestrator drives the engine over the mounted socket, so it needs the
# client, not an engine. Ubuntu's docker.io package delivers that one binary
# by installing dockerd, containerd and runc alongside it, and creates a
# `docker` group whose GID matches nothing on the host -- and on a Podman host
# there is no such group to match. The static client from download.docker.com
# is the same one console/api/Dockerfile ships and speaks to either engine's
# Docker-compatible socket. No Compose plugin: dune_orchestrator.py only runs
# `docker version` and `docker ps`, and prints `docker compose` as advice for
# the operator's own shell.
RUN arch="$(dpkg --print-architecture)" \
 && case "$arch" in \
     amd64) docker_arch="x86_64" ;; \
     arm64) docker_arch="aarch64" ;; \
     *) echo "Unsupported architecture for Docker CLI: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${docker_arch}/docker-27.5.1.tgz" -o /tmp/docker.tgz \
 && tar -xzf /tmp/docker.tgz -C /tmp \
 && mv /tmp/docker/docker /usr/local/bin/docker \
 && chmod +x /usr/local/bin/docker \
 && rm -rf /tmp/docker /tmp/docker.tgz \
 && docker --version

RUN useradd -m -s /bin/bash dune \
 && mkdir -p \
    /home/dune/.steam \
    /srv/dune/server \
    /srv/dune/steam \
    /srv/dune/generated \
    /srv/dune/cache \
    /work \
 && chown -R dune:dune /home/dune /srv/dune /work

COPY dune_orchestrator.py /usr/local/bin/dune
RUN chmod +x /usr/local/bin/dune

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["dune", "daemon"]
