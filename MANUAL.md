# Full Manual — Ubuntu 26.04 "VM" on Windows with Docker + kubectl + helm + kind

A complete, **no-administrator** setup. You run an Ubuntu 26.04 container that you
use like a VM, and from inside it you manage Docker, kubectl, helm, kind, and the
full ForgeOps / PingOne Advanced Identity Cloud toolchain.

This manual is written around your exact situation:

- **WSL distro won't start, but Docker Desktop works** → we use a **Docker
  container as the Ubuntu environment**, not a WSL distro. You never need WSL to
  boot a distro.
- **`kind create cluster` failed on cgroup** → we force **cgroup v2** via
  `.wslconfig` (no admin needed — it's in your own user folder).
- **`localhost:8080 refused`** from kubectl/helm → we wire a proper kubeconfig.
- **Corporate proxy** → `PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT` live in a
  gitignored `.env` (copy from `.env.example`) that's bind-mounted straight
  into the container and read fresh on every new shell — edit it any time,
  no rebuild, no `docker compose up`/`down`. It never touches the image
  build. Cluster traffic is told to bypass it.
- **20 GB RAM / 12 cores** → set in `.wslconfig`.

Your Windows username in the examples is `2521183489`. Change it if different.

---

## Contents

1. [How it works (read once)](#0-how-it-works)
2. [Folder layout — what files go where](#1-folder-layout)
3. [File 1 — `.wslconfig` (full code)](#2-file-wslconfig)
4. [File 2 — `Dockerfile` (full code)](#3-file-dockerfile)
5. [What gets installed](#3b-tooling)
6. [File 3 — `docker-compose.yml` (full code)](#4-file-docker-compose)
7. [File 4 — `connect-kind.sh` (full code)](#5-file-connect-kind)
7b. [Baked-in auto-run vs. `config\pre-scripts\` on-demand commands](#5b-pre-scripts)
7c. [Sharing the image — `docker save`/`docker load`](#5c-portable-image)
8. [Step-by-step from the start](#6-steps)
9. [Cluster prerequisites for Ping charts (ServiceMonitor / cert-manager)](#6b-prereqs)
9b. [Local image registry — fast kind image loads](#6b-prereqs-registry)
9c. [Ingress — reachable from Windows and the kind network](#6c-ingress)
10. [Troubleshooting table](#7-troubleshooting)
11. [Fallback if cgroup v2 is blocked (k3d)](#8-fallback)
12. [Daily cheat sheet](#9-cheatsheet)

---

<a name="0-how-it-works"></a>
## 1. How it works (read once)

```
Windows  (no administrator needed for anything below)
 └─ Docker Desktop         (its WSL2 VM shares ONE kernel → .wslconfig applies)
     ├─ my-ubuntu-vm       ← your Ubuntu 26.04 dev container ("the VM")
     │      has: docker CLI, kubectl, helm, kind, go, node, python, gcloud,
     │           kubens/kubectx, pingctl, jose, maven … + TAB completion
     │      talks to the host daemon via the mounted /var/run/docker.sock
     ├─ kind-control-plane ← the cluster kind builds, a SIBLING container
     └─ kind-registry      ← local image registry (docker-compose's `registry`
                              service), also a SIBLING container — see 9b
```

Your "VM" does **not** run its own Docker. It borrows the host's Docker through
the mounted socket. `kind` then creates the cluster as a sibling container next
to it. This is why WSL not starting a distro doesn't matter — Docker Desktop is
doing the work.

---

<a name="1-folder-layout"></a>
## 2. Folder layout — what files go where

Pick one project folder, e.g.:

```
C:\Users\2521183489\source\test\ubuntu\
```

Put these inside it:

```
ubuntu\
├── Dockerfile
├── docker-compose.yml    ← also runs the `registry` service (kind-registry) — see section 6b
├── .env                  ← copy from .env.example; PROXY_ACTIVE/PROXY_HOST/PROXY_PORT + VM_MEMORY/VM_CPUS + TZ
├── .env.example
├── config\               ← the whole folder is ALSO bind-mounted at /root/config inside the container
│   ├── connect-kind.sh   ← mounted onto PATH, run explicitly: `connect-kind`
│   ├── connect-registry.sh ← mounted onto PATH, run explicitly: `connect-registry`
│   ├── kind-config.yaml  ← `kind create cluster --config /root/config/kind-config.yaml`
│   ├── fix-and-run.sh    ← one-shot: CRLF fix + install-cluster-prereqs.sh + accelerator upgrade
│   ├── open-edge.bat     ← offline-PC domain workaround, no hosts-file/admin needed — see 9c
│   ├── wslconfig.example
│   ├── install-cluster-prereqs.sh
│   ├── environments\local\cert-manager-values.yaml
│   └── pre-scripts\
│       ├── pxset         ← mounted onto PATH, run explicitly: `pxset set`
│       └── kind-push     ← mounted onto PATH, run explicitly: `kind-push myapp:dev`
└── workspace\           ← you create this; your repos (ia-ext-ciam) go here
```

TAB completion and the proxy reachability check used to live here as
bind-mounted `.sh` files, auto-sourced on every shell. They're now baked
directly into the Dockerfile's `/etc/bash.bashrc` instead — see section 7b.
`config\pre-scripts\` is reserved for the other kind of thing: commands you
invoke explicitly during `docker exec`, like `pxset`.

`.env` is gitignored and holds two different kinds of setting, treated
differently on purpose:

- `PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT` are **not** used for `${VAR}`
  substitution in `docker-compose.yml` and never reach `docker build`.
  Instead they're bind-mounted read-only into the container at
  `/etc/ping-linux.env` and read straight off disk by the proxy check baked
  into the Dockerfile's `/etc/bash.bashrc` (section 7b) on every new shell.
  Edit any time — no rebuild, no `docker compose up`/`down`.
  `PROXY_ACTIVE=true`/`false` is a real string comparison here (plain bash,
  not compose interpolation), so it means exactly what it says.
- `VM_MEMORY`/`VM_CPUS` **are** standard `${VAR}` substitution, consumed by
  `docker-compose.yml`'s `deploy.resources.limits` — they're
  container-creation attributes, so there's no way around needing `docker
  compose up -d` (recreate) after changing them. Keep them at or below what
  you set in `.wslconfig` (see `config\wslconfig.example`).
- `TZ` **is** also standard `${VAR}` substitution, consumed by
  `docker-compose.yml`'s `environment:` block — a container-creation
  attribute like `VM_MEMORY`/`VM_CPUS`, so it needs `docker compose up -d`
  (recreate) too. Defaults to `Asia/Bangkok` (Thailand, UTC+7) if unset or
  blank; the image also bakes that same default into `tzdata` at build
  time, so a standalone/shared copy of the image (no `.env` mounted) still
  comes up on Thailand time.
- `INGRESS_DOMAIN` is **not** consumed by `docker-compose.yml`/`Dockerfile`
  at all — it's a plain shell variable for you, exported into every
  container shell the same way (`.env` is `source`d automatically). Pass it
  into whatever Helm install sets your ingress domain/FQDN. Defaults to the
  wildcard `127.0.0.1.nip.io` (any subdomain resolves to `127.0.0.1`, no
  admin-rights hosts-file edit needed) — see section 9c / README.md's
  Ingress section for the full picture, including what `config/kind-config.yaml`
  does to make it reachable from Windows.

And one file goes in your **user home**, not the project folder (copy it from
`config/wslconfig.example`):

```
C:\Users\2521183489\.wslconfig
```

---

<a name="2-file-wslconfig"></a>
## 3. File 1 — `.wslconfig` (FULL code)

**Location:** `C:\Users\2521183489\.wslconfig`
(leading dot, **no** `.txt` extension). No admin needed — it's your own folder.

```ini
# =====================================================================
#  C:\Users\2521183489\.wslconfig
#  No administrator rights needed. This controls the single WSL2 VM
#  that Docker Desktop also runs inside.
# =====================================================================

[wsl2]
memory=20GB
processors=12

# The important line: force the WSL2 kernel to use cgroup v2.
# kind + modern Kubernetes REQUIRE cgroup v2. Your Docker was on
# cgroup v1, which is why the control-plane failed to start.
#
# EXACT spelling matters: kernelCommandLine  (k-e-r-n-e-l)
kernelCommandLine = cgroup_no_v1=all
```

If, after a restart, `docker info` still shows `Cgroup Version: 1`, replace the
last line with this one and restart again:

```ini
kernelCommandLine = systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all
```

---

<a name="3-file-dockerfile"></a>
## 4. File 2 — `Dockerfile` (FULL code)

**Location:** `...\ubuntu\Dockerfile`

`docker-compose.yml` deliberately passes no build args, so these all default
to blank and `docker compose build` never uses a proxy — `.env` must not
affect the build. If you ever need a one-off proxied build, pass it
manually: `docker compose build --build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`

```dockerfile
# syntax=docker/dockerfile:1
FROM ubuntu:26.04

# ============================================================
# Build-time proxy (corporate network).
# Leave blank if you are NOT behind a proxy.
# Only used while building; not baked into the final runtime env.
# Not sourced from .env — see the note above.
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
# config/install-cluster-prereqs.sh and section 9). What follows is the CLI
# tooling to talk to those services once they're running in the cluster:
#   ldap-utils        : ldapsearch/ldapmodify/ldapwhoami/ldapdelete against
#                        ForgeRock Directory Server (DS/OpenDJ) — AM's CTS
#                        (token-store) and IDM's repo (user-store) when DS-backed.
#   postgresql-client  : psql/pg_dump/pg_restore against IDM's repo when
#                        backed by PostgreSQL (the ForgeOps default).
#   openssl            : cert/keystore/mTLS debugging between AM, IDM, DS,
#                        and the Ping Platform UI's ingress.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl wget ca-certificates gnupg lsb-release git vim jq unzip zip tar \
      bash-completion openssh-client ncurses-term \
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
#
# Deliberately NOT added: apt's `gradle` — Ubuntu ships 4.4.1 (2017), badly
# stale next to modern Gradle (8.x+), and most projects use the `./gradlew`
# wrapper anyway, which ignores system Gradle. Install a real version via
# SDKMAN inside a project if you ever need it.
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
# every user (not just root's ~/.bashrc). The proxy check still reads live
# values from the bind-mounted .env (/etc/ping-linux.env, see
# docker-compose.yml) on each new shell, so .env edits still take effect
# without a rebuild — only the completion/reachability-check CODE is fixed
# at build time, not the proxy values themselves. On a standalone/shared
# copy of this image with no .env mounted, the proxy simply stays off (the
# `if [ -f /etc/ping-linux.env ]` guard skips cleanly). See section 7b.
#
# config/pre-scripts/ is for the opposite case: commands you invoke
# explicitly during `docker exec` (e.g. `pxset set`), not auto-run scripts.
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
```

> **Notes**
> - If a corporate proxy blocks `download.docker.com`, `go.dev`, `deb.nodesource.com`,
>   `sdk.cloud.google.com`, or `dl.k8s.io`, the matching `RUN` will fail. Tell me
>   which one and I'll swap it for a GitHub-hosted mirror.
> - `pingcli` install is wrapped so it can't break the build. If your team ships
>   a specific `pingctl` binary/URL, drop it into `/usr/local/bin` instead.
> - Bump `GO_VERSION`, `COMPOSE_VERSION`, `DOCKER_CLI_VERSION`, or the NodeSource
>   `setup_XX.x` line whenever you want newer versions.

---

<a name="3b-tooling"></a>
## 5. What gets installed (quick reference)

| Category | Tools |
|----------|-------|
| Kubernetes | `kubectl`, `helm`, `kind`, `kubectx`, `kubens` |
| Cloud | `gcloud` (Google Cloud SDK) |
| Ping / ForgeOps | `pingctl`/`pingcli`, `jose` (JWT/JOSE CLI), `ldap-utils` (ForgeRock Directory Server — token-store/user-store), `postgresql-client` (IDM repo), `openssl` (certs/keystores) |
| Languages | `go`, `node` + `npm` + `yarn`, `python3` + `pip` + `venv` |
| Java build | `default-jdk`, `maven` (`mvn`) |
| Build/native | `build-essential`, `make`, `pkg-config` |
| Docker | `docker` CLI + `docker compose` plugin (talks to host daemon) |
| Network/debug | `iproute2`, `ping`, `dig`/`nslookup`, `net-tools`, `netcat`, `telnet`, `traceroute`, `lsof` |
| Classic dev tools | `less`, `nano`, `tree`, `htop`, `tmux`, `ripgrep` (`rg`), `fd-find` (`fd`), `rsync`, `patch`, `file`, `sudo`, `git-lfs`, `python-is-python3` (`python`), `pipx` |
| Shell | `bash-completion` + TAB completion wired for kubectl/helm/kind/kubectx/kubens/gcloud, plus `k` alias; `ncurses-term` for broader `TERM` compatibility with Windows terminals |

Verify after build (inside the container):
```bash
kubectl version --client && helm version && kind version
go version && node -v && python3 -V && mvn -v
gcloud version && jose --help >/dev/null && echo "jose ok"
kubens --help >/dev/null && echo "kubens ok"
command -v pingctl && pingctl --version || echo "pingctl optional"
ldapsearch -VV 2>&1 | head -1 && psql --version && openssl version
rg --version | head -1 && fd --version && tmux -V && git-lfs version
```

---

<a name="4-file-docker-compose"></a>
## 6. File 3 — `docker-compose.yml` (FULL code)

**Location:** `...\ubuntu\docker-compose.yml`

`.env` at the project root holds two kinds of setting, wired in two
different ways. Proxy settings (`PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT`) —
unlike a typical compose `.env` — are deliberately **not** used for `${VAR}`
substitution here. `.env` is bind-mounted straight into the container
instead (last volume below) and read fresh off disk by `config\pre-scripts\`
on every new shell. That means: no build args reference it (the build never
sees a proxy), and no `environment:` entry bakes proxy values in at
container-creation time — so editing those never requires `docker compose
up`/`down`, only opening a new shell.

`VM_MEMORY`/`VM_CPUS`, by contrast, ARE standard `${VAR}` substitution — they
set `deploy.resources.limits` below, a container-creation attribute with no
way around needing `docker compose up -d` (recreate) after a change.

Copy `.env.example` to `.env` and set `PROXY_ACTIVE=true`/`false` plus
`PROXY_HOST`/`PROXY_PORT`/`VM_MEMORY`/`VM_CPUS`.

```yaml
services:
  ubuntu-dev:
    build:
      context: .
      # No proxy args here on purpose — .env must never affect the image
      # build. One-off proxied build: `docker compose build --build-arg HTTP_PROXY=... --build-arg HTTPS_PROXY=...`
    image: my_wsl_ubuntu:26.04
    container_name: my-ubuntu-vm
    hostname: ubuntu-dev
    command: ["tail", "-f", "/dev/null"]   # keeps the "VM" running
    working_dir: /root/source

    # RAM / CPU limits for the container itself (the WSL2 VM overall is
    # capped by .wslconfig at 20GB / 12 cores). Sourced from .env
    # (VM_MEMORY/VM_CPUS) — a change here needs `docker compose up -d`
    # (recreate) to take effect, unlike the proxy settings below.
    deploy:
      resources:
        limits:
          memory: "${VM_MEMORY}"
          cpus: "${VM_CPUS}"

    environment:
      # No proxy vars here either, same reason as above — see the bind
      # mount at the bottom of volumes: instead.
      # ---- CRITICAL: cluster + local traffic must bypass the proxy ----
      NO_PROXY: "localhost,127.0.0.1,::1,host.docker.internal,kind-control-plane,kind-worker,.svc,.cluster.local,172.18.0.0/16,10.96.0.0/12"
      no_proxy: "localhost,127.0.0.1,::1,host.docker.internal,kind-control-plane,kind-worker,.svc,.cluster.local,172.18.0.0/16,10.96.0.0/12"

    volumes:
      # Talk to the host Docker daemon (docker-outside-of-docker).
      - /var/run/docker.sock:/var/run/docker.sock
      # Your project folder, editable from both Windows and the container.
      - ./workspace:/root/source
      # Persist kubeconfig between restarts.
      - kube-config:/root/.kube
      # ---- Custom shell commands: mounted straight onto PATH, run
      # explicitly during `docker exec` — not auto-run. See 7b for why TAB
      # completion and the proxy check are handled differently (baked into
      # the Dockerfile instead).
      - ./config/connect-kind.sh:/usr/local/bin/connect-kind:ro
      - ./config/pre-scripts/pxset:/usr/local/bin/pxset:ro
      # Live config, read straight from disk — edit this file, no
      # rebuild/up/down needed. See 7b.
      - ./.env:/etc/ping-linux.env:ro

    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  kube-config:
```

---

<a name="5-file-connect-kind"></a>
## 7. File 4 — `connect-kind.sh` (FULL code)

**Location:** `...\ubuntu\config\connect-kind.sh`
Save with **LF** line endings (not CRLF). The other example config files
(`wslconfig.example`, `install-cluster-prereqs.sh`) live next to it in
`config\`. `.env.example` is the one exception — it stays at the project
root, next to the `.env` it's copied into. `config\pre-scripts\` is covered
separately below.

> Note: the container's Docker name is **`my-ubuntu-vm`** (from `container_name`),
> which is NOT the same as its `hostname` (`ubuntu-dev`). `docker network connect`
> needs the Docker **name**, so this script uses `my-ubuntu-vm`.

```bash
#!/usr/bin/env bash
# =====================================================================
#  Run this INSIDE the container, right after:  kind create cluster
#
#  Fixes "connection to localhost:8080 refused" by giving this container
#  a kubeconfig that actually points at the kind cluster, TLS-valid.
#
#  kind runs the cluster as SIBLING containers on the host. The default
#  kubeconfig says https://127.0.0.1:<port>, but inside THIS container
#  127.0.0.1 is the container itself. We join kind's network and use
#  https://kind-control-plane:6443, a valid name in the API server's TLS
#  cert → no --insecure needed.
#
#  Usage:  connect-kind            (default cluster "kind")
#          connect-kind mycluster  (custom name)
# =====================================================================
set -euo pipefail

CLUSTER="${1:-kind}"
CONTAINER="my-ubuntu-vm"     # docker container_name from docker-compose.yml
TARGET="/root/.kube/config"

mkdir -p /root/.kube

# If $KUBECONFIG is already exported to something else, every kubectl
# command in THIS shell will keep reading that stale file even after we
# fix $TARGET below — a bad env var elsewhere (e.g. left over from
# manually following the KUBECONFIG troubleshooting tip) reproduces the
# exact "couldn't get current server API group list" / stale
# 127.0.0.1:<port> error even though the real kubeconfig is correct.
if [ -n "${KUBECONFIG:-}" ] && [ "${KUBECONFIG}" != "${TARGET}" ]; then
  echo "warning: \$KUBECONFIG is set to '${KUBECONFIG}', not ${TARGET}." >&2
  echo "         Every kubectl command in this shell will keep using that" >&2
  echo "         file instead of the one connect-kind is about to fix." >&2
  echo "         Run: unset KUBECONFIG   (or open a new shell)" >&2
fi

# Attach this container to kind's network so 'kind-control-plane' resolves.
docker network connect kind "${CONTAINER}" 2>/dev/null || true

# Write to a temp file first — if `kind get kubeconfig` fails, a plain
# `> $TARGET` would still truncate $TARGET to empty (bash opens/truncates
# the redirect target before running the command), destroying a
# previously-working kubeconfig even though `set -e` catches the failure.
TMP="$(mktemp)"
if ! kind get kubeconfig --name "${CLUSTER}" --internal > "$TMP"; then
  rm -f "$TMP"
  echo "error: 'kind get kubeconfig --name ${CLUSTER} --internal' failed (see above)." >&2
  echo "       ${TARGET} was left untouched." >&2
  exit 1
fi
mv "$TMP" "$TARGET"

echo "kubeconfig written to ${TARGET}"
echo "Testing connection..."
export KUBECONFIG="$TARGET"

# The API server can take a moment to become reachable over the internal
# network path right after cluster creation — retry briefly instead of
# failing on the very first attempt.
for i in 1 2 3 4 5; do
  if kubectl get nodes; then
    exit 0
  fi
  [ "$i" -lt 5 ] && { echo "not ready yet, retrying ($i/5)..." >&2; sleep 2; }
done
exit 1
```

---

<a name="5b-pre-scripts"></a>
## 7b. Two different patterns: baked-in auto-run vs. `config\pre-scripts\` commands

Two things need to happen on every `docker exec` shell (TAB completion, the
proxy safety net) and one thing you invoke on demand (`pxset`). These are
deliberately wired differently:

**Auto-run, every shell, every user — baked into the Dockerfile.** TAB
completion and the proxy reachability check are appended straight into
**`/etc/bash.bashrc`** at image build time (the system-wide bashrc sourced by
every interactive shell for every user, not just root's `~/.bashrc`). They
are NOT bind-mounted `.sh` files anymore — the code itself ships in the
image. The proxy check still reads `PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT`
fresh from the bind-mounted `/etc/ping-linux.env` (your `.env`) each time a
shell opens, so editing `.env` still takes effect immediately with no
rebuild and no `docker compose up`/`down` — only the *code that reads it* is
now fixed at build time, not the proxy values. Changing the completion or
proxy-check logic itself does need a rebuild (`docker compose build`), since
there's no bind mount left to edit live.

```bash
# TAB completion
source /usr/share/bash-completion/bash_completion 2>/dev/null || true
alias k=kubectl
source <(kubectl completion bash) 2>/dev/null || true
# ... helm/kind/kubectx/kubens/pingcli/gcloud completions ...

# Proxy safety net
if [ -f /etc/ping-linux.env ]; then
  set -a; source /etc/ping-linux.env; set +a
fi
if [ "${PROXY_ACTIVE:-}" = "true" ] && [ -n "${PROXY_HOST:-}" ] \
   && curl -s -m 1 -o /dev/null "http://${PROXY_HOST}:${PROXY_PORT}"; then
  export HTTP_PROXY="http://${PROXY_HOST}:${PROXY_PORT}/" HTTPS_PROXY="$HTTP_PROXY"
  export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
else
  unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
fi
```

(Full version in the Dockerfile listing, section 4.)

**Invoke on demand — `config\pre-scripts\`.** Anything you want to run as an
explicit command during `docker exec` (not auto-sourced) goes here, and is
wired in TWICE, on purpose:

1. `COPY`'d into the image in the Dockerfile (`/usr/local/bin/<name>`) — so
   the command works even if this image is shared standalone (see 7c).
2. Bind-mounted onto the same path in `docker-compose.yml` — so when you run
   it through this repo normally, the bind mount shadows the baked-in copy
   and local edits take effect immediately, no rebuild.

Today that's:

| File | Purpose |
|------|---------|
| `connect-kind.sh` | Wires kubectl to a freshly created kind cluster — run as `connect-kind`. Covered in full in section 7. |
| `pxset` | Manual proxy toggle: `source pxset set` / `source pxset unset` (must be sourced, or the exports only affect pxset's own subprocess) — reads `PROXY_HOST`/`PROXY_PORT` fresh from the bind-mounted `/etc/ping-linux.env`. It must NOT be auto-sourced — it `exit`s when called with no argument, which would kill whatever shell sourced it. If `PROXY_HOST` isn't set (no `.env` mounted — e.g. a standalone/shared copy of this image), `pxset set` fails loudly with a clear message instead of silently building a broken `http://:/` URL. |

Adding a new command script means both a `COPY`+`chmod` line in the
Dockerfile AND a matching bind-mount line in `docker-compose.yml`'s
`volumes:` — miss the second one and it still works standalone, just not
live-editable during local dev.

---

<a name="5c-portable-image"></a>
## 7c. Sharing the image — `docker save` / `docker load`

Everything above is intentionally designed so this image is self-contained
once built: all CLIs, TAB completion, and the `connect-kind`/`pxset`
commands are baked in via `RUN`/`COPY`, not left dependent on this repo's
`config\` folder or `docker-compose.yml` being present on the machine that
runs it. What's deliberately **not** baked in — because it's inherently
host/environment-specific data, not tooling — is `.env` (your proxy
settings) and the `workspace`/`kube-config` bind mounts.

Export it:
```powershell
docker compose build
docker save my_wsl_ubuntu:26.04 -o my_wsl_ubuntu_26.04.tar
```

On the other PC (no repo checkout needed at all — this alone gives you a
fully working shell with every CLI, TAB completion, `connect-kind`, and
`pxset`):
```powershell
docker load -i my_wsl_ubuntu_26.04.tar
docker run -d --name my-ubuntu-vm --hostname ubuntu-dev `
  -v /var/run/docker.sock:/var/run/docker.sock `
  my_wsl_ubuntu:26.04
docker exec -it my-ubuntu-vm bash
```

To get the full experience (live `.env` proxy config, `kind`
cluster-creation via the host's Docker socket, a persisted kubeconfig, your
project files under `/root/source`), copy this whole repo over instead and
use `docker compose up -d` as normal — `docker load` just guarantees the
image itself always has everything installed, regardless of which machine
runs it.

`my_wsl_ubuntu_26.04.tar` is sizeable (image with the full toolchain) —
`.gitignore` already excludes `*.tar` so it never ends up in version
control; share it by whatever out-of-band means you'd use for a large binary
(network share, USB, etc.).

---

<a name="6-steps"></a>
## 8. Step-by-step from the start

### Step 0 — Prerequisites
- Docker Desktop installed and running (you already have this).
- The files above created in the right locations.

### Step 1 — Enable cgroup v2 (fixes the kind failure)
1. Create/edit `C:\Users\2521183489\.wslconfig` with the contents from
   [section 3](#2-file-wslconfig). In PowerShell:
   ```powershell
   notepad C:\Users\2521183489\.wslconfig
   ```
   Paste, save, close. **Verify the spelling is `kernelCommandLine`** — an
   earlier attempt showed `kelnelCommandLine`, which WSL silently ignores.
2. Restart the WSL2 VM (also restarts Docker Desktop's backend):
   ```powershell
   wsl --shutdown
   ```
   Wait ~10s. Reopen Docker Desktop if it doesn't return on its own.
3. Verify:
   ```powershell
   docker info | Select-String cgroup
   ```
   **Must show `Cgroup Version: 2`.** Do not continue until it does.

### Step 2 — Build and start the "VM"
From the `ubuntu\` folder in PowerShell:
```powershell
mkdir workspace
copy .env.example .env    # then edit .env: set PROXY_ACTIVE=true + PROXY_HOST/PROXY_PORT, or false to disable
docker compose build
docker compose up -d
```
Enter it (your "ssh into the VM"):
```powershell
docker compose exec ubuntu-dev bash
```
**Running this from Git Bash (Git for Windows' bundled `bash.exe`)?** Prefix
it with `winpty`, or you'll hit `bash: $'\r': command not found` the moment
the shell opens — a pty-allocation quirk, not a bug in this repo (see the
troubleshooting table, section 10):
```bash
winpty docker compose exec ubuntu-dev bash
```
PowerShell and Windows Terminal don't need this.

Sanity check inside (see the fuller list in [section 5](#3b-tooling)):
```bash
docker ps                 # proves the socket works
kubectl version --client
helm version
kind version              # prints a version, not XML
```
TAB completion is already active: type `kubectl get po<TAB>` or `k get <TAB>`.

### Step 3 — Create the cluster
Inside the container:
```bash
kind create cluster --config /root/config/kind-config.yaml
```
With cgroup v2 this now finishes "Starting control-plane" instead of failing.
The `--config` wires containerd to pull images through the local registry —
see section 9b below for why that matters and what it replaces.

### Step 4 — Wire kubectl (fixes localhost:8080)
```bash
connect-kind
```
You should see a node `Ready`. Re-run `connect-kind` any time you recreate the
cluster. (If you ever get a `^M` error, the file was saved CRLF — re-save as LF
on Windows; do not `sed` it in place because it's mounted read-only.)

### Step 4b — Wire the local registry
```bash
connect-registry
```
Attaches `kind-registry` (docker-compose's `registry` service) to kind's
network and advertises it to the cluster. Re-run any time you recreate the
cluster, same as `connect-kind`. From here on, build+push instead of
`kind load docker-image`:
```bash
docker build -t myapp:dev .
kind-push myapp:dev   # tags + pushes to localhost:5000/myapp:dev
```

### Step 5 — Deploy your charts
```bash
cd /root/source/ia-ext-ciam/charts/midships-ping-ais-infrastructure
export ENV_NAME=local
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm upgrade --install ingress-nginx-tls charts/ingress-nginx-tls \
  --namespace ingress-nginx \
  --create-namespace
```
Before installing cert-manager and the Ping accelerator, see the next section.

---

<a name="6b-prereqs"></a>
## 9. Cluster prerequisites for the Ping charts

Several charts (cert-manager, `app-policy-store`, others) reference the
`ServiceMonitor` kind and cert-manager CRDs. On a fresh local kind cluster those
don't exist yet, giving errors like:

```
no matches for kind "ServiceMonitor" in version "monitoring.coreos.com/v1"
no matches for kind "Certificate"/"ClusterIssuer" ... ensure CRDs are installed first
```

Install these **once per cluster**, in order:

```bash
# 1. Prometheus-Operator ServiceMonitor CRD (satisfies every chart that wants it)
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
kubectl get crd servicemonitors.monitoring.coreos.com   # verify it exists

# 2. cert-manager WITH its CRDs (creates Certificate / ClusterIssuer kinds)
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set prometheus.servicemonitor.enabled=false \
  --values environments/${ENV_NAME}/cert-manager-values.yaml

# 3. Wait for cert-manager to be ready BEFORE anything that creates Certificates
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook

# 4. Now cert-issuer and the accelerator will find the CRDs they need
helm upgrade --install cert-issuer charts/cert-issuer/ --namespace cert-manager

# 5. Run the accelerator
cd /root/source/ia-ext-ciam
./charts/midships-ping-ais-accelerator/upgrade.sh \
  --all --environment-name local --rollout --pui-enabled true
```

`GCP_SERVICE_KEY length: 0` in the accelerator output is fine for `local` (it's
only needed for non-local environments).

**One-shot alternative:** once the cluster exists and Steps 4/4b have run,
`config/fix-and-run.sh` (mounted at `/root/config/fix-and-run.sh`) does all
of the above for you — including fixing any CRLF line endings under
`workspace/` first (a recurring problem for scripts checked out on Windows,
notably `ia-ext-ciam`'s `charts/midships-ping-ais-accelerator/upgrade.sh`,
since that repo's line-ending policy is outside this one's `.gitattributes`
control):
```bash
bash /root/config/fix-and-run.sh
```
It resolves its own paths (from `install-cluster-prereqs.sh`'s location and
from `/root/source`), so it works the same whether run inside the container
or, less commonly, directly from this repo's root on the host.

---

<a name="6b-prereqs-registry"></a>
## 9b. Local image registry — why `kind load docker-image` freezes on big images

`kind load docker-image` does a `docker save` of the image into a tar
stream, then imports that tar into the node container — a single-threaded
compress/decompress pipeline. On a large image (the accelerator images, or
this repo's own multi-GB `my_wsl_ubuntu` image, are typical sizes) that can
sit for a long time looking hung. `docker stats` showing the kind node's CPU
pegged during this is real, but it's one core doing tar/gzip work — neither
`VM_CPUS` (that limit is on `ubuntu-dev`, not the sibling `kind-control-plane`
container) nor more WSL2 processors in `.wslconfig` speeds up a
single-threaded step.

The fix wired into this repo: a local registry
(`docker-compose.yml`'s `registry` service, container name `kind-registry`,
published at `127.0.0.1:5000`) that the cluster's containerd is configured
to pull from directly (`config/kind-config.yaml`'s
`containerdConfigPatches`, applied via `kind create cluster --config
config/kind-config.yaml` — Step 3). `connect-registry` (Step 4b) attaches
the registry to kind's docker network and advertises the mapping to the
cluster. From then on:

```bash
docker build -t myapp:dev .
kind-push myapp:dev    # tags + pushes to localhost:5000/myapp:dev, see config/pre-scripts/kind-push
# reference localhost:5000/myapp:dev in your pod/values — no `kind load` step, ever
```

This is a normal registry pull — layered, streamed, and (for multi-node
clusters) parallel across nodes — which is why it doesn't hit the same wall
as the tar-based `kind load` path, especially as images grow or get pushed
repeatedly across a session.

---

<a name="6c-ingress"></a>
## 9c. Ingress — reachable from Windows AND from inside the kind network

`config/kind-config.yaml`'s `nodes:` block labels the control-plane
`ingress-ready=true` and publishes ports 80/443 from that node straight
through to the Docker host — the standard [kind + ingress-nginx
recipe](https://kind.sigs.k8s.io/docs/user/ingress/). Because Docker Desktop
forwards published container ports to Windows, `http(s)://localhost` (or any
hostname resolving to `127.0.0.1`) reaches the ingress controller directly
from a Windows browser — no `docker-compose.yml` port mapping needed for
that. `ubuntu-dev` and every pod can already reach the controller over the
`kind` docker network regardless of this port mapping (that's just ordinary
in-cluster/sibling-container networking) — the mapping is only what adds
Windows-browser access on top.

That only opens the door on the node side. The ingress controller install
itself — whatever chart `workspace/` deploys (e.g. `ingress-nginx-tls`) —
still needs to be configured to actually bind those ports:
- `nodeSelector: {ingress-ready: "true"}` so its pods schedule onto that node
- `hostPort`/`hostNetwork` enabled on 80/443 (check the chart's
  `values.yaml`; for stock `ingress-nginx` this is
  `controller.hostPort.enabled=true`)

**Domain:** `.env`'s `INGRESS_DOMAIN` (default `127.0.0.1.nip.io`) is a
wildcard domain — any subdomain of it resolves to `127.0.0.1` via public
DNS, e.g. `login.127.0.0.1.nip.io` and `admin.127.0.0.1.nip.io` both just
work, no hosts-file edit. That matters for ForgeOps/Ping-style setups that
need distinct per-service hostnames (SSO cookie-domain scoping). It's not
read by `docker-compose.yml`/the `Dockerfile` — it's for you to pass into
whichever Helm flag sets your chart's domain/FQDN (check
`workspace/ia-ext-ciam`'s `values.yaml` for the exact key) — but it IS
already exported as a plain `$INGRESS_DOMAIN` shell variable in every
container shell, same mechanism as `PROXY_*` (`.env` is bind-mounted and
`source`d automatically — section 7b).

If nip.io's DNS is blocked on your network, set `INGRESS_DOMAIN` to a real
domain and add matching entries to the Windows hosts file yourself instead
— that path needs admin rights, unlike the nip.io default.

**Fully offline PC** (e.g. it only has the `docker load`-ed shared image,
per section 7c — no internet at all): nip.io needs real DNS the same way a
hosts-file entry needs admin rights, so neither works there. Copy
`config/open-edge.bat` over with the image instead and run it (`open-edge.bat
mydomain.local` for a custom domain, default `ping.local`) — it opens Edge
with `--host-resolver-rules` mapping `*.<domain>` to `127.0.0.1` inside the
browser itself, before any DNS lookup, no admin rights and no system file
touched. Set that PC's own `.env` `INGRESS_DOMAIN` to match the domain you
pass it.

---

<a name="7-troubleshooting"></a>
## 10. Troubleshooting (the exact errors seen)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Starting control-plane` fails, `Failed to create symlink /sys/fs/cgroup/...` | Docker on cgroup v1 | Step 1: `.wslconfig` → cgroup v2 → `wsl --shutdown` |
| `docker info` still `Cgroup Version: 1` after edit | typo `kelnelCommandLine`, or no `wsl --shutdown` | fix spelling to `kernelCommandLine`, shut down again |
| `kind` gives `syntax error near '<'` / XML | URL typo `lastest` → 404 saved as the binary | use `latest` |
| `connection to the server localhost:8080 refused` | no kubeconfig in container | run `connect-kind` (Step 4) |
| `couldn't get current server API group list ... 127.0.0.1:<port>` **even after running `connect-kind`** | `$KUBECONFIG` is exported to some other file in that shell — `connect-kind` correctly rewrites `/root/.kube/config`, but your shell keeps reading the stale one | `unset KUBECONFIG`, or open a new shell. `connect-kind` now warns about this itself (and its own internal check always uses the right file, so its own output can be trusted even if this warning fires). |
| `dial tcp: lookup kind-control-plane ... no such host` | container not on kind's network | `docker network connect kind my-ubuntu-vm` then rewrite kubeconfig |
| `No such container: ubuntu-dev` on network connect | used `hostname`, not the docker name | use `my-ubuntu-vm` (the `container_name`) |
| `sed: cannot rename ... Device or resource busy` | editing a read-only mounted file in place | re-save the source file as LF on Windows instead |
| `no matches for kind "ServiceMonitor"` | Prometheus CRD missing | apply the ServiceMonitor CRD (section 9, step 1) |
| `no matches for kind "Certificate"/"ClusterIssuer"` | cert-manager CRDs missing / wrong order | install cert-manager with `--set crds.enabled=true` first (section 9) |
| helm/kubectl hang through proxy | proxy intercepting cluster traffic | `NO_PROXY` (already in compose) |
| `$env:KUBECONFIG: command not found` | PowerShell syntax used in bash | in bash: `export KUBECONFIG=/root/.kube/config` |
| `bash: $'\r': command not found` right after `docker compose exec ubuntu-dev bash` | Not a repo/file issue — `/etc/bash.bashrc` is generated LF-clean at build time regardless of host OS (verify: `docker compose exec ubuntu-dev bash -c 'cat -A /etc/bash.bashrc \| grep -c "\^M\$"'` should print `0`). Confirmed cause: Git for Windows' bundled `bash.exe` (GNU bash via MSYS2) doesn't allocate a proper pty for `docker exec` on its own. | Prefix with `winpty`: `winpty docker compose exec ubuntu-dev bash`. Or run the same command from PowerShell / Windows Terminal instead of Git Bash. |
| helm `curl ... githubusercontent.com` fails | incomplete URL | `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3` |
| `kind load docker-image` looks frozen on a large image; `docker stats` shows the kind node's CPU pegged but nothing progresses | single-threaded `docker save`/tar-import pipeline — more CPU doesn't parallelize it, and `VM_CPUS` doesn't even apply to the sibling kind node container | use the local registry instead (section 9b): `docker build -t myapp:dev .` then `kind-push myapp:dev` |
| `kind create cluster --config config/kind-config.yaml` fails to bind port 80/443 | something else on Windows already owns that port (IIS, Skype, another local dev server) | free the port, or change the `hostPort` values in `config/kind-config.yaml` (section 9c) and use that port instead of 80/443 when browsing |
| Ingress reachable via `kubectl`/inside the cluster but not from a Windows browser | `kind-config.yaml`'s port mapping only opens the door — the ingress controller chart itself also needs `nodeSelector: {ingress-ready: "true"}` and `hostPort`/`hostNetwork` enabled on 80/443 | check the chart's `values.yaml` (section 9c) |

Deeper diagnosis if control-plane still won't start:
```bash
kind create cluster --retain
docker logs kind-control-plane 2>&1 | grep -iE "error|failed|fatal" | tail -30
kind delete cluster
```

---

<a name="8-fallback"></a>
## 11. Fallback — if cgroup v2 is blocked (use k3d)

Some locked-down machines block the WSL2 kernel change. If `docker info` stays on
cgroup v1 no matter what, use **k3d** (k3s in Docker). It's lighter and tolerates
the environment far better than kind:

```bash
# inside the container
curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
k3d cluster create dev --api-port host.docker.internal:6443
kubectl get nodes
```
Your helm steps are identical afterward.

---

<a name="9-cheatsheet"></a>
## 12. Daily cheat sheet

**On Windows (PowerShell):**
```powershell
docker compose up -d                     # start the VM
docker compose exec ubuntu-dev bash      # enter it
docker compose down                      # stop it (kube volume persists)
docker info | Select-String cgroup       # confirm cgroup v2
```

**Inside the VM (bash):**
```bash
kind create cluster --config /root/config/kind-config.yaml   # make a cluster (wired to the local registry)
connect-kind               # wire kubectl to it
connect-registry           # wire the local registry into it
kubectl get nodes          # verify  (k get nodes — alias + TAB completion work)

bash /root/config/fix-and-run.sh   # one-shot: cluster prereqs + accelerator upgrade

docker build -t myapp:dev .
kind-push myapp:dev        # tag + push to localhost:5000/myapp:dev — instead of `kind load docker-image`

kubens                     # list namespaces / switch:  kubens ping-ais
kubectx                    # list/switch contexts

gcloud auth login          # (non-local only) authenticate gcloud
pingctl --help             # Ping CLI (if installed)

kind delete cluster        # tear down
```

---

## Appendix — auto-switch the proxy by network reachability

This used to be a manual copy-paste snippet for `/root/.bashrc`, then a
bind-mounted `config\pre-scripts\10-proxy.sh`. It's now baked directly into
the Dockerfile's `/etc/bash.bashrc` — see [section 7b](#5b-pre-scripts).
Every new shell re-checks whether `PROXY_HOST:PROXY_PORT` (read live from
`.env`) answers within 1s and exports or unsets `HTTP_PROXY`/`HTTPS_PROXY`
accordingly, automatically, for every user. For a manual on-demand toggle
instead, use `pxset set` / `pxset unset` (`config\pre-scripts\pxset`, also
covered in 7b).
