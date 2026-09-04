#!/usr/bin/env bash
set -euo pipefail

# Default values
ENVIRONMENT="production"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
GITHUB_OWNER="Sebastian-Nowaczyk-Elektrorecykling"
REPO_NAME="flux-manual"

usage() {
  echo "Usage: $0 -o <owner> -r <repo> [-e <environment>] [-t <github_token>]"
  echo "  -e  Target environment (default: production)"
  echo "  -t  GitHub Personal Access Token (or export GITHUB_TOKEN)"
  echo "  -o  GitHub owner/organization"
  echo "  -r  Target pre-created repository name"
  exit 1
}

# Parse command line flags
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

# Validate required inputs
if [[ -z "${GITHUB_TOKEN}" || -z "${GITHUB_OWNER}" || -z "${REPO_NAME}" || -z "${ENVIRONMENT}" ]]; then
  echo "Error: Missing required parameters." >&2
  usage
fi

export GITHUB_TOKEN

# Install longhorn prerequisites
echo "==> Installing Longhorn prerequisites"
sudo apt install open-iscsi util-linux -y

# Get k3s without network bits
echo "==> Installing k3s"
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--flannel-backend=none --disable-network-policy" sh -
mkdir -p ~/.kube || true
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
export KUBECONFIG=~/.kube/config

# Install Cilium
echo "==> Installing Cilium"
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=true


echo "==> Bootstrapping FluxCD..."
echo "    Environment:  ${ENVIRONMENT}"
echo "    Target Repo:  ${GITHUB_OWNER}/${REPO_NAME}"
echo "    Cluster Path: clusters/${ENVIRONMENT}"

# Bootstrap FluxCD
flux bootstrap github \
  --owner="${GITHUB_OWNER}" \
  --repository="${REPO_NAME}" \
  --branch="main" \
  --path="clusters/${ENVIRONMENT}" \
  --personal
