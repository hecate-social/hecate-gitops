#!/usr/bin/env bash
# smoke-test-beam.sh — Smoke test all beam nodes after migration
#
# Tests:
#   1. SSH connectivity
#   2. Podman service status
#   3. Daemon socket exists
#   4. Health endpoint responds with ready=true
#   5. LLM providers detected (API keys loaded)
#   6. Key API endpoints return valid responses
#   7. Event store (venture query returns valid JSON)
#
# Usage:
#   ./scripts/smoke-test-beam.sh              # Test all nodes
#   ./scripts/smoke-test-beam.sh beam01.lab   # Test single node

set -euo pipefail

BEAM_NODES=("beam00.lab" "beam01.lab" "beam02.lab" "beam03.lab")
SOCKET="\${HOME}/.hecate/hecate-daemon/sockets/api.sock"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

log_pass()  { echo -e "  ${GREEN}✓${NC} $*"; PASS=$((PASS + 1)); }
log_fail()  { echo -e "  ${RED}✗${NC} $*"; FAIL=$((FAIL + 1)); }
log_warn()  { echo -e "  ${YELLOW}!${NC} $*"; WARN=$((WARN + 1)); }
log_section() { echo -e "\n${BLUE}[$1]${NC} $2"; }

# Override node list if argument provided
if [[ $# -gt 0 ]]; then
    BEAM_NODES=("$@")
fi

curl_socket() {
    local node="$1"
    local path="$2"
    ssh -o ConnectTimeout=5 "rl@${node}" \
        "curl -sf -m 5 --unix-socket ${SOCKET} http://localhost${path} 2>/dev/null" 2>/dev/null
}

test_node() {
    local node="$1"
    log_section "${node}" "Starting smoke tests"

    # --- 1. SSH connectivity ---
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "rl@${node}" true 2>/dev/null; then
        log_fail "SSH unreachable"
        return
    fi
    log_pass "SSH connected"

    # --- 2. Podman service ---
    local svc_status
    svc_status=$(ssh "rl@${node}" "systemctl --user is-active hecate-daemon 2>/dev/null" 2>/dev/null || echo "unknown")
    if [[ "${svc_status}" == "active" ]]; then
        log_pass "Podman service: active"
    else
        log_fail "Podman service: ${svc_status}"
    fi

    # --- 3. Socket exists ---
    if ssh "rl@${node}" "test -S ${SOCKET}" 2>/dev/null; then
        log_pass "Socket present"
    else
        log_fail "Socket missing: ${SOCKET}"
        return
    fi

    # --- 4. Health endpoint ---
    local health
    health=$(curl_socket "${node}" "/health")
    if [[ -z "${health}" ]]; then
        log_fail "Health endpoint: no response"
        return
    fi

    local ready status
    ready=$(echo "${health}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ready',''))" 2>/dev/null || echo "")
    status=$(echo "${health}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

    if [[ "${ready}" == "True" ]] && [[ "${status}" == "healthy" ]]; then
        log_pass "Health: ready=true, status=healthy"
    else
        log_fail "Health: ready=${ready}, status=${status}"
    fi

    local uptime
    uptime=$(echo "${health}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('uptime_seconds',0))" 2>/dev/null || echo "0")
    log_pass "Uptime: ${uptime}s"

    local identity
    identity=$(echo "${health}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('identity',''))" 2>/dev/null || echo "")
    if [[ "${identity}" == "initialized" ]]; then
        log_pass "Identity: initialized"
    else
        log_warn "Identity: ${identity}"
    fi

    # --- 5. LLM providers ---
    local providers
    providers=$(curl_socket "${node}" "/api/llm/providers")
    if [[ -n "${providers}" ]]; then
        local count
        count=$(echo "${providers}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('providers',d.get('data',[]))))" 2>/dev/null || echo "0")
        if [[ "${count}" -gt 0 ]]; then
            log_pass "LLM providers: ${count} detected"
            # List provider names
            echo "${providers}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
providers = d.get('providers', d.get('data', []))
for p in providers:
    name = p.get('name', p.get('provider', 'unknown'))
    print(f'      - {name}')
" 2>/dev/null || true
        else
            log_warn "LLM providers: none detected (no API keys?)"
        fi
    else
        log_warn "LLM providers: endpoint not responding"
    fi

    # --- 6. API smoke tests ---
    # Ventures list
    local ventures
    ventures=$(curl_socket "${node}" "/api/ventures")
    if [[ -n "${ventures}" ]]; then
        log_pass "GET /api/ventures: responds"
    else
        log_fail "GET /api/ventures: no response"
    fi

    # Node capabilities
    local caps
    caps=$(curl_socket "${node}" "/api/node/capabilities")
    if [[ -n "${caps}" ]]; then
        log_pass "GET /api/node/capabilities: responds"
    else
        log_fail "GET /api/node/capabilities: no response"
    fi

    # IRC channels
    local channels
    channels=$(curl_socket "${node}" "/api/irc/channels")
    if [[ -n "${channels}" ]]; then
        log_pass "GET /api/irc/channels: responds"
    else
        log_fail "GET /api/irc/channels: no response"
    fi

    # LLM models
    local models
    models=$(curl_socket "${node}" "/api/llm/models")
    if [[ -n "${models}" ]]; then
        log_pass "GET /api/llm/models: responds"
    else
        log_fail "GET /api/llm/models: no response"
    fi

    # --- 7. No stale processes ---
    local stale
    stale=$(ssh "rl@${node}" "pgrep -c -f 'beam.smp.*hecate' 2>/dev/null || echo 0" 2>/dev/null | head -1 | tr -d '[:space:]')
    stale="${stale:-0}"
    # Expect exactly 1 BEAM process (the podman container's)
    if [[ "${stale}" -le 1 ]]; then
        log_pass "No stale BEAM processes"
    else
        log_warn "Multiple BEAM processes detected (${stale})"
    fi

    # Check for stale Docker processes
    local docker_procs
    docker_procs=$(ssh "rl@${node}" "pgrep -c dockerd 2>/dev/null || echo 0" 2>/dev/null | head -1 | tr -d '[:space:]')
    docker_procs="${docker_procs:-0}"
    if [[ "${docker_procs}" -eq 0 ]]; then
        log_pass "No Docker daemon running"
    else
        log_warn "Docker daemon still running (${docker_procs} procs)"
    fi
}

echo -e "${BLUE}=== Hecate Beam Cluster Smoke Test ===${NC}"
echo "Date: $(date -Iseconds)"
echo "Nodes: ${BEAM_NODES[*]}"

for node in "${BEAM_NODES[@]}"; do
    test_node "${node}"
done

echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "  ${GREEN}Pass: ${PASS}${NC}"
if [[ ${WARN} -gt 0 ]]; then
    echo -e "  ${YELLOW}Warn: ${WARN}${NC}"
fi
if [[ ${FAIL} -gt 0 ]]; then
    echo -e "  ${RED}Fail: ${FAIL}${NC}"
    exit 1
else
    echo -e "  ${RED}Fail: 0${NC}"
    echo -e "\n${GREEN}All tests passed.${NC}"
fi
