#!/bin/bash
# Create SealedSecret for Hecate API keys
# Run this on your local machine (needs kubectl access to beam00 cluster)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITOPS_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_FILE="$GITOPS_DIR/infrastructure/hecate/sealed-secrets.yaml"
NAMESPACE="hecate"
SECRET_NAME="hecate-secrets"

echo "=== Seal Hecate API Keys ==="
echo ""

# Check kubeseal is installed
if ! command -v kubeseal &>/dev/null; then
    echo "kubeseal not found. Installing..."
    KUBESEAL_VERSION="0.27.3"
    curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/kubeseal /usr/local/bin/
    echo "Installed kubeseal $(kubeseal --version)"
fi

# Check kubectl access
echo "Checking cluster access..."
if ! kubectl --kubeconfig ~/.kube/beam-clusters/beam00.yaml get nodes &>/dev/null; then
    echo "ERROR: Cannot access beam00 cluster. Check kubeconfig."
    exit 1
fi
echo "Cluster accessible."

# Check sealed-secrets controller is running
echo "Checking sealed-secrets controller..."
if ! kubectl --kubeconfig ~/.kube/beam-clusters/beam00.yaml get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets -o name | grep -q pod; then
    echo "ERROR: sealed-secrets controller not found in kube-system"
    exit 1
fi
echo "Sealed-secrets controller found."

# Check environment variables
echo ""
echo "Reading API keys from environment..."
MISSING=""
[ -z "$ANTHROPIC_API_KEY" ] && MISSING="$MISSING ANTHROPIC_API_KEY"
[ -z "$GEMINI_API_KEY" ] && [ -z "$GOOGLE_API_KEY" ] && MISSING="$MISSING GOOGLE_API_KEY/GEMINI_API_KEY"
[ -z "$GROQ_API_KEY" ] && MISSING="$MISSING GROQ_API_KEY"

if [ -n "$MISSING" ]; then
    echo "ERROR: Missing environment variables:$MISSING"
    echo ""
    echo "Set them first:"
    echo "  export ANTHROPIC_API_KEY='sk-...'"
    echo "  export GOOGLE_API_KEY='...' (or GEMINI_API_KEY)"
    echo "  export GROQ_API_KEY='gsk_...'"
    exit 1
fi

# Use GEMINI_API_KEY if GOOGLE_API_KEY not set
GOOGLE_KEY="${GOOGLE_API_KEY:-$GEMINI_API_KEY}"

echo "  ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY:0:10}..."
echo "  GOOGLE_API_KEY: ${GOOGLE_KEY:0:10}..."
echo "  GROQ_API_KEY: ${GROQ_API_KEY:0:10}..."

# Create the secret YAML (not sealed yet)
echo ""
echo "Creating sealed secret..."

# Create a temporary plain secret
TEMP_SECRET=$(mktemp)
cat > "$TEMP_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $SECRET_NAME
  namespace: $NAMESPACE
type: Opaque
stringData:
  ANTHROPIC_API_KEY: "$ANTHROPIC_API_KEY"
  GOOGLE_API_KEY: "$GOOGLE_KEY"
  GROQ_API_KEY: "$GROQ_API_KEY"
EOF

# Seal it
kubeseal --kubeconfig ~/.kube/beam-clusters/beam00.yaml \
    --controller-name=sealed-secrets-controller \
    --controller-namespace=kube-system \
    --format yaml \
    < "$TEMP_SECRET" \
    > "$OUTPUT_FILE"

# Clean up
rm -f "$TEMP_SECRET"

echo ""
echo "SUCCESS: Created $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Review the file: cat $OUTPUT_FILE"
echo "  2. Commit and push:"
echo "     cd $GITOPS_DIR"
echo "     git add infrastructure/hecate/sealed-secrets.yaml"
echo "     git commit -m 'feat: add sealed API keys for LLM providers'"
echo "     git push"
echo "  3. Flux will automatically unseal and create the secret"
