#!/usr/bin/env bash
# Generic network mode e2e runner.
# Deploys app to existing network, computes expected entries, executes, verifies post-facto.
#
# Usage (from project root):
#   # Single-chain:
#   bash script/e2e/shared/run-network.sh <E2E.s.sol> --rpc <RPC> --pk <PK> --rollups <ROLLUPS>
#
#   # Multi-chain (pass --l2-rpc):
#   bash script/e2e/shared/run-network.sh <E2E.s.sol> \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> \
#     --rollups <ROLLUPS> --manager-l2 <MANAGER_L2> [--l2-rollup-id <ID>]
#
# Standard contracts in E2E.s.sol: Deploy, ExecuteNetwork, ComputeExpected
# Multi-chain additionally: ExecuteL2
# All contracts read args from env vars.
# If deploy-app.sh exists in script/deployment/<test-name>/, it is called instead of Deploy.
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-network.sh <E2E.s.sol> --rpc <RPC> --pk <PK> --rollups <ROLLUPS>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }
TEST_DIR=$(dirname "$SOL")
TEST_NAME=$(basename "$TEST_DIR")
DEPLOY_SCRIPT="script/deployment/$TEST_NAME/deploy-app.sh"
MULTI_CHAIN=false

# ── Parse args → export as env vars ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)          export RPC="$2"; shift 2;;
        --pk)           export PK="$2"; shift 2;;
        --rollups)      export ROLLUPS="$2"; shift 2;;
        --l1-rpc)       export L1_RPC="$2"; export RPC="$2"; MULTI_CHAIN=true; shift 2;;
        --l2-rpc)       export L2_RPC="$2"; MULTI_CHAIN=true; shift 2;;
        --manager-l2)   export MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) export L2_ROLLUP_ID="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

# Also auto-detect multi-chain from deploy-app.sh (same as run-local.sh)
[[ -f "$DEPLOY_SCRIPT" ]] && MULTI_CHAIN=true

for var in RPC PK ROLLUPS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ══════════════════════════════════════════════
#  1. Deploy
# ══════════════════════════════════════════════
echo "====== Deploy ======"
if [[ -f "$DEPLOY_SCRIPT" ]]; then
    DEPLOY_OUT=$(bash "$DEPLOY_SCRIPT" \
        --l1-rpc "$RPC" --l2-rpc "${L2_RPC:-$RPC}" --pk "$PK" \
        --rollups "$ROLLUPS" --manager-l2 "${MANAGER_L2:-}" \
        --l2-rollup-id "${L2_ROLLUP_ID:-1}" 2>&1)
else
    DEPLOY_OUT=$(forge script "$SOL:Deploy" --rpc-url "$RPC" --broadcast --private-key "$PK" 2>&1)
fi
echo "$DEPLOY_OUT" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true
_export_outputs "$DEPLOY_OUT"

# For bridge tests: auto-set DESTINATION if not set
if [[ -z "${DESTINATION:-}" ]]; then
    export DESTINATION=$(cast wallet address --private-key "$PK")
fi

# ══════════════════════════════════════════════
#  2. Compute expected entries
# ══════════════════════════════════════════════
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUT=$(forge script "$SOL:ComputeExpected" --rpc-url "$RPC" 2>&1)
if $MULTI_CHAIN; then
    EXPECTED_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L1_HASHES")
else
    EXPECTED_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_HASHES")
fi
echo "L1 expected: $EXPECTED_HASHES"

if $MULTI_CHAIN; then
    EXPECTED_L2_HASHES=$(extract "$COMPUTE_OUT" "EXPECTED_L2_HASHES")
    echo "L2 expected: $EXPECTED_L2_HASHES"
fi

# ══════════════════════════════════════════════
#  3. Execute
# ══════════════════════════════════════════════
if $MULTI_CHAIN; then
    echo ""
    echo "====== Execute L2 ======"
    EXEC_L2=$(forge script "$SOL:ExecuteL2" --rpc-url "$L2_RPC" --broadcast --private-key "$PK" 2>&1) \
        && echo "L2 transaction succeeded" || echo "L2 transaction reverted (expected - system posts batch separately)"
fi

echo ""
echo "====== Execute L1 ======"
EXEC_OUT=$(forge script "$SOL:ExecuteNetwork" --rpc-url "$RPC" --broadcast --private-key "$PK" 2>&1) \
    && echo "Transaction succeeded" || echo "Transaction reverted (expected - system posts batch separately)"

L1_BLOCK=$(cast block-number --rpc-url "$RPC")
echo "L1 block: $L1_BLOCK"

# ══════════════════════════════════════════════
#  4. Verify L1
# ══════════════════════════════════════════════
FAILED=false

echo ""
echo "====== Verify L1 Batch (block $L1_BLOCK) ======"
L1_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
    --rpc-url "$RPC" \
    --sig "run(uint256,address,bytes32[])" "$L1_BLOCK" "$ROLLUPS" "$EXPECTED_HASHES" 2>&1) \
    && L1_OK=true || L1_OK=false

if $L1_OK; then
    echo "$L1_VERIFY" | grep "PASS"
else
    FAILED=true
    echo "L1 VERIFICATION FAILED"
fi

# ══════════════════════════════════════════════
#  5. Verify L2 (multi-chain only)
# ══════════════════════════════════════════════
L2_OK=true
if $MULTI_CHAIN && [[ -n "${EXPECTED_L2_HASHES:-}" ]]; then
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
        echo "No L2 blocks in batch callData - skipping L2 verification"
    else
        L2_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Blocks \
            --rpc-url "$L2_RPC" \
            --sig "run(uint256[],address,bytes32[])" "$L2_BLOCKS" "$MANAGER_L2" "$EXPECTED_L2_HASHES" 2>&1) \
            && L2_OK=true || L2_OK=false

        if $L2_OK; then
            echo "$L2_VERIFY" | grep "PASS"
        else
            FAILED=true
            echo "L2 VERIFICATION FAILED"
        fi
    fi
fi

# ══════════════════════════════════════════════
#  6. On failure: show diagnostics
# ══════════════════════════════════════════════
if $FAILED; then
    if ! $L1_OK; then
        echo ""
        echo "--- L1 DIAGNOSTICS ---"
        echo "$L1_VERIFY" | strip_traces
    fi
    if ! $L2_OK; then
        echo ""
        echo "--- L2 DIAGNOSTICS ---"
        echo "$L2_VERIFY" | strip_traces
    fi
    echo ""
    echo "$COMPUTE_OUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
