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