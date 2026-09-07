#!/usr/bin/env bash

set -euo pipefail

ENVIRONMENT="production"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_OWNER="Sebastian-Nowaczyk-Elektrorecykling"
REPO_NAME="flux-manual"

K3S_VERSION="${K3S_VERSION:-}"
CILIUM_VERSION="1.20.1"
GATEWAY_API_VERSION="1.6.1"

usage() {
    echo "Usage: $0 -o <owner> -r <repo> [-e <environment>] [-t <github_token>]"
    echo "  -e Target environment (default: production)"
    echo "  -t GitHub Personal Access Token (or export GITHUB_TOKEN)"
    echo "  -o GitHub owner/organization"
    echo "  -r Target pre-created repository name"
    exit 1
}

while getopts "e:t:o:r:h" opt; do
    case "${opt}" in
        e) ENVIRONMENT="${OPTARG}" ;;
        t) GITHUB_TOKEN="${OPTARG}" ;;
        o) GITHUB_OWNER="${OPTARG}" ;;
        r) REPO_NAME="${OPTARG}" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${GITHUB_TOKEN}" || -z "${GITHUB_OWNER}" || -z "${REPO_NAME}" || -z "${ENVIRONMENT}" ]]; then
    echo "Error: Missing required parameters." >&2
    usage
fi

export GITHUB_TOKEN

echo "==> Installing Longhorn prerequisites"
sudo apt-get update
sudo apt-get install -y open-iscsi util-linux

echo "==> Installing k3s"

K3S_ENV=()
if [[ -n "${K3S_VERSION}" ]]; then
    K3S_ENV+=("INSTALL_K3S_VERSION=${K3S_VERSION}")
fi

curl -sfL https://get.k3s.io | \
    env "${K3S_ENV[@]}" \
    INSTALL_K3S_EXEC="server \
        --flannel-backend=none \
        --disable-network-policy \
        --disable-kube-proxy \
        --disable=traefik \
        --disable=servicelb" \
    sh -

mkdir -p "${HOME}/.kube"

sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 600 "${HOME}/.kube/config"

export KUBECONFIG="${HOME}/.kube/config"

echo "==> Waiting for Kubernetes API"
until kubectl get nodes >/dev/null 2>&1; do
    sleep 2
done

echo "==> Installing Gateway API ${GATEWAY_API_VERSION} experimental CRDs"

kubectl apply --server-side \
    -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v${GATEWAY_API_VERSION}/experimental-install.yaml"

echo "==> Installing Cilium ${CILIUM_VERSION}"

helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade --install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set gatewayAPI.enabled=true \
    --set gatewayAPI.hostNetwork.enabled=true \
    --set prometheus.enabled=true \
    --set operator.prometheus.enabled=true \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hubble.metrics.enableOpenMetrics=true \
    --set 'hubble.metrics.enabled={dns:query;ignoreAAAA,drop,tcp,flow,icmp,httpV2}'

echo "==> Waiting for Cilium"

kubectl rollout status daemonset/cilium \
    --namespace kube-system \
    --timeout=5m

kubectl rollout status deployment/cilium-operator \
    --namespace kube-system \
    --timeout=5m

echo "==> Bootstrapping FluxCD..."
echo "    Environment: ${ENVIRONMENT}"
echo "    Target Repo: ${GITHUB_OWNER}/${REPO_NAME}"
echo "    Cluster Path: clusters/${ENVIRONMENT}"

flux bootstrap github \
    --owner="${GITHUB_OWNER}" \
    --repository="${REPO_NAME}" \
    --branch="main" \
    --path="clusters/${ENVIRONMENT}" \
    --personal
