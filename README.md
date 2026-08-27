# Ubuntu 26.04 "VM" on Windows — Docker + kubectl + helm + kind

A no-administrator Ubuntu dev environment for the ForgeOps / PingOne Advanced
Identity Cloud toolchain. Runs as a Docker container (not a WSL distro) that
talks to the host's Docker daemon, so `kind` can spin up Kubernetes clusters
as sibling containers.

For the full walkthrough (why this setup exists, troubleshooting, the k3d
fallback, cluster prerequisites for the Ping charts, daily cheat sheet), see
**[MANUAL.md](MANUAL.md)**.

## Quick start

```powershell
mkdir workspace
copy .env.example .env    # set PROXY_ACTIVE=true + PROXY_HOST/PROXY_PORT, or false to disable; TZ defaults to Asia/Bangkok
docker compose build
docker compose up -d
docker compose exec ubuntu-dev bash
```

Inside the container:

```bash
kind create cluster --config /root/config/kind-config.yaml
connect-kind          # wires kubectl to the cluster (fixes localhost:8080 refused)
connect-registry       # wires the local image registry into the cluster
kubectl get nodes
```

Build/push images for the cluster through the local registry instead of
`kind load docker-image` (which stalls on large images — see
[below](#local-image-registry-fast-kind-image-loads)):

```bash
docker build -t myapp:dev .
kind-push myapp:dev                    # tags + pushes as localhost:5000/myapp:dev
# reference localhost:5000/myapp:dev in your pod/values
```

`.wslconfig` also needs to be copied from [config/wslconfig.example](config/wslconfig.example)
to `C:\Users\<you>\.wslconfig` — see MANUAL.md section 3 for why (cgroup v2).

## Layout

```
.
├── Dockerfile             base image: docker/kubectl/helm/kind/go/node/python/gcloud/pingcli
├── docker-compose.yml     the "VM" container + local registry + bind mounts
├── .env                   gitignored — your proxy/timezone/resource settings (see below)
├── .env.example           template for .env
└── config\
    ├── connect-kind.sh              wires kubectl to a freshly created kind cluster (run: `connect-kind`)
    ├── connect-registry.sh          wires the local registry into the cluster (run: `connect-registry`)
    ├── kind-config.yaml              kind cluster config — pulls images through the local registry
    ├── fix-and-run.sh                fixes CRLF under workspace/ + runs install-cluster-prereqs.sh + the accelerator upgrade
    ├── install-cluster-prereqs.sh   ServiceMonitor CRD + cert-manager + cert-issuer + accelerator
    ├── wslconfig.example             template for C:\Users\<you>\.wslconfig
    ├── environments\local\cert-manager-values.yaml
    └── pre-scripts\
        ├── pxset       manual proxy toggle (run: `source pxset set` / `source pxset unset`)
        └── kind-push   tags + pushes an image to the local registry (run: `kind-push myapp:dev`)
```

The whole `config\` folder is also bind-mounted read-only at `/root/config`
inside the container, so `install-cluster-prereqs.sh`, `kind-config.yaml`,
`environments\`, and `fix-and-run.sh` are all reachable at a stable path
regardless of where `workspace\` puts your other repos.

TAB completion and the proxy reachability check run automatically on every
shell too, but they're baked directly into the Dockerfile's
`/etc/bash.bashrc` (not bind-mounted) — `config\pre-scripts\` is reserved
for commands you invoke explicitly, like `pxset` and `connect-kind`.

## Cluster prerequisites (one-shot)

Once the cluster exists and `connect-kind`/`connect-registry` have run, use
`fix-and-run.sh` instead of the manual steps in MANUAL.md section 9 — it
fixes any CRLF line endings under `workspace\` (a recurring problem for
scripts checked out on Windows, e.g. `ia-ext-ciam`'s accelerator
`upgrade.sh`), then runs `install-cluster-prereqs.sh` and the accelerator
upgrade:

```bash
bash /root/config/fix-and-run.sh
```

## Local image registry (fast kind image loads)

`kind load docker-image` pipes a `docker save` tar through a single-threaded
import into the node container — on a large image this can look "frozen"
even though `docker stats` shows the kind node's CPU pegged, because that
CPU time is one core doing tar/gzip work, not something more cores or a
higher `VM_CPUS` fixes (that limit is on `ubuntu-dev`, not the sibling kind
node containers anyway).

Instead, this repo runs a local registry (`docker-compose.yml`'s `registry`
service, `kind-registry:5000`) and wires the cluster's containerd to pull
from it (`config/kind-config.yaml`). That turns image delivery into a normal
layered, streamed, parallel registry pull — the actual fix, not a tuned-up
version of the slow path:

```bash
kind create cluster --config /root/config/kind-config.yaml   # once, at cluster creation
connect-registry                                              # once per cluster, after connect-kind

docker build -t myapp:dev .
kind-push myapp:dev            # tags + pushes to localhost:5000/myapp:dev
# reference localhost:5000/myapp:dev in your pod/values — no `kind load` step
```

## Sharing the image

The image is fully self-contained: every CLI, TAB completion, and the
`connect-kind`/`connect-registry`/`pxset`/`kind-push` commands are baked in
at build time (not left depending on this repo's `config\` folder being
present) — including the Thailand-time default (see Timezone below).
Export it and hand it to another PC with no repo checkout required:

```powershell
docker save my_wsl_ubuntu:26.04 -o my_wsl_ubuntu_26.04.tar
docker save -o "my_wsl_ubuntu_26.04_$(Get-Date -Format 'yyyyMMdd_HHmmss').tar" my_wsl_ubuntu:26.04
docker save my_wsl_ubuntu:26.04 | wsl gzip > "my_wsl_ubuntu_26.04_$(Get-Date -Format 'yyyyMMdd_HHmmss').tar.gz"
docker save my_wsl_ubuntu:26.04 | gzip > "my_wsl_ubuntu_26.04_$(date +%Y%m%d_%H%M%S).tar.gz"
# on the other PC:
docker load -i my_wsl_ubuntu_26.04.tar
```

`.env` (proxy settings) and the `workspace`/`kube-config` mounts are
deliberately left out of the image — they're host-specific data, not
tooling. See [MANUAL.md section 7c](MANUAL.md#5c-portable-image) for the
full standalone `docker run` command and what you get with vs. without the
rest of the repo.

## Proxy configuration

Edit `.env` (`PROXY_ACTIVE`, `PROXY_HOST`, `PROXY_PORT`) any time — it's
bind-mounted straight into the running container and read fresh by the
Dockerfile's baked-in proxy check on every new shell. It never affects the
image build and never requires `docker compose up`/`down` to take effect.

## Timezone

`.env`'s `TZ` (default `Asia/Bangkok`) sets the container's clock, same as
`VM_MEMORY`/`VM_CPUS` — it's read at container creation, so a change needs
`docker compose up -d` (recreate), not just a new shell. The image also
bakes `Asia/Bangkok` into its own `tzdata` config at build time, so a
standalone/shared copy of the image (no `.env` mounted) still defaults to
Thailand time.

## Daily commands

```powershell
docker compose up -d                     # start the VM
docker compose exec ubuntu-dev bash      # enter it
docker compose down                      # stop it (kube volume persists)
```

See MANUAL.md's [cheat sheet](MANUAL.md#9-cheatsheet) and
[troubleshooting table](MANUAL.md#7-troubleshooting) for everything else.
