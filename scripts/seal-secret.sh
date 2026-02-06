#!/usr/bin/env bash
#
# Seal a secret for the Hecate cluster
# Usage: ./seal-secret.sh <key> <value>
#        ./seal-secret.sh --file <secret.yaml>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITOPS_DIR="$(dirname "$SCRIPT_DIR")"
SEALED_SECRET_FILE="${GITOPS_DIR}/infrastructure/hecate/sealed-secrets.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Check kubeseal is installed
if ! command -v kubeseal &>/dev/null; then
    error "kubeseal not found. Install with: brew install kubeseal (macOS) or download from GitHub"
fi

show_help() {
    cat << EOF
Seal secrets for Hecate

Usage:
  $0 <KEY> <VALUE>           Add/update a single secret
  $0 --file <secret.yaml>    Seal an entire secret file
  $0 --show                  Show current sealed secret structure

Examples:
  $0 ANTHROPIC_API_KEY sk-ant-xxx
  $0 OPENAI_API_KEY sk-xxx
  $0 --file my-secrets.yaml

EOF
}

seal_single_secret() {
    local key="$1"
    local value="$2"

    info "Sealing ${key}..."

    # Create temporary secret
    local tmp_secret
    tmp_secret=$(mktemp)
    cat > "$tmp_secret" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: hecate-secrets
  namespace: hecate
stringData:
  ${key}: "${value}"
EOF

    # Seal it
    local tmp_sealed
    tmp_sealed=$(mktemp)
    kubeseal --format yaml < "$tmp_secret" > "$tmp_sealed"

    # Extract the encrypted value
    local encrypted
    encrypted=$(grep "^    ${key}:" "$tmp_sealed" | sed "s/^    ${key}: //")

    # Clean up
    rm -f "$tmp_secret" "$tmp_sealed"

    if [ -z "$encrypted" ]; then
        error "Failed to seal secret"
    fi

    info "Encrypted value: ${encrypted:0:20}..."
    ok "Add this to ${SEALED_SECRET_FILE} under spec.encryptedData:"
    echo ""
    echo "    ${key}: ${encrypted}"
    echo ""
}

seal_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        error "File not found: $file"
    fi

    info "Sealing ${file}..."
    kubeseal --format yaml < "$file" > "$SEALED_SECRET_FILE"
    ok "Sealed secret written to ${SEALED_SECRET_FILE}"
}

case "${1:-}" in
    --help|-h)
        show_help
        ;;
    --file)
        [ -z "${2:-}" ] && error "Missing file argument"
        seal_file "$2"
        ;;
    --show)
        cat "$SEALED_SECRET_FILE"
        ;;
    "")
        show_help
        ;;
    *)
        [ -z "${2:-}" ] && error "Missing value for key: $1"
        seal_single_secret "$1" "$2"
        ;;
esac
