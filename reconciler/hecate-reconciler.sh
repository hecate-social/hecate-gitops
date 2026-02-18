#!/usr/bin/env bash
# hecate-reconciler — Syncs Quadlet .container files from gitops to systemd
#
# Watches ~/.hecate/gitops/ and symlinks .container files into
# ~/.config/containers/systemd/ where Podman's Quadlet generator picks them up.
#
# Usage:
#   hecate-reconciler --once    # One-shot reconciliation
#   hecate-reconciler --watch   # Continuous watch mode (default)
#   hecate-reconciler --status  # Show current state

set -euo pipefail

# --- Configuration ---
GITOPS_DIR="${HECATE_GITOPS_DIR:-${HOME}/.hecate/gitops}"
QUADLET_DIR="${HOME}/.config/containers/systemd"
LOG_PREFIX="[hecate-reconciler]"

# --- Logging ---
log_info()  { echo "${LOG_PREFIX} INFO  $(date +%H:%M:%S) $*"; }
log_warn()  { echo "${LOG_PREFIX} WARN  $(date +%H:%M:%S) $*" >&2; }
log_error() { echo "${LOG_PREFIX} ERROR $(date +%H:%M:%S) $*" >&2; }

# --- Preflight ---
preflight() {
    if ! command -v podman &>/dev/null; then
        log_error "podman is not installed"
        exit 1
    fi

    if ! command -v systemctl &>/dev/null; then
        log_error "systemctl is not available"
        exit 1
    fi

    if [[ ! -d "${GITOPS_DIR}" ]]; then
        log_error "gitops directory not found: ${GITOPS_DIR}"
        exit 1
    fi

    mkdir -p "${QUADLET_DIR}"
}

# --- Collect desired state ---
# Returns list of .container files from gitops (system/ + apps/)
desired_units() {
    local files=()
    for dir in "${GITOPS_DIR}/system" "${GITOPS_DIR}/apps"; do
        if [[ -d "${dir}" ]]; then
            for f in "${dir}"/*.container; do
                [[ -f "${f}" ]] && files+=("${f}")
            done
        fi
    done
    printf '%s\n' "${files[@]}"
}

# Returns list of .container symlinks currently in the Quadlet directory
# that point back into our gitops dir (we only manage our own symlinks)
actual_units() {
    local files=()
    for f in "${QUADLET_DIR}"/*.container; do
        if [[ -L "${f}" ]]; then
            local target
            target=$(readlink -f "${f}" 2>/dev/null || true)
            if [[ "${target}" == "${GITOPS_DIR}"/* ]]; then
                files+=("${f}")
            fi
        fi
    done
    [[ ${#files[@]} -gt 0 ]] && printf '%s\n' "${files[@]}"
}

# --- Reconcile ---
reconcile() {
    local changed=0

    # Phase 1: Add missing symlinks
    while IFS= read -r src; do
        local name
        name=$(basename "${src}")
        local dest="${QUADLET_DIR}/${name}"

        if [[ -L "${dest}" ]]; then
            local current_target
            current_target=$(readlink -f "${dest}")
            if [[ "${current_target}" == "${src}" ]]; then
                continue  # Already correct
            fi
            log_info "UPDATE ${name} (target changed)"
            rm "${dest}"
        elif [[ -e "${dest}" ]]; then
            log_warn "SKIP ${name} (non-symlink file exists, not managed by us)"
            continue
        else
            log_info "ADD ${name}"
        fi

        ln -s "${src}" "${dest}"
        changed=1
    done < <(desired_units)

    # Phase 2: Remove stale symlinks
    while IFS= read -r dest; do
        local name
        name=$(basename "${dest}")
        local target
        target=$(readlink -f "${dest}")

        if [[ ! -f "${target}" ]]; then
            log_info "REMOVE ${name} (source deleted from gitops)"
            local unit_name="${name%.container}.service"
            systemctl --user stop "${unit_name}" 2>/dev/null || true
            rm "${dest}"
            changed=1
        fi
    done < <(actual_units)

    # Phase 3: Reload if anything changed
    if [[ ${changed} -eq 1 ]]; then
        log_info "Reloading systemd daemon..."
        systemctl --user daemon-reload

        # Start any new units that have [Install] WantedBy=default.target
        while IFS= read -r src; do
            local name
            name=$(basename "${src}")
            local unit_name="${name%.container}.service"

            if ! systemctl --user is-active --quiet "${unit_name}" 2>/dev/null; then
                log_info "Starting ${unit_name}..."
                systemctl --user start "${unit_name}" || log_warn "Failed to start ${unit_name}"
            fi
        done < <(desired_units)

        log_info "Reconciliation complete"
    else
        log_info "No changes detected"
    fi
}

# --- Status ---
show_status() {
    echo "=== Hecate Reconciler Status ==="
    echo ""
    echo "Gitops dir:  ${GITOPS_DIR}"
    echo "Quadlet dir: ${QUADLET_DIR}"
    echo ""

    echo "--- Desired State (gitops) ---"
    while IFS= read -r src; do
        echo "  $(basename "${src}")"
    done < <(desired_units)

    echo ""
    echo "--- Actual State (systemd) ---"
    for f in "${QUADLET_DIR}"/*.container; do
        [[ -f "${f}" || -L "${f}" ]] || continue
        local name
        name=$(basename "${f}")
        local unit_name="${name%.container}.service"
        local status
        status=$(systemctl --user is-active "${unit_name}" 2>/dev/null || echo "inactive")
        local sym=""
        [[ -L "${f}" ]] && sym=" -> $(readlink "${f}")"
        echo "  ${name} [${status}]${sym}"
    done

    echo ""
    echo "--- Managed Symlinks ---"
    while IFS= read -r dest; do
        echo "  $(basename "${dest}") -> $(readlink "${dest}")"
    done < <(actual_units)
}

# --- Watch mode ---
watch_loop() {
    log_info "Watching ${GITOPS_DIR} for changes..."
    log_info "Initial reconciliation..."
    reconcile

    while true; do
        # Wait for filesystem events in the gitops directory
        # -r = recursive, -e = events to watch, --timeout = max wait
        inotifywait -r -q \
            -e create -e delete -e modify -e moved_to -e moved_from \
            --timeout 300 \
            "${GITOPS_DIR}/system" "${GITOPS_DIR}/apps" 2>/dev/null || true

        # Small debounce — multiple events may fire in quick succession
        sleep 1

        log_info "Change detected, reconciling..."
        reconcile
    done
}

# --- Main ---
main() {
    local mode="${1:---watch}"

    case "${mode}" in
        --once)
            preflight
            reconcile
            ;;
        --watch)
            preflight
            watch_loop
            ;;
        --status)
            preflight
            show_status
            ;;
        --help|-h)
            echo "Usage: hecate-reconciler [--once|--watch|--status]"
            echo ""
            echo "  --once    One-shot reconciliation"
            echo "  --watch   Continuous watch mode (default)"
            echo "  --status  Show current state"
            ;;
        *)
            log_error "Unknown option: ${mode}"
            exit 1
            ;;
    esac
}

main "$@"
