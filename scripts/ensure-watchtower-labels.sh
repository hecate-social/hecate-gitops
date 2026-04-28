#!/usr/bin/env bash
# ensure-watchtower-labels.sh
#
# Watchtower's WATCHTOWER_LABEL_ENABLE=true mode only auto-updates
# containers carrying com.centurylinklabs.watchtower.enable=true on
# their image. Containers created BEFORE the compose file added the
# label keep running without it even after a `docker compose up
# --build` rolls a new image — Watchtower silently skips them and
# the host drifts behind ghcr.io's :latest tag.
#
# This script:
#   1. lists every running container missing the label,
#   2. emits the compose-up command to recreate them with the label,
#   3. (optional --apply) executes that command in-place.
#
# Run on every box that hosts Hecate containers (beam00-03, host00).
#
# Usage:
#   ./ensure-watchtower-labels.sh           # dry-run, just lists offenders
#   ./ensure-watchtower-labels.sh --apply   # recreates the affected
#                                           #   containers via compose

set -euo pipefail

DOCKER="${DOCKER:-docker}"
COMPOSE_FILE="${COMPOSE_FILE:-${HOME}/.hecate/compose/docker-compose.yml}"
LABEL="com.centurylinklabs.watchtower.enable"
APPLY="false"

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY="true" ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | sed -e '$d'
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 1
            ;;
    esac
done

echo "scanning containers without ${LABEL}=true..."

offenders=$($DOCKER ps --format '{{.Names}}' | while read -r name; do
    val=$($DOCKER inspect --format "{{ index .Config.Labels \"${LABEL}\" }}" "$name" 2>/dev/null || true)
    if [[ "$val" != "true" ]]; then
        echo "$name"
    fi
done)

if [[ -z "$offenders" ]]; then
    echo "all running containers carry the label. nothing to do."
    exit 0
fi

echo
echo "containers MISSING ${LABEL}=true:"
echo "$offenders" | sed 's/^/  - /'

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo
    echo "compose file not found at ${COMPOSE_FILE} — set COMPOSE_FILE env var" >&2
    exit 1
fi

echo
echo "to remediate, recreate the affected services from the compose file."
echo "the compose file (${COMPOSE_FILE}) MUST already declare the label"
echo "for each service:"
echo
echo "    labels:"
echo "      - \"${LABEL}=true\""
echo
echo "command:"
echo "  ${DOCKER} compose -f ${COMPOSE_FILE} up -d --force-recreate"

if [[ "$APPLY" == "true" ]]; then
    echo
    echo "--apply set; running compose now..."
    ${DOCKER} compose -f "${COMPOSE_FILE}" up -d --force-recreate
    echo "done. re-running scan to verify..."
    "$0"
else
    echo
    echo "(dry-run; pass --apply to execute)"
fi
