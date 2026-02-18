#!/usr/bin/env bash
# remove-docker-from-beam.sh — Removes Docker CE from all beam nodes
#
# Run this script from your LOCAL machine after k3s is decommissioned
# and all stale Docker containers have been stopped/removed.
#
# Usage:
#   ./scripts/remove-docker-from-beam.sh

set -euo pipefail

BEAM_NODES=("beam00.lab" "beam01.lab" "beam02.lab" "beam03.lab")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[remove-docker]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[remove-docker]${NC} $*" >&2; }
log_error() { echo -e "${RED}[remove-docker]${NC} $*" >&2; }

for node in "${BEAM_NODES[@]}"; do
    log_info "=== ${node} ==="

    # Check for running containers first
    running=$(ssh "rl@${node}" 'sudo docker ps -q 2>/dev/null | wc -l' 2>/dev/null)
    if [[ "${running}" -gt 0 ]]; then
        log_error "${node}: ${running} containers still running — skipping"
        continue
    fi

    log_info "${node}: Stopping Docker service..."
    ssh "rl@${node}" bash << 'REMOTE_EOF'
        set -euo pipefail

        # Stop Docker
        sudo systemctl stop docker.socket docker.service 2>/dev/null || true
        sudo systemctl disable docker.socket docker.service 2>/dev/null || true

        # Remove Docker packages
        sudo apt-get purge -y -qq \
            docker-ce \
            docker-ce-cli \
            docker-ce-rootless-extras \
            docker-buildx-plugin \
            docker-compose-plugin \
            containerd.io 2>/dev/null || true

        # Clean up Docker data
        sudo rm -rf /var/lib/docker
        sudo rm -rf /var/lib/containerd
        sudo rm -rf /etc/docker

        # Remove Docker apt repo
        sudo rm -f /etc/apt/sources.list.d/docker.list
        sudo rm -f /etc/apt/keyrings/docker.asc

        # Remove Docker group (if empty)
        if getent group docker >/dev/null 2>&1; then
            sudo groupdel docker 2>/dev/null || true
        fi

        # Clean up networks left behind
        for iface in docker0 br-*; do
            sudo ip link delete "${iface}" 2>/dev/null || true
        done

        echo "Docker removed"
REMOTE_EOF

    log_info "${node}: done"
    echo ""
done

log_info "Docker removed from all beam nodes"
