#!/usr/bin/env bash
# Generic local mode e2e runner.
# Starts anvil(s), deploys infra + app, executes via Batcher, decodes events.
#
# Usage (from project root):
#   # Single-chain:
#   bash script/e2e/shared/run-local.sh <E2E.s.sol>
#
#   # Multi-chain (auto-detected if deploy.sh exists in test dir):
#   bash script/e2e/shared/run-local.sh <E2E.s.sol>
#
# Standard contracts: Deploy, Execute (+ ExecuteL2 for multi-chain)
# All contracts read args from env vars.
# If deploy-app.sh exists in script/deployment/<test-name>/, it is called instead of Deploy (implies multi-chain).
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-local.sh <E2E.s.sol>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }
TEST_DIR=$(dirname "$SOL")
TEST_NAME=$(basename "$TEST_DIR")
DEPLOY_SCRIPT="script/deployment/$TEST_NAME/deploy-app.sh"

L1_PORT=8545
L2_PORT=8546
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
export L2_ROLLUP_ID=1
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Auto-detect multi-chain: deploy.sh in test dir means multi-chain
MULTI_CHAIN=false
[[ -f "$DEPLOY_SCRIPT" ]] && MULTI_CHAIN=true

# ══════════════════════════════════════════════
#  1. Start anvil(s)
# ══════════════════════════════════════════════
start_anvil "$L1_PORT" L1_PID
if $MULTI_CHAIN; then
    start_anvil "$L2_PORT" L2_PID
fi

# ══════════════════════════════════════════════
#  2. Deploy infrastructure
# ══════════════════════════════════════════════
if $MULTI_CHAIN; then
    deploy_infra "$L1_RPC" "$PK" "$L2_RPC" "$L2_ROLLUP_ID" "$SYSTEM_ADDRESS"
else
    deploy_infra "$L1_RPC" "$PK"
fi
export ROLLUPS
export RPC="$L1_RPC"
if $MULTI_CHAIN; then
    export MANAGER_L2
    export L2_RPC
fi

# ══════════════════════════════════════════════
#  3. Ensure CREATE2 factory (needed for Bridge/CREATE2 tests)
# ══════════════════════════════════════════════
ensure_create2_factory "$L1_RPC" "L1" "$PK"
if $MULTI_CHAIN; then
    ensure_create2_factory "$L2_RPC" "L2" "$PK"
fi

# ══════════════════════════════════════════════
#  4. Deploy app
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy App ======"
if $MULTI_CHAIN; then
    DEPLOY_OUT=$(bash "$DEPLOY_SCRIPT" \
        --l1-rpc "$L1_RPC" --l2-rpc "$L2_RPC" --pk "$PK" \
        --rollups "$ROLLUPS" --manager-l2 "$MANAGER_L2" \
        --l2-rollup-id "$L2_ROLLUP_ID" 2>&1)
else
    DEPLOY_OUT=$(forge script "$SOL:Deploy" --rpc-url "$L1_RPC" --broadcast --private-key "$PK" 2>&1)
fi
echo "$DEPLOY_OUT" | sed 's/^[[:space:]]*//' | grep -E '^[A-Z0-9_]+=' | grep -v '^==' || true
_export_outputs "$DEPLOY_OUT"

# For bridge: auto-set DESTINATION
if [[ -z "${DESTINATION:-}" ]]; then
    export DESTINATION=$(cast wallet address --private-key "$PK")
fi

# ══════════════════════════════════════════════
#  5. Execute
# ══════════════════════════════════════════════
if $MULTI_CHAIN; then
    echo ""
    echo "====== Execute L2 ======"
    EXEC_L2=$(forge script "$SOL:ExecuteL2" --rpc-url "$L2_RPC" --broadcast --private-key "$PK" 2>&1) \
        && echo "L2 execution succeeded" || echo "L2 execution failed"
    echo "$EXEC_L2" | grep -E "complete|done|error|Error" || true
    L2_BLOCK=$(cast block-number --rpc-url "$L2_RPC")
    echo "L2 execution at block $L2_BLOCK"
fi

echo ""
echo "====== Execute L1 ======"
EXEC_L1=$(forge script "$SOL:Execute" --rpc-url "$L1_RPC" --broadcast --private-key "$PK" 2>&1) \
    && echo "L1 execution succeeded" || echo "L1 execution failed"
echo "$EXEC_L1" | grep -E "complete|done|counter" || true
L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
echo "L1 execution at block $L1_BLOCK"

# ══════════════════════════════════════════════
#  6. Decode events
# ══════════════════════════════════════════════
if $MULTI_CHAIN; then
    decode_block "$L2_RPC" "$L2_BLOCK" "$MANAGER_L2" "L2 "
fi
decode_block "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "L1 "

echo ""
echo "====== Done ======"
