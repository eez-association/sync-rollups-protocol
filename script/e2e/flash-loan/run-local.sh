#!/usr/bin/env bash
# End-to-end: start 2 anvils, deploy everything, execute flash loan, decode events.
#
# Run from project root:
#   bash script/e2e/flash-loan/run-local.sh
source "$(dirname "$0")/../shared/E2EBase.sh"

SCRIPT_DIR="script/e2e/flash-loan"
L1_PORT=8545
L2_PORT=8546
L1_RPC="http://localhost:$L1_PORT"
L2_RPC="http://localhost:$L2_PORT"
L2_ROLLUP_ID=1
# On anvil the deployer is also the system address
SYSTEM_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# ══════════════════════════════════════════════
#  Start 2 anvils
# ══════════════════════════════════════════════
start_anvil "$L1_PORT" L1_PID
start_anvil "$L2_PORT" L2_PID

# ══════════════════════════════════════════════
#  Deploy infrastructure
# ══════════════════════════════════════════════
deploy_infra "$L1_RPC" "$PK" "$L2_RPC" "$L2_ROLLUP_ID" "$SYSTEM_ADDRESS"

# ══════════════════════════════════════════════
#  Run deploy-app.sh (Bridge + FlashLoan contracts)
# ══════════════════════════════════════════════
echo ""
echo "====== Deploy Bridge + FlashLoan ======"
DEPLOY_OUTPUT=$(bash "$SCRIPT_DIR/deploy-app.sh" \
    --l1-rpc "$L1_RPC" \
    --l2-rpc "$L2_RPC" \
    --pk "$PK" \
    --rollups "$ROLLUPS" \
    --manager-l2 "$MANAGER_L2" \
    --l2-rollup-id "$L2_ROLLUP_ID" 2>&1)
echo "$DEPLOY_OUTPUT"

TOKEN=$(extract "$DEPLOY_OUTPUT" "  TOKEN")
BRIDGE_L1=$(extract "$DEPLOY_OUTPUT" "  BRIDGE_L1")
BRIDGE_L2=$(extract "$DEPLOY_OUTPUT" "  BRIDGE_L2")
EXECUTOR_L1=$(extract "$DEPLOY_OUTPUT" "  EXECUTOR_L1")
EXECUTOR_L2=$(extract "$DEPLOY_OUTPUT" "  EXECUTOR_L2")
FLASH_LOANERS_NFT=$(extract "$DEPLOY_OUTPUT" "  FLASH_LOANERS_NFT")
WRAPPED_TOKEN_L2=$(extract "$DEPLOY_OUTPUT" "  WRAPPED_TOKEN_L2")

# ══════════════════════════════════════════════
#  Execute L2 phase
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L2 Phase ======"
# Read token metadata from L1 (token doesn't exist on L2)
TOKEN_NAME=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "name()(string)" | tr -d '"')
TOKEN_SYMBOL=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "symbol()(string)" | tr -d '"')
TOKEN_DECIMALS=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "decimals()(uint8)")
echo "Token: $TOKEN_NAME ($TOKEN_SYMBOL), decimals=$TOKEN_DECIMALS"

# ABI-encode args (forge --sig has trouble parsing strings)
L2_CALLDATA=$(cast abi-encode \
    "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
    "$MANAGER_L2" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" \
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS")
L2_SELECTOR=$(cast sig "run(address,address,address,address,address,address,address,address,string,string,uint8)")

forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "${L2_SELECTOR}${L2_CALLDATA#0x}" 2>&1 \
    | grep -E "complete|error|Error" || true

L2_BLOCK=$(cast block-number --rpc-url "$L2_RPC")
echo "L2 execution at block $L2_BLOCK"

# ══════════════════════════════════════════════
#  Execute L1 phase (postBatch + flash loan in same block)
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L1 Phase ======"
forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address,address,address,address,address)" \
    "$ROLLUPS" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" 2>&1 \
    | grep -E "complete|error|Error" || true

L1_BLOCK=$(cast block-number --rpc-url "$L1_RPC")
echo "L1 execution at block $L1_BLOCK"

# ══════════════════════════════════════════════
#  Decode executions
# ══════════════════════════════════════════════
decode_block "$L2_RPC" "$L2_BLOCK" "$MANAGER_L2" "L2 "
decode_block "$L1_RPC" "$L1_BLOCK" "$ROLLUPS" "L1 "

echo ""
echo "====== Done ======"
