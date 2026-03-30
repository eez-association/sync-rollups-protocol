#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Cross-chain trace decoder
# ═══════════════════════════════════════════════════════════════════════
#
# Given a tx hash (L1 or L2), produces a fully decoded, human-readable
# execution trace with contract names, function names, and decoded errors.
# For cross-chain txs, automatically finds and shows the corresponding
# chain's trace too.
#
# Features:
#   - Auto-discovers contract names via Blockscout API (l1.eez.dev, l2.eez.dev)
#   - Decodes custom error selectors (ExecutionNotFound, etc.)
#   - Finds corresponding L2 blocks from L1 batches (and vice versa via L2Context)
#   - Truncates verbose calldata for readability
#   - Labels from env vars, explorer API, and optional --labels file
#
# Usage:
#   bash script/e2e/shared/decode-trace.sh \
#     --tx <HASH> --l1-rpc <RPC> --l2-rpc <RPC> \
#     --rollups <ADDR> --manager-l2 <ADDR> \
#     [--l1-explorer <URL>] [--l2-explorer <URL>] \
#     [--labels <FILE>]
#
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

source "$(dirname "$0")/E2EBase.sh"

# ── Constants ──
L2_CONTEXT="0x5FbDB2315678afecb367f032d93F642f64180aa3"
SIG_BATCH_POSTED="0x2f482312f12dceb86aac9ef0e0e1d9421ac62910326b3d50695d63117321b520"

# ── Error selector cache (populated dynamically via cast 4byte) ──
declare -A ERROR_CACHE

# ── Parse args ──
TX_HASH=""
LABELS_FILE=""
L1_EXPLORER="https://l1.eez.dev"
L2_EXPLORER="https://l2.eez.dev"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tx)            TX_HASH="$2"; shift 2;;
        --l1-rpc)        L1_RPC="$2"; shift 2;;
        --l2-rpc)        L2_RPC="$2"; shift 2;;
        --rollups)       ROLLUPS="$2"; shift 2;;
        --manager-l2)    MANAGER_L2="$2"; shift 2;;
        --l1-explorer)   L1_EXPLORER="$2"; shift 2;;
        --l2-explorer)   L2_EXPLORER="$2"; shift 2;;
        --labels)        LABELS_FILE="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in TX_HASH L1_RPC L2_RPC ROLLUPS MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ══════════════════════════════════════════════
#  Explorer API helpers
# ══════════════════════════════════════════════

# Lookup contract name via Blockscout v2 API.
# Returns "ContractName" for verified contracts, "EOA" for non-contracts, "" for unknown.
explorer_lookup_name() {
    local addr="$1" explorer_url="$2"
    local result
    result=$(curl -sL --max-time 5 "${explorer_url}/api/v2/addresses/${addr}" 2>/dev/null) || { echo ""; return; }

    local is_contract name
    is_contract=$(echo "$result" | jq -r '.is_contract // false' 2>/dev/null)
    name=$(echo "$result" | jq -r '.name // empty' 2>/dev/null)

    if [[ "$is_contract" == "false" ]]; then
        echo "EOA"
    elif [[ -n "$name" && "$name" != "null" ]]; then
        echo "$name"
    else
        echo ""
    fi
}

# Lookup contract name via Blockscout v1 API (fallback).
explorer_lookup_name_v1() {
    local addr="$1" explorer_url="$2"
    local result
    result=$(curl -sL --max-time 5 "${explorer_url}/api?module=contract&action=getsourcecode&address=${addr}" 2>/dev/null) || { echo ""; return; }
    echo "$result" | jq -r '.result[0].ContractName // empty' 2>/dev/null
}

# ══════════════════════════════════════════════
#  Build label map (Phase 1: known sources)
# ══════════════════════════════════════════════

declare -A LABEL_MAP

# System contracts
LABEL_MAP["$(echo "$ROLLUPS" | tr '[:upper:]' '[:lower:]')"]="Rollups"
LABEL_MAP["$(echo "$MANAGER_L2" | tr '[:upper:]' '[:lower:]')"]="ManagerL2"
LABEL_MAP["$(echo "$L2_CONTEXT" | tr '[:upper:]' '[:lower:]')"]="L2Context"

# Auto-detect from env vars: any var whose value is a 42-char hex address
while IFS='=' read -r varname varval; do
    if [[ "$varval" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
        addr_lower=$(echo "$varval" | tr '[:upper:]' '[:lower:]')
        if [[ -z "${LABEL_MAP[$addr_lower]:-}" ]]; then
            LABEL_MAP["$addr_lower"]="$varname"
        fi
    fi
done < <(env | grep -E '^[A-Z][A-Z0-9_]*=0x[0-9a-fA-F]{40}$' || true)

# From --labels file
if [[ -n "$LABELS_FILE" && -f "$LABELS_FILE" ]]; then
    while IFS='=' read -r addr name; do
        [[ -z "$addr" || "$addr" == \#* ]] && continue
        addr_lower=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
        LABEL_MAP["$addr_lower"]="$name"
    done < "$LABELS_FILE"
fi

# ══════════════════════════════════════════════
#  Detect which chain the tx is on
# ══════════════════════════════════════════════

detect_chain() {
    local tx="$1"
    if cast tx "$tx" blockNumber --rpc-url "$L1_RPC" >/dev/null 2>&1; then
        echo "L1"; return
    fi
    if cast tx "$tx" blockNumber --rpc-url "$L2_RPC" >/dev/null 2>&1; then
        echo "L2"; return
    fi
    echo "UNKNOWN"
}

echo "Detecting chain for tx $TX_HASH..."
CHAIN=$(detect_chain "$TX_HASH")
echo "Chain: $CHAIN"

if [[ "$CHAIN" == "UNKNOWN" ]]; then
    echo "ERROR: Could not find tx on L1 or L2"
    exit 1
fi

# ══════════════════════════════════════════════
#  Phase 2: Discover addresses from raw trace, enrich via explorer
# ══════════════════════════════════════════════

# Try to resolve an address name from both explorers.
# Returns the name or empty string.
resolve_address_name() {
    local addr="$1"
    local name

    # Try primary explorer (v2, then v1)
    for explorer in "$L1_EXPLORER" "$L2_EXPLORER"; do
        name=$(explorer_lookup_name "$addr" "$explorer")
        if [[ -n "$name" && "$name" != "null" && "$name" != "EOA" ]]; then
            echo "$name"; return
        fi
        # v1 fallback (has ContractName from verified source)
        name=$(explorer_lookup_name_v1 "$addr" "$explorer")
        if [[ -n "$name" && "$name" != "null" ]]; then
            echo "$name"; return
        fi
    done

    # Check if EOA on the primary chain
    name=$(explorer_lookup_name "$addr" "$L1_EXPLORER")
    if [[ "$name" == "EOA" ]]; then
        echo "EOA"; return
    fi
    name=$(explorer_lookup_name "$addr" "$L2_EXPLORER")
    if [[ "$name" == "EOA" ]]; then
        echo "EOA"; return
    fi

    echo ""
}

discover_and_label_addresses() {
    local tx="$1" rpc="$2"

    echo "  Discovering addresses from trace..." >&2

    # Run a quick trace to extract all unique addresses
    local raw_trace
    raw_trace=$(cast run "$tx" --rpc-url "$rpc" 2>&1) || true

    # Extract all unique 0x addresses (40 hex chars)
    local addrs
    addrs=$(echo "$raw_trace" | grep -oE '0x[0-9a-fA-F]{40}' | sort -uf)

    local count=0 resolved=0
    while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        local addr_lower
        addr_lower=$(echo "$addr" | tr '[:upper:]' '[:lower:]')

        # Skip if already labelled
        if [[ -n "${LABEL_MAP[$addr_lower]:-}" ]]; then
            continue
        fi

        count=$((count + 1))

        local name
        name=$(resolve_address_name "$addr")

        if [[ "$name" == "EOA" ]]; then
            LABEL_MAP["$addr_lower"]="EOA_${addr:0:8}"
            resolved=$((resolved + 1))
        elif [[ -n "$name" ]]; then
            LABEL_MAP["$addr_lower"]="$name"
            resolved=$((resolved + 1))
        fi
    done <<< "$addrs"

    echo "  Resolved $resolved/$count unknown addresses via explorer" >&2
}

# Discover on the primary chain
if [[ "$CHAIN" == "L1" ]]; then
    discover_and_label_addresses "$TX_HASH" "$L1_RPC"
else
    discover_and_label_addresses "$TX_HASH" "$L2_RPC"
fi

# ══════════════════════════════════════════════
#  Build --label flags
# ══════════════════════════════════════════════

LABEL_ARGS=()
build_label_args() {
    LABEL_ARGS=()
    for addr in "${!LABEL_MAP[@]}"; do
        # Sanitize: replace spaces and special chars with underscores
        local safe_name
        safe_name=$(echo "${LABEL_MAP[$addr]}" | tr ' /:()' '_____')
        LABEL_ARGS+=("--label" "${addr}:${safe_name}")
    done
}

build_label_args

# ══════════════════════════════════════════════
#  Post-processing: decode errors, truncate calldata
# ══════════════════════════════════════════════

# Resolve an error selector to its name. Uses cache, then cast 4byte.
resolve_error_selector() {
    local sel="$1"

    # Check cache
    if [[ -n "${ERROR_CACHE[$sel]:-}" ]]; then
        echo "${ERROR_CACHE[$sel]}"
        return
    fi

    # Try cast 4byte (online 4byte.directory lookup)
    local decoded
    decoded=$(cast 4byte "$sel" 2>/dev/null | head -1) || true
    if [[ -n "$decoded" ]]; then
        ERROR_CACHE["$sel"]="$decoded"
        echo "$decoded"
        return
    fi

    echo ""
}

postprocess_trace() {
    local trace="$1"

    # 1. Find and decode all custom error selectors via cast 4byte
    local error_sels
    error_sels=$(echo "$trace" | grep -oE 'custom error 0x[0-9a-fA-F]{8}' | grep -oE '0x[0-9a-fA-F]{8}' | sort -u || true)
    while IFS= read -r sel; do
        [[ -z "$sel" ]] && continue
        local decoded
        decoded=$(resolve_error_selector "$sel")
        if [[ -n "$decoded" ]]; then
            trace=$(echo "$trace" | sed "s|custom error ${sel}|${decoded}|g")
        fi
    done <<< "$error_sels"

    # 2. Truncate long hex in calldata args (>64 hex chars after 0x)
    trace=$(echo "$trace" | sed -E 's/0x([0-9a-fA-F]{16})[0-9a-fA-F]{50,}/0x\1...(truncated)/g')

    echo "$trace"
}

# ══════════════════════════════════════════════
#  Get trace for a tx
# ══════════════════════════════════════════════

run_trace() {
    local tx="$1" rpc="$2" label="$3"

    echo ""
    echo "====== $label Trace ($tx) ======"
    echo ""

    local raw_trace
    raw_trace=$(cast run "$tx" --rpc-url "$rpc" "${LABEL_ARGS[@]}" 2>&1) || true

    postprocess_trace "$raw_trace"
}

# ══════════════════════════════════════════════
#  Cross-chain block correlation helpers
# ══════════════════════════════════════════════

find_l2_blocks_from_l1_block() {
    local l1_block="$1"
    local batch_tx
    batch_tx=$(cast logs \
        --from-block "$l1_block" --to-block "$l1_block" \
        --address "$ROLLUPS" \
        --rpc-url "$L1_RPC" --json 2>/dev/null \
        | jq -r "[.[] | select(.topics[0] == \"$SIG_BATCH_POSTED\")] | .[0].transactionHash // empty")

    if [[ -z "$batch_tx" ]]; then
        echo "[]"
        return
    fi
    extract_l2_blocks_from_tx "$batch_tx" "$L1_RPC"
}

# L2Context returns the PARENT L1 block. The batch is typically at parent+1.
find_l1_block_from_l2() {
    local l2_block="$1"
    local result
    result=$(cast call "$L2_CONTEXT" "contexts(uint256)(uint256,bytes32)" "$l2_block" \
        --rpc-url "$L2_RPC" 2>/dev/null) || { echo ""; return; }

    local l1_parent
    l1_parent=$(echo "$result" | head -1 | tr -d '[:space:]')

    if [[ "$l1_parent" == "0" ]]; then
        echo ""
        return
    fi

    # Return parent+1 (the batch block, not the parent)
    echo $((l1_parent + 1))
}

find_l2_manager_txs() {
    local l2_block="$1"
    local manager_lower
    manager_lower=$(echo "$MANAGER_L2" | tr '[:upper:]' '[:lower:]')

    local block_json
    block_json=$(cast block "$l2_block" --json --rpc-url "$L2_RPC" 2>/dev/null) || return
    local tx_hashes
    tx_hashes=$(echo "$block_json" | jq -r '.transactions[]' 2>/dev/null) || return

    while IFS= read -r tx; do
        [[ -z "$tx" ]] && continue
        local to
        to=$(cast tx "$tx" to --rpc-url "$L2_RPC" 2>/dev/null | tr '[:upper:]' '[:lower:]') || continue
        if [[ "$to" == "$manager_lower" ]]; then
            echo "$tx"
        fi
    done <<< "$tx_hashes"
}

find_l1_batch_tx() {
    local l1_block="$1"
    cast logs \
        --from-block "$l1_block" --to-block "$l1_block" \
        --address "$ROLLUPS" \
        --rpc-url "$L1_RPC" --json 2>/dev/null \
        | jq -r "[.[] | select(.topics[0] == \"$SIG_BATCH_POSTED\")] | .[0].transactionHash // empty"
}

# ══════════════════════════════════════════════
#  Also discover addresses from cross-chain traces
# ══════════════════════════════════════════════

discover_cross_chain_addresses() {
    local tx="$1" rpc="$2"
    discover_and_label_addresses "$tx" "$rpc"
    # Rebuild label args after discovering more addresses
    build_label_args
}

# ══════════════════════════════════════════════
#  Main: L1 tx flow
# ══════════════════════════════════════════════

if [[ "$CHAIN" == "L1" ]]; then
    L1_BLOCK=$(cast receipt "$TX_HASH" blockNumber --rpc-url "$L1_RPC" 2>/dev/null)
    L1_BLOCK_DEC=$(printf "%d" "$L1_BLOCK")
    TX_STATUS=$(cast receipt "$TX_HASH" status --rpc-url "$L1_RPC" 2>/dev/null)

    echo "L1 block: $L1_BLOCK_DEC (status: $TX_STATUS)"

    # 1. L1 user tx trace
    run_trace "$TX_HASH" "$L1_RPC" "L1 User TX"

    # 2. L1 batch tx (if different)
    BATCH_TX=$(find_l1_batch_tx "$L1_BLOCK_DEC")
    if [[ -n "$BATCH_TX" && "$BATCH_TX" != "$TX_HASH" ]]; then
        run_trace "$BATCH_TX" "$L1_RPC" "L1 Batch (postBatch)"
    fi

    # 3. Find L2 blocks and show L2 traces
    L2_BLOCKS=$(find_l2_blocks_from_l1_block "$L1_BLOCK_DEC")
    echo ""
    echo "====== L2 Blocks from batch: $L2_BLOCKS ======"

    if [[ "$L2_BLOCKS" != "[]" && -n "$L2_BLOCKS" ]]; then
        BLOCKS_CSV=$(echo "$L2_BLOCKS" | tr -d '[] ')
        IFS=',' read -ra BLOCK_ARR <<< "$BLOCKS_CSV"
        for b in "${BLOCK_ARR[@]}"; do
            [[ -z "$b" ]] && continue
            echo ""
            echo "--- L2 Block $b ---"

            L2_TXS=$(find_l2_manager_txs "$b")
            if [[ -z "$L2_TXS" ]]; then
                echo "(no ManagerL2 txs in block $b)"
                continue
            fi

            # Discover L2 addresses from first tx
            first_l2_tx=$(echo "$L2_TXS" | head -1)
            if [[ -n "$first_l2_tx" ]]; then
                discover_cross_chain_addresses "$first_l2_tx" "$L2_RPC"
            fi

            while IFS= read -r l2_tx; do
                [[ -z "$l2_tx" ]] && continue
                run_trace "$l2_tx" "$L2_RPC" "L2 (block $b)"
            done <<< "$L2_TXS"
        done
    fi

# ══════════════════════════════════════════════
#  Main: L2 tx flow
# ══════════════════════════════════════════════

elif [[ "$CHAIN" == "L2" ]]; then
    L2_BLOCK=$(cast receipt "$TX_HASH" blockNumber --rpc-url "$L2_RPC" 2>/dev/null)
    L2_BLOCK_DEC=$(printf "%d" "$L2_BLOCK")
    TX_STATUS=$(cast receipt "$TX_HASH" status --rpc-url "$L2_RPC" 2>/dev/null)

    echo "L2 block: $L2_BLOCK_DEC (status: $TX_STATUS)"

    # 1. L2 tx trace
    run_trace "$TX_HASH" "$L2_RPC" "L2 User TX"

    # 2. Find L1 batch block via L2Context (parent+1)
    L1_BATCH_BLOCK=$(find_l1_block_from_l2 "$L2_BLOCK_DEC")
    if [[ -n "$L1_BATCH_BLOCK" ]]; then
        echo ""
        echo "====== L2 block $L2_BLOCK_DEC → L1 batch block ~$L1_BATCH_BLOCK ======"

        # Search L1 blocks [parent+1 .. parent+5] for the batch referencing this L2 block
        L1_SEARCH_END=$((L1_BATCH_BLOCK + 4))
        if find_batch_block_by_l2_ref "$L2_BLOCK_DEC" "$L1_BATCH_BLOCK" "$L1_SEARCH_END" "$ROLLUPS" "$L1_RPC" 2>/dev/null; then
            echo "Found L1 batch in block $FOUND_L1_BLOCK (tx $FOUND_BATCH_TX)"

            # Discover L1 addresses from batch tx
            discover_cross_chain_addresses "$FOUND_BATCH_TX" "$L1_RPC"

            # Show batch trace
            run_trace "$FOUND_BATCH_TX" "$L1_RPC" "L1 Batch (postBatch, block $FOUND_L1_BLOCK)"

            # Find user txs in same L1 block (non-batch)
            BLOCK_JSON=$(cast block "$FOUND_L1_BLOCK" --json --rpc-url "$L1_RPC" 2>/dev/null)
            ALL_L1_TXS=$(echo "$BLOCK_JSON" | jq -r '.transactions[]' 2>/dev/null)

            while IFS= read -r l1_tx; do
                [[ -z "$l1_tx" || "$l1_tx" == "$FOUND_BATCH_TX" ]] && continue
                local_status=$(cast receipt "$l1_tx" status --rpc-url "$L1_RPC" 2>/dev/null || echo "?")
                run_trace "$l1_tx" "$L1_RPC" "L1 User TX (block $FOUND_L1_BLOCK, status $local_status)"
            done <<< "$ALL_L1_TXS"
        else
            echo "Could not find L1 batch referencing L2 block $L2_BLOCK_DEC in blocks $L1_BATCH_BLOCK..$L1_SEARCH_END"
        fi
    else
        echo "Could not resolve L1 parent block from L2Context"
    fi
fi

echo ""
echo "====== Done ======"
