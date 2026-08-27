#!/usr/bin/env bash
# =====================================================================
#  Run this INSIDE the container, right after:
#    kind create cluster --config config/kind-config.yaml
#    connect-kind
#
#  Wires the kind-registry sibling container (from docker-compose.yml's
#  `registry` service) onto kind's docker network and tells the cluster
#  where to find it, so `docker push localhost:5000/name:tag` + a normal
#  image pull replaces `kind load docker-image` — see config/kind-config.yaml
#  for why that matters on large images.
#
#  Idempotent — safe to re-run any time (e.g. after `kind delete cluster`
#  + recreate).
#
#  Usage:  connect-registry            (default cluster "kind")
#          connect-registry mycluster  (custom name)
# =====================================================================
set -euo pipefail

CLUSTER="${1:-kind}"
REGISTRY_CONTAINER="kind-registry"   # docker container_name from docker-compose.yml
REGISTRY_HOST_PORT="5000"

# Join kind's network so nodes can resolve "kind-registry" — matches how
# connect-kind.sh attaches this dev container to the same network.
docker network connect kind "${REGISTRY_CONTAINER}" 2>/dev/null || true

# Advertise the mapping cluster-wide (the containerd mirror patch in
# kind-config.yaml makes the *pulls* work; this ConfigMap is what tells
# registry-aware tooling — e.g. some CI/build helpers — that
# localhost:5000 inside the cluster is this registry). See:
# https://kind.sigs.k8s.io/docs/user/local-registry/
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_HOST_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "kind-registry connected to network 'kind' and advertised to cluster '${CLUSTER}'."
echo "Push images with:  docker push localhost:${REGISTRY_HOST_PORT}/<name>:<tag>"
echo "Reference them as: localhost:${REGISTRY_HOST_PORT}/<name>:<tag>"
