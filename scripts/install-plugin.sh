#!/usr/bin/env bash
# install-plugin.sh — Install a hecate plugin on the local node
#
# Simulates the marketplace install flow:
#   1. Copy quadlet files from gitops repo to ~/.hecate/gitops/apps/
#   2. Symlink to systemd quadlet directory
#   3. Pull OCI images
#   4. Reload systemd and start services
#   5. Wait for health check
#
# Usage:
#   ./scripts/install-plugin.sh trader        # Install trader plugin
#   ./scripts/install-plugin.sh trader --dry   # Dry run (show what would happen)

set -euo pipefail

GITOPS_REPO="$(cd "$(dirname "$0")/.." && pwd)"
HECATE_DIR="${HOME}/.hecate"
GITOPS_DIR="${HECATE_DIR}/gitops/apps"
SYSTEMD_DIR="${HOME}/.config/containers/systemd"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_step()  { echo -e "${BLUE}[install]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[install]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[install]${NC} $*" >&2; }
log_error() { echo -e "${RED}[install]${NC} $*" >&2; }

usage() {
    echo "Usage: $0 <plugin-name> [--dry]"
    echo ""
    echo "Available plugins:"
    for f in "${GITOPS_REPO}/quadlet/apps/"*.container; do
        name=$(basename "${f}" .container | sed 's/^hecate-//')
        echo "  - ${name}"
    done
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

PLUGIN="$1"
DRY_RUN=false
if [[ "${2:-}" == "--dry" ]]; then
    DRY_RUN=true
fi

# Resolve component names
# A plugin may have: daemon (*d) + frontend (*w) + env
QUADLET_DIR="${GITOPS_REPO}/quadlet/apps"
COMPONENTS=()
ENV_FILES=()

for suffix in d w; do
    container_file="${QUADLET_DIR}/hecate-${PLUGIN}${suffix}.container"
    if [[ -f "${container_file}" ]]; then
        COMPONENTS+=("hecate-${PLUGIN}${suffix}")
    fi
done

for comp in "${COMPONENTS[@]}"; do
    env_file="${QUADLET_DIR}/${comp}.env"
    if [[ -f "${env_file}" ]]; then
        ENV_FILES+=("${comp}.env")
    fi
done

if [[ ${#COMPONENTS[@]} -eq 0 ]]; then
    log_error "No quadlet files found for plugin '${PLUGIN}'"
    log_error "Looked in: ${QUADLET_DIR}/"
    exit 1
fi

echo -e "${BLUE}=== Installing plugin: ${PLUGIN} ===${NC}"
echo "Components: ${COMPONENTS[*]}"
echo "Quadlet source: ${QUADLET_DIR}/"
echo "Target: ${GITOPS_DIR}/"
echo ""

if ${DRY_RUN}; then
    log_warn "DRY RUN — no changes will be made"
    echo ""
fi

# --- Step 1: Create directories ---
log_step "Creating directories..."
if ! ${DRY_RUN}; then
    mkdir -p "${GITOPS_DIR}"
    mkdir -p "${SYSTEMD_DIR}"
fi

# --- Step 2: Copy quadlet files ---
log_step "Copying quadlet files to ${GITOPS_DIR}/..."
for comp in "${COMPONENTS[@]}"; do
    src="${QUADLET_DIR}/${comp}.container"
    dst="${GITOPS_DIR}/${comp}.container"
    if ${DRY_RUN}; then
        echo "  cp ${src} -> ${dst}"
    else
        cp "${src}" "${dst}"
        log_ok "  ${comp}.container"
    fi
done

for env in "${ENV_FILES[@]}"; do
    src="${QUADLET_DIR}/${env}"
    dst="${GITOPS_DIR}/${env}"
    if ${DRY_RUN}; then
        echo "  cp ${src} -> ${dst}"
    else
        cp "${src}" "${dst}"
        log_ok "  ${env}"
    fi
done

# --- Step 3: Symlink to systemd ---
log_step "Symlinking to ${SYSTEMD_DIR}/..."
for comp in "${COMPONENTS[@]}"; do
    src="${GITOPS_DIR}/${comp}.container"
    dst="${SYSTEMD_DIR}/${comp}.container"
    if ${DRY_RUN}; then
        echo "  ln -sf ${src} -> ${dst}"
    else
        ln -sf "${src}" "${dst}"
        log_ok "  ${comp}.container -> systemd"
    fi
done

# --- Step 4: Pull images ---
log_step "Pulling OCI images..."
for comp in "${COMPONENTS[@]}"; do
    container_file="${QUADLET_DIR}/${comp}.container"
    image=$(grep '^Image=' "${container_file}" | cut -d= -f2)
    if [[ -n "${image}" ]]; then
        if ${DRY_RUN}; then
            echo "  podman pull ${image}"
        else
            log_step "  Pulling ${image}..."
            if podman pull "${image}" 2>&1 | tail -1; then
                log_ok "  ${image}"
            else
                log_error "  Failed to pull ${image}"
                exit 1
            fi
        fi
    fi
done

# --- Step 5: Reload systemd ---
log_step "Reloading systemd..."
if ! ${DRY_RUN}; then
    systemctl --user daemon-reload
    log_ok "systemd reloaded"
fi

# --- Step 6: Start services ---
log_step "Starting services..."
for comp in "${COMPONENTS[@]}"; do
    if ${DRY_RUN}; then
        echo "  systemctl --user start ${comp}"
    else
        log_step "  Starting ${comp}..."
        systemctl --user start "${comp}" 2>&1 || true
        sleep 2
        status=$(systemctl --user is-active "${comp}" 2>/dev/null || echo "unknown")
        if [[ "${status}" == "active" ]]; then
            log_ok "  ${comp}: active"
        else
            log_warn "  ${comp}: ${status}"
        fi
    fi
done

# --- Step 7: Wait for health ---
# Check daemon socket if present
for comp in "${COMPONENTS[@]}"; do
    if [[ "${comp}" == *d ]]; then
        plugin_name="${comp#hecate-}"
        socket_path="${HECATE_DIR}/${comp}/sockets/api.sock"
        log_step "Waiting for socket: ${socket_path}..."

        if ${DRY_RUN}; then
            echo "  (would wait up to 30s for socket)"
            continue
        fi

        for i in $(seq 1 30); do
            if [[ -S "${socket_path}" ]]; then
                log_ok "Socket appeared after ${i}s"
                # Hit health endpoint
                health=$(curl -sf -m 2 --unix-socket "${socket_path}" http://localhost/health 2>/dev/null || echo "")
                if [[ -n "${health}" ]]; then
                    log_ok "Health: ${health}"
                fi
                break
            fi
            sleep 1
        done

        if [[ ! -S "${socket_path}" ]]; then
            log_warn "Socket did not appear after 30s"
            log_warn "Check logs: journalctl --user -u ${comp} -n 50"
        fi
    fi
done

echo ""
echo -e "${GREEN}=== Plugin '${PLUGIN}' installed ===${NC}"
echo ""
echo "Useful commands:"
for comp in "${COMPONENTS[@]}"; do
    echo "  systemctl --user status ${comp}"
done
echo "  journalctl --user -u hecate-${PLUGIN}d -f"
