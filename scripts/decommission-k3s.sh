#!/usr/bin/env bash
# decommission-k3s.sh — Removes k3s from the beam cluster after migration to podman
#
# Run this script from your LOCAL machine (host00) after all beam nodes
# have been migrated to podman using migrate-beam-to-podman.sh.
#
# Usage:
#   ./scripts/decommission-k3s.sh
#
# What it does:
#   1. Verifies all beam nodes have podman running
#   2. Extracts API key secrets from k3s (hecate-secrets)
#   3. Distributes API keys to each node's env file
#   4. Deletes k3s workloads gracefully
#   5. Uninstalls k3s from all nodes (server + agents) via SSH
#   6. Cleans up k3s artifacts (/fast/k3s-data, kubeconfigs)
#   7. Removes k3s-agent from host00 (local machine)
#
# Prerequisites:
#   - SSH access to all beam nodes (ssh rl@beamXX.lab)
#   - kubectl access to beam00 (kubeconfig at ~/.kube/beam-clusters/beam00.yaml)
#   - All beam nodes already migrated to podman

set -euo pipefail

# --- Configuration ---
BEAM_SERVER="beam00.lab"
BEAM_AGENTS=("beam01.lab" "beam02.lab" "beam03.lab")
ALL_BEAM_NODES=("${BEAM_SERVER}" "${BEAM_AGENTS[@]}")
KUBECONFIG_DIR="${HOME}/.kube/beam-clusters"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/beam00.yaml"
HECATE_NS="hecate"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[decommission]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[decommission]${NC} $*" >&2; }
log_error() { echo -e "${RED}[decommission]${NC} $*" >&2; }
log_step()  { echo -e "${CYAN}[decommission]${NC} === $* ==="; }

# --- Preflight ---
preflight() {
    log_step "Preflight checks"

    # Check SSH access to all beam nodes
    for node in "${ALL_BEAM_NODES[@]}"; do
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "rl@${node}" true 2>/dev/null; then
            log_error "Cannot SSH to rl@${node}"
            log_error "Ensure SSH key access is configured"
            exit 1
        fi
        log_info "SSH OK: ${node}"
    done

    # Check kubectl access
    if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
        log_error "Kubeconfig not found: ${KUBECONFIG_FILE}"
        exit 1
    fi

    if ! kubectl --kubeconfig "${KUBECONFIG_FILE}" cluster-info &>/dev/null; then
        log_warn "k3s cluster may be unhealthy (expected if already partially decommissioned)"
    else
        log_info "kubectl access OK"
    fi
}

# --- Step 1: Verify podman is running on all beam nodes ---
verify_podman() {
    log_step "Verifying podman migration on all nodes"

    local all_ok=true
    for node in "${ALL_BEAM_NODES[@]}"; do
        local podman_status
        podman_status=$(ssh "rl@${node}" "command -v podman &>/dev/null && echo 'installed' || echo 'missing'" 2>/dev/null)

        local reconciler_status
        reconciler_status=$(ssh "rl@${node}" "systemctl --user is-active hecate-reconciler 2>/dev/null || echo 'inactive'" 2>/dev/null)

        local daemon_status
        daemon_status=$(ssh "rl@${node}" "systemctl --user is-active hecate-daemon 2>/dev/null || echo 'inactive'" 2>/dev/null)

        log_info "${node}: podman=${podman_status} reconciler=${reconciler_status} daemon=${daemon_status}"

        if [[ "${podman_status}" != "installed" ]]; then
            log_error "${node}: podman not installed! Run migrate-beam-to-podman.sh first."
            all_ok=false
        fi

        if [[ "${reconciler_status}" != "active" ]]; then
            log_warn "${node}: reconciler not active"
        fi
    done

    if [[ "${all_ok}" != "true" ]]; then
        log_error "Not all nodes are ready. Migrate them first."
        exit 1
    fi
}

# --- Step 2: Extract secrets from k3s ---
extract_secrets() {
    log_step "Extracting secrets from k3s"

    local secrets_file="/tmp/hecate-api-keys.env"

    # Try to get the hecate-secrets from k3s
    if ! kubectl --kubeconfig "${KUBECONFIG_FILE}" get secret hecate-secrets -n "${HECATE_NS}" &>/dev/null; then
        log_warn "hecate-secrets not found in k3s (may already be extracted)"
        log_warn "Skipping secret extraction"
        return 0
    fi

    log_info "Decoding hecate-secrets..."

    # Extract each key
    local anthropic_key google_key groq_key

    anthropic_key=$(kubectl --kubeconfig "${KUBECONFIG_FILE}" get secret hecate-secrets -n "${HECATE_NS}" \
        -o jsonpath='{.data.ANTHROPIC_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    google_key=$(kubectl --kubeconfig "${KUBECONFIG_FILE}" get secret hecate-secrets -n "${HECATE_NS}" \
        -o jsonpath='{.data.GOOGLE_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    groq_key=$(kubectl --kubeconfig "${KUBECONFIG_FILE}" get secret hecate-secrets -n "${HECATE_NS}" \
        -o jsonpath='{.data.GROQ_API_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    # Write to temp file
    {
        echo "# Hecate API Keys — extracted from k3s hecate-secrets"
        echo "# Generated: $(date -Iseconds)"
        [[ -n "${anthropic_key}" ]] && echo "ANTHROPIC_API_KEY=${anthropic_key}"
        [[ -n "${google_key}" ]] && echo "GOOGLE_API_KEY=${google_key}"
        [[ -n "${groq_key}" ]] && echo "GROQ_API_KEY=${groq_key}"
    } > "${secrets_file}"

    chmod 600 "${secrets_file}"

    local key_count=0
    [[ -n "${anthropic_key}" ]] && key_count=$((key_count + 1))
    [[ -n "${google_key}" ]] && key_count=$((key_count + 1))
    [[ -n "${groq_key}" ]] && key_count=$((key_count + 1))

    log_info "Extracted ${key_count} API key(s)"

    # Distribute to each beam node
    for node in "${ALL_BEAM_NODES[@]}"; do
        log_info "Distributing API keys to ${node}..."

        # Copy secrets file
        scp -q "${secrets_file}" "rl@${node}:/tmp/hecate-api-keys.env"

        # Move to secrets dir and append to daemon env
        ssh "rl@${node}" bash << 'REMOTE_EOF'
            mkdir -p ~/.hecate/secrets
            mv /tmp/hecate-api-keys.env ~/.hecate/secrets/api-keys.env
            chmod 600 ~/.hecate/secrets/api-keys.env

            # Append API keys to hecate-daemon.env if not already present
            ENV_FILE="${HOME}/.hecate/gitops/system/hecate-daemon.env"
            if [[ -f "${ENV_FILE}" ]]; then
                # Add keys that aren't already in the env file
                while IFS='=' read -r key value; do
                    [[ "${key}" =~ ^#.*$ ]] && continue
                    [[ -z "${key}" ]] && continue
                    if ! grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
                        echo "${key}=${value}" >> "${ENV_FILE}"
                    fi
                done < ~/.hecate/secrets/api-keys.env
            fi
REMOTE_EOF

        log_info "  ${node}: secrets installed"
    done

    # Clean up local temp file
    rm -f "${secrets_file}"
    log_info "API keys distributed to all nodes"
}

# --- Step 3: Delete k3s workloads ---
delete_workloads() {
    log_step "Deleting k3s workloads"

    if ! kubectl --kubeconfig "${KUBECONFIG_FILE}" cluster-info &>/dev/null; then
        log_warn "k3s cluster not reachable, skipping workload deletion"
        return 0
    fi

    # Delete hecate namespace (contains daemon, secrets, configmaps)
    log_info "Deleting hecate namespace..."
    kubectl --kubeconfig "${KUBECONFIG_FILE}" delete ns "${HECATE_NS}" \
        --timeout=30s --ignore-not-found 2>/dev/null || log_warn "hecate ns deletion timed out (will be cleaned by k3s uninstall)"

    # Delete other dead namespaces
    for ns in macula external-dns macula-arcade; do
        log_info "Deleting namespace: ${ns}..."
        kubectl --kubeconfig "${KUBECONFIG_FILE}" delete ns "${ns}" \
            --timeout=15s --ignore-not-found 2>/dev/null || log_warn "${ns} deletion timed out"
    done

    log_info "Workload cleanup complete"
}

# --- Step 4: Uninstall k3s ---
uninstall_k3s() {
    log_step "Uninstalling k3s from all nodes"

    # Uninstall agents first (workers)
    for node in "${BEAM_AGENTS[@]}"; do
        log_info "Uninstalling k3s-agent from ${node}..."

        ssh "rl@${node}" bash << 'REMOTE_EOF'
            if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
                sudo /usr/local/bin/k3s-agent-uninstall.sh
                echo "k3s-agent uninstalled"
            else
                echo "k3s-agent uninstall script not found (already removed?)"
            fi
REMOTE_EOF

        log_info "  ${node}: k3s-agent removed"
    done

    # Uninstall server (control plane) last
    log_info "Uninstalling k3s server from ${BEAM_SERVER}..."

    ssh "rl@${BEAM_SERVER}" bash << 'REMOTE_EOF'
        if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
            sudo /usr/local/bin/k3s-uninstall.sh
            echo "k3s server uninstalled"
        else
            echo "k3s uninstall script not found (already removed?)"
        fi
REMOTE_EOF

    log_info "  ${BEAM_SERVER}: k3s server removed"
}

# --- Step 5: Clean up k3s artifacts ---
cleanup_artifacts() {
    log_step "Cleaning up k3s artifacts"

    # Clean up on each beam node
    for node in "${ALL_BEAM_NODES[@]}"; do
        log_info "Cleaning artifacts on ${node}..."

        ssh "rl@${node}" bash << 'REMOTE_EOF'
            # Remove k3s data symlink and directory
            if [[ -L /var/lib/rancher/k3s ]] || [[ -d /var/lib/rancher/k3s ]]; then
                sudo rm -rf /var/lib/rancher/k3s
                echo "  Removed /var/lib/rancher/k3s"
            fi

            # Remove k3s data on /fast
            if [[ -d /fast/k3s-data ]]; then
                sudo rm -rf /fast/k3s-data
                echo "  Removed /fast/k3s-data"
            fi

            # Remove stale kubeconfig
            if [[ -f ~/.hecate/kubeconfig ]]; then
                rm -f ~/.hecate/kubeconfig
                echo "  Removed ~/.hecate/kubeconfig"
            fi

            # Remove /var/lib/rancher if empty
            if [[ -d /var/lib/rancher ]] && [[ -z "$(ls -A /var/lib/rancher 2>/dev/null)" ]]; then
                sudo rmdir /var/lib/rancher
                echo "  Removed empty /var/lib/rancher"
            fi
REMOTE_EOF
    done

    # Clean up local kubeconfig files
    log_info "Cleaning local kubeconfig files..."
    if [[ -d "${KUBECONFIG_DIR}" ]]; then
        rm -rf "${KUBECONFIG_DIR}"
        log_info "  Removed ${KUBECONFIG_DIR}"
    fi
}

# --- Step 6: Remove k3s-agent from host00 (local) ---
remove_local_k3s_agent() {
    log_step "Removing k3s-agent from local machine (host00)"

    if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        log_info "Uninstalling k3s-agent..."
        sudo /usr/local/bin/k3s-agent-uninstall.sh
        log_info "k3s-agent uninstalled from host00"
    else
        log_info "k3s-agent not installed on host00 (or already removed)"
    fi
}

# --- Step 7: Verify decommission ---
verify_decommission() {
    log_step "Verifying decommission"

    echo ""

    # Check k3s is gone from all beam nodes
    for node in "${ALL_BEAM_NODES[@]}"; do
        local k3s_status
        k3s_status=$(ssh "rl@${node}" "systemctl is-active k3s k3s-agent 2>/dev/null || echo 'removed'" 2>/dev/null)
        log_info "${node}: k3s=${k3s_status}"
    done

    echo ""

    # Check podman services running
    for node in "${ALL_BEAM_NODES[@]}"; do
        local daemon_status
        daemon_status=$(ssh "rl@${node}" "systemctl --user is-active hecate-daemon 2>/dev/null || echo 'inactive'" 2>/dev/null)
        log_info "${node}: hecate-daemon=${daemon_status}"
    done

    echo ""

    # Check local k3s-agent
    if systemctl is-active k3s-agent &>/dev/null; then
        log_warn "host00: k3s-agent still active"
    else
        log_info "host00: k3s-agent removed"
    fi

    echo ""

    # Check local kubeconfigs
    if [[ -d "${KUBECONFIG_DIR}" ]]; then
        log_warn "Local kubeconfig dir still exists: ${KUBECONFIG_DIR}"
    else
        log_info "Local kubeconfigs cleaned up"
    fi
}

# --- Main ---
main() {
    echo ""
    echo "============================================"
    echo "  Hecate: Decommission k3s from beam cluster"
    echo "  Date: $(date -Iseconds)"
    echo "============================================"
    echo ""

    log_warn "This will PERMANENTLY remove k3s from all beam nodes!"
    log_warn "Make sure all nodes are migrated to podman first."
    echo ""
    read -rp "Continue? (y/N) " confirm
    if [[ "${confirm}" != "y" && "${confirm}" != "Y" ]]; then
        log_info "Aborted."
        exit 0
    fi
    echo ""

    preflight
    verify_podman
    extract_secrets
    delete_workloads
    uninstall_k3s
    cleanup_artifacts
    remove_local_k3s_agent
    verify_decommission

    echo ""
    log_info "Decommission complete!"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Verify all daemons are healthy: for n in beam0{0..3}; do ssh rl@\${n}.lab 'systemctl --user status hecate-daemon'; done"
    log_info "  2. Restart daemons to pick up API keys: for n in beam0{0..3}; do ssh rl@\${n}.lab 'systemctl --user restart hecate-daemon'; done"
    log_info "  3. Clean up hecate-gitops repo (delete k8s dirs, update README)"
    echo ""
}

main "$@"
