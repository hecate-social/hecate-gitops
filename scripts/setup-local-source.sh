#!/bin/bash
# Setup local git source for Flux to watch user apps
#
# This creates a bare git repo on the k3s control-plane node
# and adds it as a remote to the local gitops clone.
#
# Usage: ./setup-local-source.sh [KUBECONFIG]
set -euo pipefail

KUBECONFIG="${1:-$HOME/.kube/beam-clusters/beam00.yaml}"
export KUBECONFIG

GITOPS_DIR="$HOME/.hecate/gitops"
BARE_REPO_PATH="/var/lib/hecate/repos/hecate-gitops.git"
CONTROL_NODE="beam00.lab"

echo "=== Setup Local Git Source for Flux ==="

# Step 1: Ensure the gitops clone exists
if [ ! -d "$GITOPS_DIR/.git" ]; then
    echo "Cloning hecate-gitops to $GITOPS_DIR..."
    git clone https://github.com/hecate-social/hecate-gitops.git "$GITOPS_DIR"
else
    echo "GitOps clone found at $GITOPS_DIR"
fi

# Step 2: Create bare repo on control-plane node
echo ""
echo "Creating bare repo on $CONTROL_NODE..."
ssh "rl@$CONTROL_NODE" "sudo mkdir -p $(dirname $BARE_REPO_PATH) && \
    sudo git init --bare $BARE_REPO_PATH && \
    sudo chown -R rl:rl $BARE_REPO_PATH" 2>/dev/null || {
    echo "ERROR: Could not SSH to $CONTROL_NODE"
    echo "Create the bare repo manually:"
    echo "  ssh rl@$CONTROL_NODE"
    echo "  sudo mkdir -p $(dirname $BARE_REPO_PATH)"
    echo "  sudo git init --bare $BARE_REPO_PATH"
    echo "  sudo chown -R rl:rl $BARE_REPO_PATH"
    exit 1
}

# Step 3: Add local remote
echo ""
echo "Adding 'local' remote..."
cd "$GITOPS_DIR"
git remote remove local 2>/dev/null || true
git remote add local "ssh://rl@$CONTROL_NODE$BARE_REPO_PATH"

# Step 4: Push to local
echo "Pushing to local..."
git push local main

echo ""
echo "=== Local Source Ready ==="
echo ""
echo "Workflow:"
echo "  cd $GITOPS_DIR"
echo "  # Edit files in apps/"
echo "  git add -A && git commit -m 'update'"
echo "  git push local main"
echo "  # Flux picks up changes in ~30s"
