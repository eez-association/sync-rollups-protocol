#!/usr/bin/env bash
# Shared utilities for e2e test scripts.
# Source from test runners: source "$(dirname "$0")/../shared/E2EBase.sh"

set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

# Default values
PK="${PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"

# ── PIDs to clean up on exit ──
_E2E_PIDS=()

cleanup() {
    for pid in "${_E2E_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Extract KEY=VALUE from forge script output ──
extract() { echo "$1" | grep "$2=" | sed "s/.*$2=//" | awk '{print $1}'; }

# ── Start an anvil instance, return PID via variable name ──
# Usage: start_anvil PORT PID_VAR
start_anvil() {
    local port="$1"
    local pid_var="$2"
    echo "Starting anvil (port $port)..."
    anvil --port "$port" --silent &
    local pid=$!
    _E2E_PIDS+=("$pid")
    eval "$pid_var=$pid"
    sleep 1
    echo "Anvil running (PID $pid)"
}

# ── Deploy infrastructure (Rollups on L1, optionally CCManagerL2 on L2) ──
# Sets ROLLUPS (and MANAGER_L2 if L2_RPC provided)
deploy_infra() {
    local l1_rpc="$1"
    local pk="$2"
    local l2_rpc="${3:-}"
    local l2_rollup_id="${4:-1}"
    local system_address="${5:-0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266}"

    echo ""
    echo "====== Deploy Rollups (L1) ======"
    local output
    output=$(forge script script/e2e/shared/DeployInfra.s.sol:DeployRollupsL1 \
        --rpc-url "$l1_rpc" --broadcast --private-key "$pk" 2>&1)
    ROLLUPS=$(extract "$output" "ROLLUPS")
    echo "ROLLUPS=$ROLLUPS"

    if [[ -n "$l2_rpc" ]]; then
        echo ""
        echo "====== Deploy CrossChainManagerL2 (L2) ======"
        output=$(forge script script/e2e/shared/DeployInfra.s.sol:DeployManagerL2 \
            --rpc-url "$l2_rpc" --broadcast --private-key "$pk" \
            --sig "run(uint256,address)" "$l2_rollup_id" "$system_address" 2>&1)
        MANAGER_L2=$(extract "$output" "MANAGER_L2")
        echo "MANAGER_L2=$MANAGER_L2"
    fi
}

# ── Decode events from a block ──
# Usage: decode_block RPC BLOCK_NUMBER TARGET_CONTRACT
decode_block() {
    local rpc="$1"
    local block="$2"
    local target="$3"
    local label="${4:-}"

    echo ""
    echo "====== DecodeExecutions ${label}(block $block, target $target) ======"
    echo ""
    forge script script/DecodeExecutions.s.sol:DecodeExecutions \
        --rpc-url "$rpc" \
        --sig "runBlock(uint256,address)" "$block" "$target" 2>&1 \
        | sed -n '/^  /p'
}

# ── Auto-export KEY=VALUE lines from forge script output as env vars ──
# Usage: _export_outputs "$FORGE_OUTPUT"
_export_outputs() {
    local output="$1"
    local vars
    vars=$(echo "$output" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true)
    if [[ -n "$vars" ]]; then
        while IFS= read -r line; do
            export "$line"
        done <<< "$vars"
    fi
}

# ── Auto-discover and run Deploy* contracts in file order ──
# Contracts with "L2" in name → L2 RPC, others → L1 RPC
# Usage: deploy_contracts SOL_FILE L1_RPC L2_RPC PK
deploy_contracts() {
    local sol="$1" l1_rpc="$2" l2_rpc="$3" pk="$4"
    local contracts
    contracts=$(grep -oE 'contract Deploy[A-Za-z0-9_]* ' "$sol" | awk '{print $2}')
    [[ -z "$contracts" ]] && { echo "No Deploy* contracts found"; return 1; }
    while IFS= read -r contract; do
        local rpc label
        if [[ "$contract" == *L2* ]]; then
            rpc="$l2_rpc"; label="L2"
        else
            rpc="$l1_rpc"; label="L1"
        fi
        echo "--- $contract ($label) ---"
        local out
        out=$(forge script "$sol:$contract" --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1)
        echo "$out" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true
        _export_outputs "$out"
    done <<< "$contracts"
}

# ── Strip forge execution traces, keep only console.log output ──
# Usage: echo "$FORGE_OUTPUT" | strip_traces
strip_traces() {
    grep -v '├─\|└─\|│ \|→ new\|\[staticcall\]\|\[Return\]\|\[Stop\]\|\[Revert\]\|::run(' | sed -n '/^  /p'
}

# ── Ensure CREATE2 factory exists on a chain ──
ensure_create2_factory() {
    local rpc="$1"
    local label="$2"
    local pk="$3"
    local CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"
    local code
    code=$(cast code "$CREATE2_FACTORY" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    if [[ "$code" != "0x" && ${#code} -gt 2 ]]; then
        echo "$label: CREATE2 factory already deployed"
        return
    fi
    echo "$label: Deploying CREATE2 factory..."
    # Run twice: first funds the pre-determined signer, second deploys the factory
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
}
