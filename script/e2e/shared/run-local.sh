#!/usr/bin/env bash
# Generic local mode e2e runner.
# Starts two anvils (L1 + L2), deploys infra + app, executes L2 then L1, decodes events.
#
# Usage (from project root):
#   bash script/e2e/shared/run-local.sh <E2E.s.sol>
#
# Standard contracts in E2E.s.sol (all read args from env vars):
#   Deploy* contracts  → auto-discovered, run in file order (L2 suffix → L2 RPC)
#   ExecuteL2          → L2 execution (load table + executeIncomingCrossChainCall)
#   Execute            → L1 execution (postBatch + user action via Batcher)
source "$(dirname "$0")/E2EBase.sh"

SOL="$1"; shift || { echo "Usage: run-local.sh <E2E.s.sol>"; exit 1; }
[[ -f "$SOL" ]] || { echo "File not found: $SOL"; exit 1; }

L1_PORT=8545
L2_PORT=8546
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
export L2_ROLLUP_ID=1
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# ══════════════════════════════════════════════
#  1. Start anvils (L1 + L2)
# ══════════════════════════════════════════════
start_anvil "$L1_PORT" L1_PID
start_anvil "$L2_PORT" L2_PID

# ══════════════════════════════════════════════
#  2. Deploy infrastructure (L1 Rollups + L2 CrossChainManagerL2)
# ══════════════════════════════════════════════
deploy_infra "$L1_RPC" "$PK" "$L2_RPC" "$L2_ROLLUP_ID" "$SYSTEM_ADDRESS"
export ROLLUPS
export RPC="$L1_RPC"
export MANAGER_L2
export L2_RPC

# ══════════════════════════════════════════════
#  3. Ensure CREATE2 factory on both chains
# ══════════════════════════════════════════════
ensure_create2_factory "$L1_RPC" "L1" "$PK"
ensure_create2_factory "$L2_RPC" "L2" "$PK"

# ══════════════════════════════════════════════
#  4. Deploy app (auto-discover Deploy* contracts in file order)
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy App ======"
deploy_contracts "$SOL" "$L1_RPC" "$L2_RPC" "$PK"

# ══════════════════════════════════════════════
#  5. Execute (L2 first, then L1)
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L2 ======"
EXEC_L2=$(forge script "$SOL:ExecuteL2" --rpc-url "$L2_RPC" --broadcast --private-key "$PK" 2>&1) \
    && echo "L2 execution succeeded" || echo "L2 execution failed"
echo "$EXEC_L2" | grep -E "complete|done|error|Error" || true
L2_BLOCK=$(cast block-number --rpc-url "$L2_RPC")
echo "L2 execution at block $L2_BLOCK"

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
decode_block "$L2_RPC" "$L2_BLOCK" "$MANAGER_L2" "L2 "
decode_block "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "L1 "

echo ""
echo "====== Done ======"
