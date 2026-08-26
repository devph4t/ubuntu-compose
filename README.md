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
copy .env.example .env    # set PROXY_ACTIVE=true + PROXY_HOST/PROXY_PORT, or false to disable
docker compose build
docker compose up -d
docker compose exec ubuntu-dev bash
```

Inside the container:

```bash
kind create cluster
connect-kind          # wires kubectl to the cluster (fixes localhost:8080 refused)
kubectl get nodes
```

`.wslconfig` also needs to be copied from [config/wslconfig.example](config/wslconfig.example)
to `C:\Users\<you>\.wslconfig` — see MANUAL.md section 3 for why (cgroup v2).

## Layout

```
.
├── Dockerfile             base image: docker/kubectl/helm/kind/go/node/python/gcloud/pingcli
├── docker-compose.yml     the "VM" container + bind mounts
├── .env                   gitignored — your proxy settings (see below)
├── .env.example           template for .env
└── config\
    ├── connect-kind.sh              wires kubectl to a freshly created kind cluster (run: `connect-kind`)
    ├── install-cluster-prereqs.sh   ServiceMonitor CRD + cert-manager + cert-issuer + accelerator
    ├── wslconfig.example             template for C:\Users\<you>\.wslconfig
    ├── environments\local\cert-manager-values.yaml
    └── pre-scripts\
        └── pxset   manual proxy toggle (run: `source pxset set` / `source pxset unset`)
```

TAB completion and the proxy reachability check run automatically on every
shell too, but they're baked directly into the Dockerfile's
`/etc/bash.bashrc` (not bind-mounted) — `config\pre-scripts\` is reserved
for commands you invoke explicitly, like `pxset` and `connect-kind`.

## Sharing the image

The image is fully self-contained: every CLI, TAB completion, and the
`connect-kind`/`pxset` commands are baked in at build time (not left
depending on this repo's `config\` folder being present). Export it and
hand it to another PC with no repo checkout required:

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

## Daily commands

```powershell
docker compose up -d                     # start the VM
docker compose exec ubuntu-dev bash      # enter it
docker compose down                      # stop it (kube volume persists)
```

See MANUAL.md's [cheat sheet](MANUAL.md#9-cheatsheet) and
[troubleshooting table](MANUAL.md#7-troubleshooting) for everything else.
