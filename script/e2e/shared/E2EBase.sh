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
# Usage: decode_block RPC BLOCK_NUMBER TARGET_CONTRACT [LABEL]
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

# ── Strip forge execution traces ──
strip_traces() {
    grep -v '├─\|└─\|│ \|→ new\|\[staticcall\]\|\[Return\]\|\[Stop\]\|\[Revert\]\|::run(' | sed -n '/^  /p'
}

# ── Trace failed transactions from forge output ──
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
execute_l2_same_block() {
    local sol="$1" l2_rpc="$2" pk="$3"
    local tmpfile
    tmpfile=$(mktemp)

    cast rpc evm_setAutomine false --rpc-url "$l2_rpc" > /dev/null 2>&1

    forge script "$sol:ExecuteL2" --rpc-url "$l2_rpc" --broadcast --private-key "$pk" > "$tmpfile" 2>&1 &
    local forge_pid=$!
    _E2E_PIDS+=("$forge_pid")

    sleep 3

    cast rpc evm_mine --rpc-url "$l2_rpc" > /dev/null 2>&1

    wait "$forge_pid" 2>/dev/null
    local exit_code=$?

    cast rpc evm_setAutomine true --rpc-url "$l2_rpc" > /dev/null 2>&1

    cat "$tmpfile"
    rm -f "$tmpfile"
    return "$exit_code"
}

# ── Get block number from forge broadcast JSON ──
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

# ── Extract L2 block numbers from a postBatch tx's callData (flatten ABI) ──
# postBatch(ExecutionEntry[], StaticCall[], uint256, bytes, bytes)
# We only need to decode the 4th param (callData: bytes), which encodes (uint256[], bytes[]).
extract_l2_blocks_from_tx() {
    local tx_hash="$1" rpc="$2"
    local postbatch_sig='postBatch(((uint256,bytes32,int256)[],bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bool,bytes32)[],(bytes32,bytes,bool,bytes32,uint64,uint64,(address,uint256,bytes,address,uint256,uint256)[],bytes32)[],uint256,bytes,bytes)'

    local input
    input=$(cast tx "$tx_hash" input --rpc-url "$rpc" 2>/dev/null) || { echo "[]"; return; }

    # Decode postBatch, take 4th param (callData bytes) — line 4 in output
    local calldata_hex
    calldata_hex=$(cast calldata-decode "$postbatch_sig" "$input" 2>/dev/null | sed -n '4p') || { echo "[]"; return; }

    if [[ -z "$calldata_hex" || "$calldata_hex" == "0x" ]]; then
        echo "[]"
        return
    fi

    local decoded
    decoded=$(cast abi-decode "f()(uint256[],bytes[])" "$calldata_hex" 2>/dev/null) || { echo "[]"; return; }

    local blocks_str
    blocks_str=$(echo "$decoded" | head -1 | grep -oE '\[[0-9, ]*\]' | head -1)
    echo "${blocks_str:-[]}"
}

# ── Find L1 batch block that references a specific L2 block ──
find_batch_block_by_l2_ref() {
    local l2_block="$1" l1_from="$2" l1_to="$3" rollups="$4" rpc="$5"
    # Computed from keccak256 of flatten-ABI BatchPosted signature.
    # If this ever misses events, regenerate via cast keccak on the event signature.
    local SIG_BATCH
    SIG_BATCH=$(cast keccak 'BatchPosted(((uint256,bytes32,int256)[],bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bool,bytes32)[],bytes32)')

    local logs_json
    logs_json=$(cast logs --from-block "$l1_from" --to-block "$l1_to" \
        --address "$rollups" --rpc-url "$rpc" --json 2>/dev/null) || return 1

    local tx_pairs
    tx_pairs=$(echo "$logs_json" | jq -r \
        "[.[] | select(.topics[0] == \"$SIG_BATCH\") | {tx: .transactionHash, block: .blockNumber}] | unique_by(.tx) | .[] | \"\(.tx) \(.block)\"") || return 1

    [[ -z "$tx_pairs" ]] && return 1

    while IFS=' ' read -r tx_hash block_hex; do
        local l2_blocks
        l2_blocks=$(extract_l2_blocks_from_tx "$tx_hash" "$rpc")
        if echo "$l2_blocks" | grep -qE "(^|\[|,) *${l2_block} *(,|\]|$)"; then
            FOUND_L1_BLOCK=$(printf "%d" "$block_hex")
            FOUND_BATCH_TX="$tx_hash"
            return 0
        fi
    done <<< "$tx_pairs"

    return 1
}

# ── Publish a pre-signed raw tx ──
publish_user_tx() {
    local rpc="$1"

    local rpc_out tx_hash
    if ! rpc_out=$(cast rpc eth_sendRawTransaction "$RLP_ENCODED_TX" --rpc-url "$rpc" 2>&1); then
        echo "ERROR: eth_sendRawTransaction failed"
        echo "$rpc_out"
        return 1
    fi

    tx_hash="${rpc_out%\"}"
    tx_hash="${tx_hash#\"}"
    tx_hash=$(echo "$tx_hash" | tr -d '[:space:]')

    if [[ -z "$tx_hash" || "$tx_hash" == "null" ]]; then
        echo "ERROR: Could not extract tx hash from RPC response."
        echo "Output was: $rpc_out"
        return 1
    fi

    local receipt block_number status

    if ! receipt=$(cast receipt "$tx_hash" --rpc-url "$rpc" --json 2>&1); then
        echo "ERROR: cast receipt failed for tx: $tx_hash"
        echo "$receipt"
        return 1
    fi

    block_number=$(echo "$receipt" | jq -r '.blockNumber // empty')
    status=$(echo "$receipt" | jq -r '.status // empty')

    if [[ -z "$block_number" ]]; then
        echo "ERROR: could not get block number from receipt (tx: $tx_hash)"
        return 1
    fi

    echo "tx: $tx_hash"
    echo "block: $block_number (status: $status)"

    TX_HASH="$tx_hash"
    TX_BLOCK_NUMBER=$(printf "%d" "$block_number")
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
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$pk" 2>&1 | tail -1
}
