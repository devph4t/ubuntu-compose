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