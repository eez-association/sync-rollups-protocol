#!/usr/bin/env bash
# Cross-chain block decoder.
# Given an L1 block, decodes L1 events + extracts L2 block numbers from
# postBatch callData + decodes L2 events.
#
# Usage:
#   bash script/e2e/shared/decode-block.sh \
#     --l1-block <N> --l1-rpc <RPC> --l2-rpc <RPC> \
#     --rollups <ADDR> --manager-l2 <ADDR>
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

source "$(dirname "$0")/E2EBase.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-block)     L1_BLOCK="$2"; shift 2;;
        --l1-rpc)       L1_RPC="$2"; shift 2;;
        --l2-rpc)       L2_RPC="$2"; shift 2;;
        --rollups)      ROLLUPS="$2"; shift 2;;
        --manager-l2)   MANAGER_L2="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_BLOCK L1_RPC L2_RPC ROLLUPS MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

DECODE_SCRIPT="script/DecodeExecutions.s.sol:DecodeExecutions"

# 1. Decode L1 block
echo ""
echo "====== L1 Block $L1_BLOCK (Rollups @ $ROLLUPS) ======"
echo ""
forge script "$DECODE_SCRIPT" \
    --rpc-url "$L1_RPC" \
    --sig "runBlock(uint256,address)" "$L1_BLOCK" "$ROLLUPS" 2>&1 \
    | sed -n '/^  /p'

# 2. Extract L2 blocks from postBatch tx
SIG_BATCH_POSTED=$(cast keccak 'BatchPosted(((uint256,bytes32,int256)[],bytes32,(address,uint256,bytes,address,uint256,uint256)[],(bytes32,uint256,bytes)[],uint256,bytes,bool,bytes32)[],bytes32)')

BATCH_TX=$(cast logs \
    --from-block "$L1_BLOCK" --to-block "$L1_BLOCK" \
    --address "$ROLLUPS" \
    --rpc-url "$L1_RPC" --json 2>/dev/null \
    | jq -r "[.[] | select(.topics[0] == \"$SIG_BATCH_POSTED\")] | .[0].transactionHash // empty")

L2_BLOCKS="[]"
if [[ -n "$BATCH_TX" ]]; then
    L2_BLOCKS=$(extract_l2_blocks_from_tx "$BATCH_TX" "$L1_RPC")
fi

echo ""
echo "====== L2 Blocks extracted: $L2_BLOCKS (from tx $BATCH_TX) ======"

# 3. Decode each L2 block
if [[ "$L2_BLOCKS" != "[]" ]]; then
    BLOCKS_CSV=$(echo "$L2_BLOCKS" | tr -d '[] ')
    IFS=',' read -ra BLOCK_ARR <<< "$BLOCKS_CSV"
    for b in "${BLOCK_ARR[@]}"; do
        [[ -z "$b" ]] && continue
        echo ""
        echo "====== L2 Block $b (ManagerL2 @ $MANAGER_L2) ======"
        echo ""
        forge script "$DECODE_SCRIPT" \
            --rpc-url "$L2_RPC" \
            --sig "runBlock(uint256,address)" "$b" "$MANAGER_L2" 2>&1 \
            | sed -n '/^  /p'
    done
else
    echo ""
    echo "(no L2 blocks found in postBatch callData)"
fi

echo ""
echo "====== Done ======"
