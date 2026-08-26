# syntax=docker/dockerfile:1
FROM ubuntu:26.04

# ============================================================
# Build-time proxy (corporate network).
# Leave blank if you are NOT behind a proxy.
# Only used while building; not baked into the final runtime env.
# ============================================================
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY="localhost,127.0.0.1,::1,host.docker.internal,kind-control-plane,.svc,.cluster.local,172.18.0.0/16,10.96.0.0/12"

ENV http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} HTTPS_PROXY=${HTTPS_PROXY} \
    no_proxy=${NO_PROXY} NO_PROXY=${NO_PROXY} \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /root/source

# ---- System packages: dev libraries, build tools, network tools ----
#   build-essential / make / pkg-config : compiling native deps
#   default-jdk + maven                 : Java + mvn (ForgeOps / Ping)
#   python3 (+pip/venv/dev)             : scripts & tooling
#   jose                                : JOSE/JWT CLI used by ping scripts
#   iproute2/iputils-ping/dnsutils/...  : docker network + DNS debugging
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl wget ca-certificates gnupg lsb-release git vim jq unzip zip tar \
      bash-completion openssh-client \
      build-essential pkg-config make \
      default-jdk maven \
      python3 python3-pip python3-venv python3-dev \
      jose \
      iproute2 iputils-ping dnsutils net-tools netcat-openbsd telnet traceroute \
    && rm -rf /var/lib/apt/lists/*

# ---- Node.js 22 LTS (+ npm, yarn) ----
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

# ---- Go ----
ARG GO_VERSION=1.23.4
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm -f /tmp/go.tgz
ENV PATH="/usr/local/go/bin:/root/go/bin:${PATH}" GOPATH="/root/go"

# ---- Docker CLI (static) + compose plugin ----
# ONLY the client. The container talks to the HOST daemon via the mounted
# socket. This is what lets 'kind' create cluster containers as siblings.
ARG DOCKER_CLI_VERSION=27.3.1
RUN curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/d.tgz \
    && tar -xzf /tmp/d.tgz -C /tmp \
    && mv /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker /tmp/d.tgz
ARG COMPOSE_VERSION=v2.29.7
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
       -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ---- kubectl (latest stable) ----
RUN curl -fsSLO "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl \
    && rm -f kubectl

# ---- helm (correct upstream script) ----
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 -o /tmp/get-helm-3 \
    && chmod 700 /tmp/get-helm-3 \
    && /tmp/get-helm-3 \
    && rm -f /tmp/get-helm-3

# ---- kind ----
# 'latest' resolves correctly here. Do NOT type 'lastest' (that 404s and
# saves an XML error page as the binary → "syntax error near '<'").
RUN curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64 \
    && chmod +x /usr/local/bin/kind

# ---- kubectx / kubens ----
RUN git clone --depth 1 https://github.com/ahmetb/kubectx /opt/kubectx \
    && ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx \
    && ln -s /opt/kubectx/kubens  /usr/local/bin/kubens

# ---- Ping CLI (pingcli; older name 'pingctl') ----
# Installed via Go. Non-fatal: if the module path differs for your version,
# the build still succeeds and you can install it manually later.
RUN (go install github.com/pingidentity/pingcli@latest \
      && ln -sf /root/go/bin/pingcli /usr/local/bin/pingctl) \
    || echo ">> pingcli install skipped - adjust module path/version if you need it"

# ---- Google Cloud SDK (gcloud) ----
RUN curl -sSL https://sdk.cloud.google.com > /tmp/install_gcloud.sh \
    && bash /tmp/install_gcloud.sh --install-dir=/root --disable-prompts \
    && rm -f /tmp/install_gcloud.sh
ENV PATH="/root/google-cloud-sdk/bin:${PATH}"

# ---- Shell: auto-load config/pre-scripts for EVERY user's shell ----
# The scripts themselves (TAB completion, the proxy safety net, etc.) are
# bind-mounted read-only at runtime from ./config/pre-scripts (see
# docker-compose.yml), so they can be added/edited without rebuilding the
# image. /etc/bash.bashrc is sourced by every interactive non-login bash
# shell for every user (not just root's ~/.bashrc). Only *.sh files are
# auto-sourced, in sorted order (00-, 10-, ... prefixes control ordering) —
# non-.sh helpers like pxset are meant to be run manually, not sourced.
RUN printf '%s\n' \
    '# Auto-load every *.sh in config/pre-scripts (bind-mounted, all users).' \
    'if [ -d /etc/profile.d/pre-scripts ]; then' \
    '  for f in /etc/profile.d/pre-scripts/*.sh; do' \
    '    [ -f "$f" ] && source "$f"' \
    '  done' \
    'fi' \
    >> /etc/bash.bashrc

# ---- Unset build proxy so it isn't forced at runtime ----
# (docker-compose re-injects proxy + NO_PROXY at runtime if you need it.)
ENV http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY=""

# Keep the container alive so you can `exec` into it like a VM.
CMD ["tail", "-f", "/dev/null"]