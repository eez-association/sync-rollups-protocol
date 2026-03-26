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

# ── Extract KEY=VALUE from forge script output (returns "" if not found) ──
extract() { echo "$1" | grep "$2=" | sed "s/.*$2=//" | awk '{print $1}' || true; }

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

# ── Trace failed transactions from forge output ──
# Usage: trace_failed_txs "$FORGE_OUTPUT" RPC
trace_failed_txs() {
    local output="$1"
    local rpc="$2"
    local txs
    txs=$(echo "$output" | grep "Transaction Failure:" | sed 's/.*Transaction Failure: //' | awk '{print $1}' || true)
    if [[ -n "$txs" ]]; then
        while IFS= read -r tx; do
            echo ""
            echo "--- Tracing failed tx $tx ---"
            cast run "$tx" --rpc-url "$rpc" 2>&1 || true
        done <<< "$txs"
    fi
}

# ── Execute L2 with same-block guarantee (local mode only) ──
# Disables automine so forge submits all txs to the mempool, then mines
# them in a single block. This satisfies the ExecutionNotInCurrentBlock check.
# Usage: EXEC_L2=$(execute_l2_same_block SOL_FILE L2_RPC PK)
execute_l2_same_block() {
    local sol="$1" l2_rpc="$2" pk="$3"
    local tmpfile
    tmpfile=$(mktemp)

    # Disable automine — txs go to pending pool instead of being mined immediately
    cast rpc evm_setAutomine false --rpc-url "$l2_rpc" > /dev/null 2>&1

    # forge --broadcast (without --slow) sends ALL txs before polling for receipts
    forge script "$sol:ExecuteL2" --rpc-url "$l2_rpc" --broadcast --private-key "$pk" > "$tmpfile" 2>&1 &
    local forge_pid=$!
    _E2E_PIDS+=("$forge_pid")

    # Wait for forge to submit all txs to the pending pool
    sleep 3

    # Mine a single block containing all pending txs
    cast rpc evm_mine --rpc-url "$l2_rpc" > /dev/null 2>&1

    # Wait for forge to finish (it now gets receipts from the mined block)
    wait "$forge_pid" 2>/dev/null
    local exit_code=$?

    # Re-enable automine for subsequent operations
    cast rpc evm_setAutomine true --rpc-url "$l2_rpc" > /dev/null 2>&1

    cat "$tmpfile"
    rm -f "$tmpfile"
    return "$exit_code"
}

# ── Get block number from forge broadcast JSON ──
# Reads broadcast/<Script>.s.sol/<chainId>/run-latest.json, returns decimal block of last receipt.
# Usage: BLOCK=$(get_block_from_broadcast SOL_FILE RPC_URL)
get_block_from_broadcast() {
    local sol="$1" rpc="$2"
    local chain_id
    chain_id=$(cast chain-id --rpc-url "$rpc")
    local sol_basename
    sol_basename=$(basename "$sol")
    local json="broadcast/${sol_basename}/${chain_id}/run-latest.json"
    if [[ ! -f "$json" ]]; then
        echo "ERROR: Broadcast file not found: $json" >&2
        return 1
    fi
    local tx_hash
    tx_hash=$(jq -r '.receipts[-1].transactionHash' "$json")
    echo "tx: $tx_hash" >&2
    printf "%d\n" "$(jq -r '.receipts[-1].blockNumber' "$json")"
}

# ── Extract L2 block numbers from a postBatch tx's callData ──
# Fetches the tx input, extracts the 3rd param (callData), decodes L2 block numbers.
# Usage: L2_BLOCKS=$(extract_l2_blocks_from_tx TX_HASH RPC_URL)
# Returns: "[156,157]" or "[]" if empty
extract_l2_blocks_from_tx() {
    local tx_hash="$1" rpc="$2"
    local postbatch_sig='postBatch(((uint256,bytes32,bytes32,int256)[],bytes32,(uint8,uint256,address,uint256,bytes,bool,address,uint256,uint256[]))[],uint256,bytes,bytes)'

    local input
    input=$(cast tx "$tx_hash" input --rpc-url "$rpc" 2>/dev/null) || { echo "[]"; return; }

    # Decode the full postBatch calldata — 3rd line is the callData (bytes) param
    local calldata_hex
    calldata_hex=$(cast calldata-decode "$postbatch_sig" "$input" 2>/dev/null | sed -n '3p') || { echo "[]"; return; }

    if [[ -z "$calldata_hex" || "$calldata_hex" == "0x" ]]; then
        echo "[]"
        return
    fi

    local decoded
    decoded=$(cast abi-decode "f()(uint256[],bytes[])" "$calldata_hex" 2>/dev/null) || { echo "[]"; return; }

    # cast outputs: ([156, 157], [0x...]) — extract the first array
    local blocks_str
    blocks_str=$(echo "$decoded" | head -1 | grep -oE '\[[0-9, ]*\]' | head -1)
    echo "${blocks_str:-[]}"
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
