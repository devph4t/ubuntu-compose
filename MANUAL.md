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
7b. [`config\pre-scripts\` — auto-loaded for every user's shell](#5b-pre-scripts)
8. [Step-by-step from the start](#6-steps)
9. [Cluster prerequisites for Ping charts (ServiceMonitor / cert-manager)](#6b-prereqs)
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
     └─ kind-control-plane ← the cluster kind builds, a SIBLING container
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
├── docker-compose.yml
├── .env                  ← copy from .env.example; PROXY_ACTIVE/PROXY_HOST/PROXY_PORT + VM_MEMORY/VM_CPUS
├── .env.example
├── config\
│   ├── connect-kind.sh
│   ├── wslconfig.example
│   ├── install-cluster-prereqs.sh
│   ├── environments\local\cert-manager-values.yaml
│   └── pre-scripts\     ← bind-mounted whole; auto-loaded for EVERY user's shell
│       ├── 00-completions.sh   (TAB completion, sourced via /etc/bash.bashrc)
│       ├── 10-proxy.sh         (proxy reachability check, sourced too)
│       └── pxset                (manual `pxset set`/`pxset unset`, run — not sourced)
└── workspace\           ← you create this; your repos (ia-ext-ciam) go here
```

`.env` is gitignored and holds two different kinds of setting, treated
differently on purpose:

- `PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT` are **not** used for `${VAR}`
  substitution in `docker-compose.yml` and never reach `docker build`.
  Instead they're bind-mounted read-only into the container at
  `/etc/ping-linux.env` and read straight off disk by `config\pre-scripts\`
  on every new shell. Edit any time — no rebuild, no `docker compose
  up`/`down`. `PROXY_ACTIVE=true`/`false` is a real string comparison here
  (plain bash, not compose interpolation), so it means exactly what it says.
- `VM_MEMORY`/`VM_CPUS` **are** standard `${VAR}` substitution, consumed by
  `docker-compose.yml`'s `deploy.resources.limits` — they're
  container-creation attributes, so there's no way around needing `docker
  compose up -d` (recreate) after changing them. Keep them at or below what
  you set in `.wslconfig` (see `config\wslconfig.example`).

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
# The scripts themselves (TAB completion, proxy safety net, ...) are
# bind-mounted read-only at runtime from ./config/pre-scripts (see
# docker-compose.yml) — editable without rebuilding the image. This just
# installs the loader into /etc/bash.bashrc, sourced by every interactive
# shell for every user. Only *.sh files are auto-sourced. See MANUAL.md
# section 7b for what ships there.
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
| Ping / ForgeOps | `pingctl`/`pingcli`, `jose` (JWT/JOSE CLI) |
| Languages | `go`, `node` + `npm` + `yarn`, `python3` + `pip` + `venv` |
| Java build | `default-jdk`, `maven` (`mvn`) |
| Build/native | `build-essential`, `make`, `pkg-config` |
| Docker | `docker` CLI + `docker compose` plugin (talks to host daemon) |
| Network/debug | `iproute2`, `ping`, `dig`/`nslookup`, `net-tools`, `netcat`, `telnet`, `traceroute` |
| Shell | `bash-completion` + TAB completion wired for kubectl/helm/kind/kubectx/kubens/gcloud, plus `k` alias |

Verify after build (inside the container):
```bash
kubectl version --client && helm version && kind version
go version && node -v && python3 -V && mvn -v
gcloud version && jose --help >/dev/null && echo "jose ok"
kubens --help >/dev/null && echo "kubens ok"
command -v pingctl && pingctl --version || echo "pingctl optional"
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
      # The helper script, mounted as a command.
      - ./config/connect-kind.sh:/usr/local/bin/connect-kind:ro
      # Manual proxy toggle, mounted as a command: `pxset set` / `pxset unset`.
      - ./config/pre-scripts/pxset:/usr/local/bin/pxset:ro
      # Auto-loaded for every user's shell (TAB completion, proxy safety
      # net) via /etc/bash.bashrc, installed by the Dockerfile. See 7b.
      - ./config/pre-scripts:/etc/profile.d/pre-scripts:ro
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

mkdir -p /root/.kube

# Attach this container to kind's network so 'kind-control-plane' resolves.
docker network connect kind "${CONTAINER}" 2>/dev/null || true

# Write a kubeconfig that targets the in-network API server address.
kind get kubeconfig --name "${CLUSTER}" --internal > /root/.kube/config

echo "kubeconfig written to /root/.kube/config"
echo "Testing connection..."
kubectl get nodes
```

---

<a name="5b-pre-scripts"></a>
## 7b. `config\pre-scripts\` — auto-loaded for every user's shell

The whole `config\pre-scripts\` folder is bind-mounted read-only into the
container at `/etc/profile.d/pre-scripts` (see docker-compose.yml). The
Dockerfile appends a small loader to **`/etc/bash.bashrc`** — the system-wide
bashrc sourced by every interactive shell for every user, not just root's
`~/.bashrc` — that sources every `*.sh` file found there, in sorted order:

```bash
if [ -d /etc/profile.d/pre-scripts ]; then
  for f in /etc/profile.d/pre-scripts/*.sh; do
    [ -f "$f" ] && source "$f"
  done
fi
```

Because it's a bind mount, editing or adding a script under `config\pre-scripts\`
takes effect the next time a shell opens — no image rebuild needed. Number-prefix
new scripts (`00-`, `10-`, `20-`, ...) to control load order.

What ships today:

| File | Sourced automatically? | Purpose |
|------|------------------------|---------|
| `00-completions.sh` | Yes (`.sh`) | TAB completion for kubectl/helm/kind/kubectx/kubens/gcloud/pingcli, plus the `k` alias. |
| `10-proxy.sh` | Yes (`.sh`) | Reads `PROXY_ACTIVE`/`PROXY_HOST`/`PROXY_PORT` fresh from the bind-mounted `/etc/ping-linux.env` on every new shell, and only turns the proxy on if `PROXY_ACTIVE=true` **and** `PROXY_HOST:PROXY_PORT` answers within 1s — so an unreachable proxy (VPN off, wrong network) doesn't silently break every command. |
| `pxset` | **No** (no `.sh` extension — by design) | Also mounted directly to `/usr/local/bin/pxset`, so it's runnable as a command: `source pxset set` / `source pxset unset` (must be sourced, or the exports only affect pxset's own subprocess) to manually toggle `HTTP_PROXY`/`HTTPS_PROXY`/`COMPOSE_HTTP_PROXY`/`COMPOSE_HTTPS_PROXY`. It must NOT be auto-sourced from the loader — it `exit`s when called with no argument, which would kill whatever shell sourced it. |

Both `10-proxy.sh` and `pxset` read `/etc/ping-linux.env` directly — the
bind-mounted copy of your `.env` — not container environment variables. So
editing `.env` on the host takes effect the moment you open a new shell,
with no `docker compose up`/`down` and no rebuild. `PROXY_ACTIVE=true`/`false`
is a genuine string comparison in these scripts (plain bash), not compose
interpolation, so `false` really does mean off.

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
kind create cluster
```
With cgroup v2 this now finishes "Starting control-plane" instead of failing.

### Step 4 — Wire kubectl (fixes localhost:8080)
```bash
connect-kind
```
You should see a node `Ready`. Re-run `connect-kind` any time you recreate the
cluster. (If you ever get a `^M` error, the file was saved CRLF — re-save as LF
on Windows; do not `sed` it in place because it's mounted read-only.)

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

---

<a name="7-troubleshooting"></a>
## 10. Troubleshooting (the exact errors seen)

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Starting control-plane` fails, `Failed to create symlink /sys/fs/cgroup/...` | Docker on cgroup v1 | Step 1: `.wslconfig` → cgroup v2 → `wsl --shutdown` |
| `docker info` still `Cgroup Version: 1` after edit | typo `kelnelCommandLine`, or no `wsl --shutdown` | fix spelling to `kernelCommandLine`, shut down again |
| `kind` gives `syntax error near '<'` / XML | URL typo `lastest` → 404 saved as the binary | use `latest` |
| `connection to the server localhost:8080 refused` | no kubeconfig in container | run `connect-kind` (Step 4) |
| `dial tcp: lookup kind-control-plane ... no such host` | container not on kind's network | `docker network connect kind my-ubuntu-vm` then rewrite kubeconfig |
| `No such container: ubuntu-dev` on network connect | used `hostname`, not the docker name | use `my-ubuntu-vm` (the `container_name`) |
| `sed: cannot rename ... Device or resource busy` | editing a read-only mounted file in place | re-save the source file as LF on Windows instead |
| `no matches for kind "ServiceMonitor"` | Prometheus CRD missing | apply the ServiceMonitor CRD (section 9, step 1) |
| `no matches for kind "Certificate"/"ClusterIssuer"` | cert-manager CRDs missing / wrong order | install cert-manager with `--set crds.enabled=true` first (section 9) |
| helm/kubectl hang through proxy | proxy intercepting cluster traffic | `NO_PROXY` (already in compose) |
| `$env:KUBECONFIG: command not found` | PowerShell syntax used in bash | in bash: `export KUBECONFIG=/root/.kube/config` |
| helm `curl ... githubusercontent.com` fails | incomplete URL | `https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3` |

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
kind create cluster        # make a cluster
connect-kind               # wire kubectl to it
kubectl get nodes          # verify  (k get nodes — alias + TAB completion work)

kubens                     # list namespaces / switch:  kubens ping-ais
kubectx                    # list/switch contexts

gcloud auth login          # (non-local only) authenticate gcloud
pingctl --help             # Ping CLI (if installed)

kind delete cluster        # tear down
```

---

## Appendix — auto-switch the proxy by network reachability

This used to be a manual copy-paste snippet for `/root/.bashrc`. It's now
wired in automatically as `config\pre-scripts\10-proxy.sh` — see
[section 7b](#5b-pre-scripts). Every new shell re-checks whether
`PROXY_HOST:PROXY_PORT` (from `.env`) answers within 1s and exports or unsets
`HTTP_PROXY`/`HTTPS_PROXY` accordingly, automatically, for every user. For a
manual on-demand toggle instead, use `pxset set` / `pxset unset`
(`config\pre-scripts\pxset`, also covered in 7b).
