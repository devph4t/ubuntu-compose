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
#
# PingAM/PingIDM/Ping Platform UI/ForgeRock Directory Server (token-store,
# user-store) are NOT apt packages — they're deployed as Kubernetes
# workloads via the Helm charts this repo installs (see
# config/install-cluster-prereqs.sh and MANUAL.md section 9). What follows
# is the CLI tooling to talk to those services once they're running in
# the cluster:
#   ldap-utils      : ldapsearch/ldapmodify/ldapwhoami/ldapdelete against
#                      ForgeRock Directory Server (DS/OpenDJ) — AM's CTS
#                      (token-store) and IDM's repo (user-store) when
#                      backed by DS.
#   postgresql-client : psql/pg_dump/pg_restore against IDM's repo when
#                      backed by PostgreSQL (the ForgeOps default).
#   openssl         : cert/keystore/mTLS debugging between AM, IDM, DS,
#                      and the Ping Platform UI's ingress.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl wget ca-certificates gnupg lsb-release git vim jq unzip zip tar \
      bash-completion openssh-client \
      build-essential pkg-config make \
      default-jdk maven \
      python3 python3-pip python3-venv python3-dev \
      jose \
      iproute2 iputils-ping dnsutils net-tools netcat-openbsd telnet traceroute \
      ldap-utils postgresql-client openssl \
    && rm -rf /var/lib/apt/lists/*

# ---- Classic developer tooling ----
#   less/nano/tree/htop/tmux : everyday shell tools
#   ripgrep/fd-find          : fast search (rg, and fd — see the symlink below)
#   locales/man-db/procps/lsof/rsync/patch/file/sudo : general Unix staples
#   git-lfs                  : large-file git support
#   python-is-python3/pipx   : `python` on PATH, isolated CLI tool installs
RUN apt-get update && apt-get install -y --no-install-recommends \
      less nano tree htop tmux ripgrep fd-find \
      locales man-db procps lsof rsync patch file sudo \
      git-lfs python-is-python3 pipx \
    && ln -sf "$(command -v fdfind)" /usr/local/bin/fd \
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

# ---- Bake in the custom commands (connect-kind, pxset) ----
# This image is meant to be portable — `docker save`d to a .tar and shared
# to another PC that won't have this repo's config/ folder or
# docker-compose.yml around — so these can't rely solely on bind mounts.
# COPY them straight into the image. When you DO run it through this
# repo's docker-compose.yml, its bind mounts (see volumes:) shadow these
# same paths, so local edits to config/connect-kind.sh or
# config/pre-scripts/pxset still take effect without a rebuild — this COPY
# only matters once the image is loaded standalone, elsewhere.
COPY config/connect-kind.sh /usr/local/bin/connect-kind
COPY config/pre-scripts/pxset /usr/local/bin/pxset
RUN chmod +x /usr/local/bin/connect-kind /usr/local/bin/pxset

# ---- Shell: baked-in TAB completion + proxy safety net, EVERY user's shell ----
# This runs automatically on every `docker exec` shell, so it's baked into
# the image at build time rather than sourced from a bind mount —
# /etc/bash.bashrc is sourced by every interactive non-login bash shell for
# every user (not just root's ~/.bashrc). The proxy check below still reads
# live values from the bind-mounted .env (/etc/ping-linux.env, see
# docker-compose.yml) on each new shell, so `.env` edits still take effect
# without a rebuild — only the completion/reachability-check CODE is fixed
# at build time, not the proxy values themselves. On a standalone/shared
# copy of this image with no .env mounted, the proxy simply stays off (the
# `if [ -f /etc/ping-linux.env ]` guard below skips cleanly).
RUN printf '%s\n' \
    '# ---- TAB completion (kubectl/helm/kind/kubectx/kubens/gcloud/pingcli) ----' \
    'source /usr/share/bash-completion/bash_completion 2>/dev/null || true' \
    'alias k=kubectl' \
    'source <(kubectl completion bash) 2>/dev/null || true' \
    'complete -o default -F __start_kubectl k 2>/dev/null || true' \
    'source <(helm completion bash) 2>/dev/null || true' \
    'source <(kind completion bash) 2>/dev/null || true' \
    'source /opt/kubectx/completion/kubectx.bash 2>/dev/null || true' \
    'source /opt/kubectx/completion/kubens.bash 2>/dev/null || true' \
    'command -v pingcli >/dev/null 2>&1 && source <(pingcli completion bash) 2>/dev/null || true' \
    '[ -f /root/google-cloud-sdk/completion.bash.inc ] && source /root/google-cloud-sdk/completion.bash.inc' \
    '' \
    '# ---- Proxy safety net: reads PROXY_ACTIVE/PROXY_HOST/PROXY_PORT live' \
    '# from the bind-mounted .env (/etc/ping-linux.env) on every new shell,' \
    '# and only enables the proxy if it answers within 1s.' \
    'if [ -f /etc/ping-linux.env ]; then' \
    '  set -a' \
    '  source /etc/ping-linux.env' \
    '  set +a' \
    'fi' \
    'if [ "${PROXY_ACTIVE:-}" = "true" ] && [ -n "${PROXY_HOST:-}" ] \' \
    '   && curl -s -m 1 -o /dev/null "http://${PROXY_HOST}:${PROXY_PORT}"; then' \
    '  export HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}/"' \
    '  export HTTPS_PROXY="$HTTP_PROXY"' \
    '  export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"' \
    'else' \
    '  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy' \
    'fi' \
    >> /etc/bash.bashrc

# ---- Unset build proxy so it isn't forced at runtime ----
# (docker-compose re-injects proxy + NO_PROXY at runtime if you need it.)
ENV http_proxy="" https_proxy="" HTTP_PROXY="" HTTPS_PROXY=""

# Keep the container alive so you can `exec` into it like a VM.
CMD ["tail", "-f", "/dev/null"]