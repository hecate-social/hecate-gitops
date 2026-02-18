#!/usr/bin/env bash
# install-reconciler.sh — Installs the hecate-reconciler on this machine
#
# Copies the reconciler script to ~/.local/bin/ and installs the systemd user service.
#
# Usage:
#   ./install-reconciler.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
GITOPS_DIR="${HOME}/.hecate/gitops"

echo "=== Installing Hecate Reconciler ==="

# 1. Create directories
mkdir -p "${BIN_DIR}"
mkdir -p "${SYSTEMD_USER_DIR}"
mkdir -p "${GITOPS_DIR}/system"
mkdir -p "${GITOPS_DIR}/apps"
mkdir -p "${HOME}/.config/containers/systemd"

# 2. Install the reconciler script
cp "${SCRIPT_DIR}/hecate-reconciler.sh" "${BIN_DIR}/hecate-reconciler"
chmod +x "${BIN_DIR}/hecate-reconciler"
echo "  Installed: ${BIN_DIR}/hecate-reconciler"

# 3. Install the systemd service
cp "${SCRIPT_DIR}/hecate-reconciler.service" "${SYSTEMD_USER_DIR}/hecate-reconciler.service"
echo "  Installed: ${SYSTEMD_USER_DIR}/hecate-reconciler.service"

# 4. Reload systemd and enable the service
systemctl --user daemon-reload
systemctl --user enable hecate-reconciler.service
echo "  Enabled: hecate-reconciler.service"

# 5. Seed gitops directory with Quadlet files if empty
if [[ ! -f "${GITOPS_DIR}/system/hecate-daemon.container" ]]; then
    QUADLET_DIR="${SCRIPT_DIR}/../quadlet"
    if [[ -d "${QUADLET_DIR}" ]]; then
        echo "  Seeding gitops directory with Quadlet files..."
        cp "${QUADLET_DIR}/system/"* "${GITOPS_DIR}/system/" 2>/dev/null || true
        # Note: apps/ are NOT seeded by default — installed on demand
        echo "  Seeded: ${GITOPS_DIR}/system/"
    fi
fi

# 6. Start the reconciler
systemctl --user start hecate-reconciler.service
echo "  Started: hecate-reconciler.service"

echo ""
echo "=== Done ==="
echo ""
echo "The reconciler is now watching ${GITOPS_DIR}"
echo "To install a plugin, copy its .container file to ${GITOPS_DIR}/apps/"
echo ""
echo "Useful commands:"
echo "  hecate-reconciler --status          # Show current state"
echo "  hecate-reconciler --once            # Manual reconciliation"
echo "  journalctl --user -u hecate-reconciler -f  # View logs"
