#!/usr/bin/env bash
# migrate-beam-to-podman.sh — Migrates a beam cluster node from k3s to systemd + podman
#
# Run this script ON each beam node (via SSH) as the `rl` user.
# It requires sudo for installing podman and enabling lingering.
#
# Usage:
#   ssh rl@beam01.lab 'bash -s' < scripts/migrate-beam-to-podman.sh
#
# Or copy to node and run:
#   scp scripts/migrate-beam-to-podman.sh rl@beam01.lab:/tmp/
#   ssh rl@beam01.lab 'bash /tmp/migrate-beam-to-podman.sh'
#
# What it does:
#   1. Installs podman + inotify-tools (Ubuntu 20.04 via kubic repo)
#   2. Enables systemd lingering for the rl user
#   3. Creates the ~/.hecate/ directory layout
#   4. Clones hecate-gitops, seeds Quadlet files to ~/.hecate/gitops/
#   5. Installs the hecate-reconciler (script + systemd service)
#   6. Runs initial reconciliation (starts hecate-daemon via podman)
#   7. Waits for daemon socket to confirm it's running
#
# What it does NOT do:
#   - Uninstall k3s (use decommission-k3s.sh for that, after verifying all nodes)
#   - Install the hecate CLI (download separately from GitHub releases)

set -euo pipefail

# --- Configuration ---
HECATE_GITOPS_REPO="https://github.com/hecate-social/hecate-gitops.git"
HECATE_HOME="${HOME}/.hecate"
GITOPS_DIR="${HECATE_HOME}/gitops"
DAEMON_DIR="${HECATE_HOME}/hecate-daemon"
SOCKET_PATH="${DAEMON_DIR}/sockets/api.sock"
QUADLET_DIR="${HOME}/.config/containers/systemd"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
BIN_DIR="${HOME}/.local/bin"
WAIT_TIMEOUT=60

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[migrate]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[migrate]${NC} $*" >&2; }
log_error() { echo -e "${RED}[migrate]${NC} $*" >&2; }

# --- Preflight checks ---
preflight() {
    log_info "Running preflight checks..."

    if [[ "$(id -u)" -eq 0 ]]; then
        log_error "Do not run this script as root. Run as the 'rl' user."
        log_error "Sudo will be requested for specific operations."
        exit 1
    fi

    if [[ "$(whoami)" != "rl" ]]; then
        log_warn "Expected user 'rl', running as '$(whoami)'"
    fi

    if ! command -v sudo &>/dev/null; then
        log_error "sudo is required"
        exit 1
    fi

    # Detect OS
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        log_info "Detected OS: ${PRETTY_NAME:-${ID} ${VERSION_ID}}"
    else
        log_warn "Could not detect OS version"
    fi
}

# --- Step 1: Install podman ---
install_podman() {
    if command -v podman &>/dev/null; then
        log_info "Podman already installed: $(podman --version)"
        return 0
    fi

    log_info "Installing podman..."

    # Detect distro and install accordingly
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    fi

    case "${ID:-unknown}" in
        ubuntu)
            local version_id="${VERSION_ID:-20.04}"
            log_info "Adding kubic repository for Ubuntu ${version_id}..."

            # Add kubic repo for podman (Ubuntu 20.04 doesn't have podman in default repos)
            sudo mkdir -p /etc/apt/keyrings
            local kubic_url="https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/xUbuntu_${version_id}"

            curl -fsSL "${kubic_url}/Release.key" \
                | gpg --dearmor \
                | sudo tee /etc/apt/keyrings/devel_kubic_libcontainers_stable.gpg > /dev/null

            echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/devel_kubic_libcontainers_stable.gpg] ${kubic_url}/ /" \
                | sudo tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list > /dev/null

            sudo apt-get update -qq
            sudo apt-get install -y -qq podman inotify-tools
            ;;
        arch|manjaro)
            sudo pacman -S --noconfirm --needed podman inotify-tools
            ;;
        *)
            log_error "Unsupported distro: ${ID:-unknown}"
            log_error "Install podman and inotify-tools manually, then re-run."
            exit 1
            ;;
    esac

    log_info "Podman installed: $(podman --version)"
}

# --- Step 2: Enable lingering ---
enable_lingering() {
    local user
    user="$(whoami)"

    if loginctl show-user "${user}" --property=Linger 2>/dev/null | grep -q "Linger=yes"; then
        log_info "Lingering already enabled for ${user}"
        return 0
    fi

    log_info "Enabling lingering for ${user}..."
    sudo loginctl enable-linger "${user}"
    log_info "Lingering enabled"
}

# --- Step 3: Create directory layout ---
create_directories() {
    log_info "Creating ~/.hecate/ directory layout..."

    local dirs=(
        "${HECATE_HOME}"
        "${GITOPS_DIR}/system"
        "${GITOPS_DIR}/apps"
        "${DAEMON_DIR}/sqlite"
        "${DAEMON_DIR}/reckon-db"
        "${DAEMON_DIR}/sockets"
        "${DAEMON_DIR}/run"
        "${DAEMON_DIR}/connectors"
        "${HECATE_HOME}/secrets"
        "${HECATE_HOME}/config"
        "${QUADLET_DIR}"
        "${SYSTEMD_USER_DIR}"
        "${BIN_DIR}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "${dir}"
    done

    log_info "Directory layout created"
}

# --- Step 4: Seed Quadlet files from gitops repo ---
seed_quadlet_files() {
    log_info "Seeding Quadlet files from hecate-gitops..."

    local tmp_clone="/tmp/hecate-gitops-clone"

    # Clone to temp if needed
    if [[ -d "${tmp_clone}" ]]; then
        log_info "Updating existing clone..."
        git -C "${tmp_clone}" pull --quiet 2>/dev/null || {
            rm -rf "${tmp_clone}"
            git clone --quiet --depth 1 "${HECATE_GITOPS_REPO}" "${tmp_clone}"
        }
    else
        git clone --quiet --depth 1 "${HECATE_GITOPS_REPO}" "${tmp_clone}"
    fi

    # Copy system Quadlet files (core daemon)
    if [[ -d "${tmp_clone}/quadlet/system" ]]; then
        cp "${tmp_clone}/quadlet/system/"* "${GITOPS_DIR}/system/"
        log_info "Seeded system Quadlet files"
    fi

    # Copy reconciler files
    if [[ -d "${tmp_clone}/reconciler" ]]; then
        # Install reconciler script
        cp "${tmp_clone}/reconciler/hecate-reconciler.sh" "${BIN_DIR}/hecate-reconciler"
        chmod +x "${BIN_DIR}/hecate-reconciler"
        log_info "Installed reconciler to ${BIN_DIR}/hecate-reconciler"

        # Install systemd service
        cp "${tmp_clone}/reconciler/hecate-reconciler.service" "${SYSTEMD_USER_DIR}/hecate-reconciler.service"
        log_info "Installed reconciler service"
    fi

    # Clean up clone
    rm -rf "${tmp_clone}"
}

# --- Step 5: Apply node-specific overrides ---
apply_node_overrides() {
    local hostname
    hostname="$(hostname -s)"

    log_info "Applying node-specific overrides for ${hostname}..."

    # Determine RAM and CPU from system
    local ram_gb
    ram_gb=$(awk '/MemTotal/ { printf "%d", $2/1024/1024 }' /proc/meminfo)
    local cpu_cores
    cpu_cores=$(nproc)

    # Create node.env with hardware overrides
    cat > "${HECATE_HOME}/config/node.env" << EOF
# Node-specific overrides for ${hostname}
# Auto-generated by migrate-beam-to-podman.sh

HECATE_NODE_NAME=hecate@${hostname}
HECATE_RAM_GB=${ram_gb}
HECATE_CPU_CORES=${cpu_cores}
HECATE_GPU=none
HECATE_GPU_VRAM_GB=0
EOF

    log_info "Node overrides written to ${HECATE_HOME}/config/node.env"
    log_info "  RAM: ${ram_gb}GB, CPU: ${cpu_cores} cores"
}

# --- Step 6: Generate systemd service files ---
# Podman 3.x doesn't support Quadlet (.container files).
# We generate equivalent .service files that call `podman run` directly.
generate_service_files() {
    log_info "Generating systemd service files from Quadlet specs..."

    local podman_major
    podman_major=$(podman --version | awk '{print $3}' | cut -d. -f1)

    if [[ "${podman_major}" -ge 4 ]]; then
        log_info "Podman ${podman_major}.x detected — Quadlet supported, skipping service generation"
        return 0
    fi

    log_info "Podman ${podman_major}.x detected — no Quadlet support, generating .service files"

    # Read image and env from the gitops .container and .env files
    local container_file="${GITOPS_DIR}/system/hecate-daemon.container"
    local env_file="${GITOPS_DIR}/system/hecate-daemon.env"

    if [[ ! -f "${container_file}" ]]; then
        log_error "Container spec not found: ${container_file}"
        exit 1
    fi

    # Extract image from .container file
    local image
    image=$(grep '^Image=' "${container_file}" | cut -d= -f2-)

    if [[ -z "${image}" ]]; then
        log_error "Could not extract Image from ${container_file}"
        exit 1
    fi

    log_info "  Image: ${image}"

    # Generate hecate-daemon.service
    cat > "${SYSTEMD_USER_DIR}/hecate-daemon.service" << EOF
[Unit]
Description=Hecate Daemon (core) — podman container
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
TimeoutStartSec=90s
TimeoutStopSec=30s

# Pull image if not present
ExecStartPre=-/usr/bin/podman pull ${image}
# Remove any existing container
ExecStartPre=-/usr/bin/podman rm -f hecate-daemon

ExecStart=/usr/bin/podman run \\
  --rm \\
  --name hecate-daemon \\
  --network host \\
  --volume %h/.hecate/hecate-daemon:/home/rl/.hecate/hecate-daemon:Z \\
  --env-file %h/.hecate/gitops/system/hecate-daemon.env \\
  ${image}

ExecStop=/usr/bin/podman stop -t 10 hecate-daemon

[Install]
WantedBy=default.target
EOF

    log_info "Generated ${SYSTEMD_USER_DIR}/hecate-daemon.service"
}

# --- Step 7: Start services ---
start_services() {
    log_info "Starting hecate services..."

    # Reload systemd to pick up new service files
    systemctl --user daemon-reload

    # Enable and start the reconciler
    systemctl --user enable hecate-reconciler.service
    systemctl --user start hecate-reconciler.service
    log_info "Reconciler started"

    # Enable and start the daemon
    systemctl --user enable hecate-daemon.service
    systemctl --user start hecate-daemon.service
    log_info "Daemon service started"
}

# --- Step 7: Wait for daemon ---
wait_for_daemon() {
    log_info "Waiting for hecate-daemon to start (timeout: ${WAIT_TIMEOUT}s)..."

    local elapsed=0
    while [[ ${elapsed} -lt ${WAIT_TIMEOUT} ]]; do
        if [[ -S "${SOCKET_PATH}" ]]; then
            log_info "Daemon socket detected at ${SOCKET_PATH}"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        if (( elapsed % 10 == 0 )); then
            log_info "  Still waiting... (${elapsed}s)"
        fi
    done

    log_warn "Daemon socket not found after ${WAIT_TIMEOUT}s"
    log_warn "Check logs: journalctl --user -u hecate-daemon -n 50"
    log_warn "Check reconciler: journalctl --user -u hecate-reconciler -n 20"
    return 1
}

# --- Step 8: Clean up stale files ---
cleanup_stale_files() {
    log_info "Cleaning up stale files..."

    local stale_files=(
        "${HECATE_HOME}/docker-compose.yml"
        "${HECATE_HOME}/docker-compose.yaml"
        "${HECATE_HOME}/SKILLS.md"
        "${HECATE_HOME}/kubeconfig"
    )

    for f in "${stale_files[@]}"; do
        if [[ -f "${f}" ]]; then
            rm "${f}"
            log_info "  Removed stale file: ${f}"
        fi
    done
}

# --- Step 9: Verify ---
verify() {
    log_info "=== Migration Verification ==="

    echo ""
    echo "  Podman:     $(podman --version 2>/dev/null || echo 'NOT INSTALLED')"
    echo "  Lingering:  $(loginctl show-user "$(whoami)" --property=Linger 2>/dev/null || echo 'unknown')"
    echo ""

    echo "  Reconciler: $(systemctl --user is-active hecate-reconciler 2>/dev/null || echo 'inactive')"
    echo "  Daemon:     $(systemctl --user is-active hecate-daemon 2>/dev/null || echo 'inactive')"
    echo ""

    echo "  Socket:     $(test -S "${SOCKET_PATH}" && echo 'present' || echo 'absent')"
    echo ""

    echo "  Quadlet symlinks:"
    for f in "${QUADLET_DIR}"/*.container; do
        [[ -e "${f}" ]] || continue
        if [[ -L "${f}" ]]; then
            echo "    $(basename "${f}") -> $(readlink "${f}")"
        fi
    done

    echo ""

    # Check if k3s is still running (expected at this point)
    if systemctl is-active k3s &>/dev/null || systemctl is-active k3s-agent &>/dev/null; then
        log_warn "k3s is still running (expected — use decommission-k3s.sh to remove it later)"
    fi
}

# --- Main ---
main() {
    echo ""
    echo "============================================"
    echo "  Hecate: Migrate beam node to podman"
    echo "  Host: $(hostname -f 2>/dev/null || hostname)"
    echo "  Date: $(date -Iseconds)"
    echo "============================================"
    echo ""

    preflight
    install_podman
    enable_lingering
    create_directories
    seed_quadlet_files
    apply_node_overrides
    generate_service_files
    start_services
    wait_for_daemon || true
    cleanup_stale_files
    verify

    echo ""
    log_info "Migration complete!"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Verify daemon is healthy"
    log_info "  2. Migrate remaining nodes"
    log_info "  3. Run decommission-k3s.sh to remove k3s"
    echo ""
}

main "$@"
