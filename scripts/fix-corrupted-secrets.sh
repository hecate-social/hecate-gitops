#!/bin/bash
# Fix k3s cluster after secrets encryption corrupted existing secrets
# Run this on beam00.lab as root: sudo ./fix-corrupted-secrets.sh

set -e

echo "=== K3s Secrets Corruption Fix ==="
echo ""

# Check we're running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Must run as root (sudo)"
    exit 1
fi

# Check we're on the right machine
if ! systemctl is-active --quiet k3s; then
    echo "ERROR: k3s service not found. Run this on beam00.lab"
    exit 1
fi

DB_PATH="/fast/k3s-data/server/db/state.db"
CRED_PATH="/fast/k3s-data/server/cred"

if [ ! -f "$DB_PATH" ]; then
    echo "ERROR: k3s database not found at $DB_PATH"
    exit 1
fi

echo "Step 1: Stop k3s..."
systemctl stop k3s
sleep 3

echo ""
echo "Step 2: List corrupted secrets..."
CORRUPTED=$(sqlite3 "$DB_PATH" "SELECT name FROM kine WHERE name LIKE '/registry/secrets/%'" | grep -E 'hecate-secrets|external-dns-pdns' || true)

if [ -z "$CORRUPTED" ]; then
    echo "No known corrupted secrets found."
else
    echo "Found corrupted secrets:"
    echo "$CORRUPTED"
    echo ""
    echo "Step 3: Deleting corrupted secrets from database..."
    sqlite3 "$DB_PATH" "DELETE FROM kine WHERE name = '/registry/secrets/hecate/hecate-secrets'"
    sqlite3 "$DB_PATH" "DELETE FROM kine WHERE name = '/registry/secrets/external-dns/external-dns-pdns'"
    echo "Deleted."
fi

echo ""
echo "Step 4: Remove encryption config..."
if [ -f "$CRED_PATH/encryption-config.json" ]; then
    mv "$CRED_PATH/encryption-config.json" "$CRED_PATH/encryption-config.json.disabled"
    echo "Moved encryption-config.json to .disabled"
fi
if [ -f "$CRED_PATH/encryption-state.json" ]; then
    mv "$CRED_PATH/encryption-state.json" "$CRED_PATH/encryption-state.json.disabled"
    echo "Moved encryption-state.json to .disabled"
fi

echo ""
echo "Step 5: Start k3s..."
systemctl start k3s

echo ""
echo "Step 6: Wait for API server..."
sleep 10
for i in {1..30}; do
    if kubectl get nodes &>/dev/null; then
        echo "API server ready!"
        break
    fi
    echo "  Waiting... ($i/30)"
    sleep 2
done

echo ""
echo "Step 7: Verify cluster health..."
kubectl get nodes
echo ""
kubectl get pods -A | head -20

echo ""
echo "Step 8: Check secrets are readable..."
if kubectl get secrets -A &>/dev/null; then
    echo "SUCCESS: Secrets are now readable"
    kubectl get secrets -A
else
    echo "WARNING: Secrets still have issues. Check manually."
fi

echo ""
echo "=== Fix complete ==="
echo ""
echo "Next steps:"
echo "1. Recreate any deleted secrets using SealedSecrets"
echo "2. Run: flux reconcile kustomization hecate-infrastructure"
