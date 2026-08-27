#!/usr/bin/env bash
# fix-and-run.sh
#
# Fixes Windows (CRLF) line endings on the cluster prereqs script and any
# other shell scripts under workspace/ (this repo's own scripts are already
# LF via .gitattributes — see the note below), then runs
# install-cluster-prereqs.sh and the Ping accelerator upgrade.
#
# Usage (inside the container, after `kind create cluster` + `connect-kind`
# + `connect-registry`):
#   bash /root/config/fix-and-run.sh
#
# Usage (from the host, e.g. PowerShell/WSL, from this repo's root):
#   bash config/fix-and-run.sh
#
# Both work unchanged — paths below are resolved from the script's own
# location and from /root/source (this repo's docker-compose.yml bind-mount
# target for workspace/) when that path exists, rather than assuming a
# fixed $(pwd).
set -uo pipefail

# config/ itself ships with LF line endings already, enforced by this
# repo's .gitattributes (`* text=auto eol=lf`) — that only covers files
# tracked in THIS repo, though. workspace/ia-ext-ciam is a separate git
# checkout with its own (or no) line-ending policy, so its shell scripts
# routinely come back CRLF after a Windows-side clone/pull. That's what
# Step 1 below fixes, every run, unconditionally.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
PREREQS_SCRIPT="${SCRIPT_DIR}/install-cluster-prereqs.sh"

if [ -d /root/source ]; then
  WORKSPACE_DIR="/root/source"          # running inside the container
else
  WORKSPACE_DIR="${REPO_DIR}/workspace" # running on the host
fi

IA_CIAM_DIR="${WORKSPACE_DIR}/ia-ext-ciam"
UPGRADE_SCRIPT="${IA_CIAM_DIR}/charts/midships-ping-ais-accelerator/upgrade.sh"

echo "=================================================="
echo " Step 1: Fixing CRLF line endings under workspace/"
echo "=================================================="

if [ ! -f "${PREREQS_SCRIPT}" ]; then
  echo "ERROR: could not find ${PREREQS_SCRIPT}"
  echo "Make sure config/ is intact (run from the repo root on the host, or"
  echo "as /root/config inside the container)."
  exit 1
fi

# Fix CRLF on every .sh file under workspace/ (covers the accelerator's
# upgrade.sh and anything else checked out there on Windows line endings).
if [ -d "${WORKSPACE_DIR}" ]; then
  find "${WORKSPACE_DIR}" -type f -name "*.sh" -print0 | \
  while IFS= read -r -d '' f; do
    if file "$f" | grep -q "CRLF"; then
      echo "  fixing CRLF: $f"
      sed -i 's/\r$//' "$f"
    fi
  done
fi

echo
echo "=================================================="
echo " Step 2: Running install-cluster-prereqs.sh"
echo "=================================================="
# This script uses relative paths like:
#   environments/local/cert-manager-values.yaml
#   ${CHARTS_DIR:-charts}/cert-issuer/
# Both of those only resolve correctly from inside:
#   workspace/ia-ext-ciam/charts/midships-ping-ais-infrastructure
# (that folder has its own environments/local/ and charts/cert-issuer)
INFRA_DIR="${IA_CIAM_DIR}/charts/midships-ping-ais-infrastructure"

if [ ! -d "${INFRA_DIR}" ]; then
  echo "ERROR: could not find ${INFRA_DIR}"
  echo "Check that workspace/ia-ext-ciam is checked out and has this chart folder."
  exit 1
fi

(cd "${INFRA_DIR}" && bash "${PREREQS_SCRIPT}")
PREREQS_STATUS=$?

if [ ${PREREQS_STATUS} -ne 0 ]; then
  echo
  echo "!! install-cluster-prereqs.sh exited with status ${PREREQS_STATUS}."
  echo "!! Fix the error above before continuing to the accelerator install."
  exit ${PREREQS_STATUS}
fi

echo
echo "=================================================="
echo " Step 3: Running midships-ping-ais-accelerator upgrade"
echo "=================================================="

if [ ! -f "${UPGRADE_SCRIPT}" ]; then
  echo "NOTE: ${UPGRADE_SCRIPT} not found — skipping this step."
  echo "Run it yourself once ia-ext-ciam is checked out at the expected path, e.g.:"
  echo "  cd ${IA_CIAM_DIR}"
  echo "  ./charts/midships-ping-ais-accelerator/upgrade.sh --all --environment-name local --rollout --pui-enabled true"
  exit 0
fi

cd "${IA_CIAM_DIR}"
./charts/midships-ping-ais-accelerator/upgrade.sh --all --environment-name local --rollout --pui-enabled true

echo
echo "=================================================="
echo " Done."
echo "=================================================="
