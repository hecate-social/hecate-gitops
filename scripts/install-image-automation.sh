#!/bin/bash
#
# Install Flux Image Automation Controllers
#
# This script installs the image-reflector-controller and image-automation-controller
# which are required for automatic image updates.
#
# Usage: ./install-image-automation.sh [KUBECONFIG]
#
set -euo pipefail

KUBECONFIG="${1:-$HOME/.kube/beam-clusters/beam00.yaml}"
export KUBECONFIG

echo "=== Installing Flux Image Automation Controllers ==="
echo "Using kubeconfig: $KUBECONFIG"

# Check flux CLI is available
if ! command -v flux &> /dev/null; then
    echo "Error: flux CLI not found. Install with: curl -s https://fluxcd.io/install.sh | sudo bash"
    exit 1
fi

# Check cluster connection
if ! kubectl cluster-info &> /dev/null; then
    echo "Error: Cannot connect to cluster"
    exit 1
fi

echo "Cluster: $(kubectl config current-context)"

# Install the image automation components
echo ""
echo "Installing image-reflector-controller and image-automation-controller..."
flux install \
    --components-extra=image-reflector-controller,image-automation-controller \
    --export | kubectl apply -f -

echo ""
echo "Waiting for controllers to be ready..."
kubectl -n flux-system wait deployment/image-reflector-controller --for=condition=available --timeout=60s
kubectl -n flux-system wait deployment/image-automation-controller --for=condition=available --timeout=60s

echo ""
echo "=== Image Automation Controllers Installed ==="
kubectl get deployments -n flux-system

echo ""
echo "Next steps:"
echo "1. Push the gitops changes: cd hecate-gitops && git add -A && git commit -m 'feat: add image automation' && git push"
echo "2. Flux will reconcile and create ImageRepository, ImagePolicy, ImageUpdateAutomation"
echo "3. When new images are pushed to ghcr.io, Flux will auto-update the daemonset"
