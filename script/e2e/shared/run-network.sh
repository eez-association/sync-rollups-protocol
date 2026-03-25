#!/usr/bin/env bash
# Generic network mode e2e runner.
# Deploys app to existing L1+L2 network, computes expected entries, executes, verifies post-facto.
#
# Usage (from project root):
#   bash script/e2e/shared/run-network.sh <E2E.s.sol> \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> \
#     --rollups <ROLLUPS> --manager-l2 <MANAGER_L2> [--l2-rollup-id <ID>]
#
# Standard contracts in E2E.s.sol (all read args from env vars):
#   Deploy* contracts   → auto-discovered, run in file order (L2 suffix → L2 RPC)
#   ExecuteL2           → L2 execution (load table + executeIncomingCrossChainCall)
#   ExecuteNetwork      → L1 execution (user transaction only, no Batcher)
#   ComputeExpected     → outputs EXPECTED_L1_HASHES, EXPECTED_L2_CALL_HASHES, etc.
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-network.sh <E2E.s.sol> --l1-rpc <RPC> --l2-rpc <RPC> --pk <PK> --rollups <ROLLUPS> --manager-l2 <ADDR>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

# ── Parse args → export as env vars ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)          export RPC="$2"; export L1_RPC="$2"; shift 2;;
        --pk)           export PK="$2"; shift 2;;
        --rollups)      export ROLLUPS="$2"; shift 2;;
        --l1-rpc)       export L1_RPC="$2"; export RPC="$2"; shift 2;;
        --l2-rpc)       export L2_RPC="$2"; shift 2;;
        --manager-l2)   export MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) export L2_ROLLUP_ID="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in RPC PK ROLLUPS L2_RPC MANAGER_L2; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ══════════════════════════════════════════════
#  1. Deploy (auto-discover Deploy* contracts)
# ══════════════════════════════════════════════
echo "====== Deploy ======"
deploy_contracts "$SOL" "$RPC" "$L2_RPC" "$PK"

# ══════════════════════════════════════════════
#  2. Compute expected entries
# ══════════════════════════════════════════════
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$RPC" 2>&1)

EXPECTED_L1_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L1_HASHES")
echo "L1 expected: $EXPECTED_L1_HASHES"

EXPECTED_L2_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_HASHES")
if [[ -n "$EXPECTED_L2_HASHES" ]]; then
    echo "L2 table expected: $EXPECTED_L2_HASHES"
fi

EXPECTED_L2_CALL_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_CALL_HASHES")
echo "L2 calls expected: $EXPECTED_L2_CALL_HASHES"

# ══════════════════════════════════════════════
#  3. Execute (L2 first, then L1)
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L2 ======"
EXEC_L2=$(forge script "$SOL:ExecuteL2" --rpc-url "$L2_RPC" --broadcast --private-key "$PK" 2>&1) \
    && echo "L2 transaction succeeded" || echo "L2 transaction reverted (expected - system posts batch separately)"

echo ""
echo "====== Execute L1 ======"
EXEC_OUT=$(forge script "$SOL:ExecuteNetwork" --rpc-url "$RPC" --broadcast --private-key "$PK" 2>&1) \
    && echo "Transaction succeeded" || echo "Transaction reverted (expected - system posts batch separately)"

L1_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "L1 block: $L1_BLOCK"

# ══════════════════════════════════════════════
#  4. Verify L1 batch
# ══════════════════════════════════════════════
FAILED=false
L1_OK=true
L2_OK=true
L2_CALL_OK=true

echo ""
echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
L1_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
    --rpc-url "$RPC" \
    --sig "run(uint256,address,bytes32[])" "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_L1_HASHES" 2>&1) \
    && L1_OK=true || L1_OK=false

if $L1_OK; then
    echo "$L1_VERIFY" | grep "PASS"
else
    FAILED=true
    echo "L1 VERIFICATION FAILED"
fi

# ══════════════════════════════════════════════
#  5. Verify L2 table (ExecutionTableLoaded) — only for tests with EXPECTED_L2_HASHES
# ══════════════════════════════════════════════
if [[ -n "${EXPECTED_L2_HASHES:-}" ]]; then
    echo ""
    echo "====== Extract L2 Blocks from L1 Batch ======"
    L2_BLOCKS_OUT=$(forge script script/e2e/shared/Verify.s.sol:ExtractL2Blocks \
        --rpc-url "$RPC" \
        --sig "run(uint256,address)" "$L1_BLOCK" "$ROLLUPS" 2>&1)
    L2_BLOCKS=$(extract "$L2_BLOCKS_OUT" "L2_BLOCKS")
    echo "L2 blocks: $L2_BLOCKS"

    echo ""
    echo "====== Verify L2 Table ======"
    if [[ "$L2_BLOCKS" == "[]" ]]; then
        echo "No L2 blocks in batch callData - skipping L2 table verification"
    else
        L2_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Blocks \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256[],address,bytes32[])" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_HASHES" 2>&1) \
            && L2_OK=true || L2_OK=false

        if $L2_OK; then
            echo "$L2_VERIFY" | grep "PASS"
        else
            FAILED=true
            echo "L2 TABLE VERIFICATION FAILED"
        fi
    fi
fi

# ══════════════════════════════════════════════
#  6. Verify L2 calls (IncomingCrossChainCallExecuted)
# ══════════════════════════════════════════════
echo ""
echo "====== Verify L2 Calls ======"
L2_VERIFY_BLOCKS="${L2_BLOCKS:-[$(cast block-number --rpc-url "$L2_RPC")]}"
L2_CALL_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Calls \
    --rpc-url "$L2_RPC" \
    --sig "run(uint256[],address,bytes32[])" "$L2_VERIFY_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_CALL_HASHES" 2>&1) \
    && L2_CALL_OK=true || L2_CALL_OK=false

if $L2_CALL_OK; then
    echo "$L2_CALL_VERIFY" | grep "PASS"
else
    FAILED=true
    echo "L2 CALL VERIFICATION FAILED"
fi

# ══════════════════════════════════════════════
#  7. On failure: show diagnostics
# ══════════════════════════════════════════════
if $FAILED; then
    if ! $L1_OK; then
        echo ""
        echo "--- L1 DIAGNOSTICS ---"
        echo "$L1_VERIFY" | strip_traces
    fi
    if ! $L2_OK; then
        echo ""
        echo "--- L2 TABLE DIAGNOSTICS ---"
        echo "$L2_VERIFY" | strip_traces
    fi
    if ! $L2_CALL_OK; then
        echo ""
        echo "--- L2 CALL DIAGNOSTICS ---"
        echo "$L2_CALL_VERIFY" | strip_traces
    fi
    echo ""
    echo "$COMPUTE_OUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
