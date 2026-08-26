#!/usr/bin/env bash
# =====================================================================
#  Run this INSIDE the container, after `kind create cluster` and
#  `connect-kind`, before deploying the Ping charts.
#  See MANUAL.md section 9 ("Cluster prerequisites for the Ping charts").
#
#  Installs, once per cluster and in order:
#    1. Prometheus-Operator ServiceMonitor CRD
#    2. cert-manager (with its CRDs)
#    3. cert-issuer chart
#    4. the midships-ping-ais-accelerator upgrade
#
#  Usage:
#    ENV_NAME=local ./install-cluster-prereqs.sh
# =====================================================================
set -euo pipefail

ENV_NAME="${ENV_NAME:-local}"
CHARTS_DIR="${CHARTS_DIR:-charts}"
ACCELERATOR_DIR="${ACCELERATOR_DIR:-./charts/midships-ping-ais-accelerator}"
CERT_MANAGER_VALUES="${CERT_MANAGER_VALUES:-environments/${ENV_NAME}/cert-manager-values.yaml}"

echo ">> [1/4] Prometheus-Operator ServiceMonitor CRD"
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
kubectl get crd servicemonitors.monitoring.coreos.com

echo ">> [2/4] cert-manager (with CRDs)"
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set prometheus.servicemonitor.enabled=false \
  --values "${CERT_MANAGER_VALUES}"

echo ">> waiting for cert-manager rollout"
kubectl -n cert-manager rollout status deploy/cert-manager
kubectl -n cert-manager rollout status deploy/cert-manager-webhook

echo ">> [3/4] cert-issuer"
helm upgrade --install cert-issuer "${CHARTS_DIR}/cert-issuer/" --namespace cert-manager

echo ">> [4/4] midships-ping-ais-accelerator"
"${ACCELERATOR_DIR}/upgrade.sh" \
  --all --environment-name "${ENV_NAME}" --rollout --pui-enabled true

echo ">> done. (GCP_SERVICE_KEY length: 0 in the accelerator output is expected for 'local'.)"
