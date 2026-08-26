#!/usr/bin/env bash
# Shell aliases + TAB completion (kubectl/helm/kind/kubectx/kubens/gcloud/pingcli).
# Auto-loaded for every interactive shell, every user — see /etc/bash.bashrc's
# pre-scripts loader (installed by the Dockerfile) and MANUAL.md section 7b.
source /usr/share/bash-completion/bash_completion 2>/dev/null || true
alias k=kubectl
source <(kubectl completion bash) 2>/dev/null || true
complete -o default -F __start_kubectl k 2>/dev/null || true
source <(helm completion bash) 2>/dev/null || true
source <(kind completion bash) 2>/dev/null || true
source /opt/kubectx/completion/kubectx.bash 2>/dev/null || true
source /opt/kubectx/completion/kubens.bash 2>/dev/null || true
command -v pingcli >/dev/null 2>&1 && source <(pingcli completion bash) 2>/dev/null || true
[ -f /root/google-cloud-sdk/completion.bash.inc ] && source /root/google-cloud-sdk/completion.bash.inc
