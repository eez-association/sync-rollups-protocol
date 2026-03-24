#!/usr/bin/env bash
# Network mode: deploy flash loan app to existing networks, execute, verify post-facto.
#
# Expects Rollups on L1 and CrossChainManagerL2 on L2 to be already deployed.
# Verifies that both L1 batch and L2 table contain expected entries at the same block number.
# On failure, prints both actual and expected execution tables for diagnostics.
#
# Usage (from project root):
#   bash script/e2e/flash-loan/run-network.sh \
#     --l1-rpc <L1_RPC> \
#     --l2-rpc <L2_RPC> \
#     --pk <PRIVATE_KEY> \
#     --rollups <ROLLUPS_ADDR> \
#     --manager-l2 <MANAGER_L2_ADDR> \
#     --l2-rollup-id <ROLLUP_ID>
source "$(dirname "$0")/../shared/E2EBase.sh"

SCRIPT_DIR="script/e2e/flash-loan"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-rpc)       L1_RPC="$2"; shift 2;;
        --l2-rpc)       L2_RPC="$2"; shift 2;;
        --pk)           PK="$2"; shift 2;;
        --rollups)      ROLLUPS="$2"; shift 2;;
        --manager-l2)   MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) L2_ROLLUP_ID="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_RPC L2_RPC PK ROLLUPS MANAGER_L2 L2_ROLLUP_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ══════════════════════════════════════════════
#  Deploy app contracts (Bridge + FlashLoan)
# ══════════════════════════════════════════════
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
#  Compute expected entries (L1 + L2)
# ══════════════════════════════════════════════
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUTPUT=$(forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:FlashLoanComputeExpected" \
    --rpc-url "$L1_RPC" \
    --sig "run(address,address,address,address,address,address,address)" \
    "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" 2>&1)
EXPECTED_L1_HASHES=$(extract "$COMPUTE_OUTPUT" "EXPECTED_L1_HASHES")
EXPECTED_L2_HASHES=$(extract "$COMPUTE_OUTPUT" "EXPECTED_L2_HASHES")
echo "L1 expected hashes: $EXPECTED_L1_HASHES"
echo "L2 expected hashes: $EXPECTED_L2_HASHES"

# ══════════════════════════════════════════════
#  Execute L2 phase
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L2 Phase ======"
TOKEN_NAME=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "name()(string)" | tr -d '"')
TOKEN_SYMBOL=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "symbol()(string)" | tr -d '"')
TOKEN_DECIMALS=$(cast call --rpc-url "$L1_RPC" "$TOKEN" "decimals()(uint8)")
echo "Token: $TOKEN_NAME ($TOKEN_SYMBOL), decimals=$TOKEN_DECIMALS"

L2_CALLDATA=$(cast abi-encode \
    "run(address,address,address,address,address,address,address,address,string,string,uint8)" \
    "$MANAGER_L2" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" \
    "$TOKEN_NAME" "$TOKEN_SYMBOL" "$TOKEN_DECIMALS")
L2_SELECTOR=$(cast sig "run(address,address,address,address,address,address,address,address,string,string,uint8)")

EXEC_L2=$(forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "${L2_SELECTOR}${L2_CALLDATA#0x}" 2>&1) \
    && echo "L2 transaction succeeded" || echo "L2 transaction reverted (expected — system posts batch separately)"

# ══════════════════════════════════════════════
#  Execute L1 phase
# ══════════════════════════════════════════════
echo ""
echo "====== Execute L1 Phase ======"
EXEC_L1=$(forge script "$SCRIPT_DIR/ExecuteFlashLoan.s.sol:ExecuteFlashLoanL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address,address,address,address,address)" \
    "$ROLLUPS" "$BRIDGE_L1" "$BRIDGE_L2" "$EXECUTOR_L1" "$EXECUTOR_L2" "$FLASH_LOANERS_NFT" "$TOKEN" "$WRAPPED_TOKEN_L2" 2>&1) \
    && echo "L1 transaction succeeded" || echo "L1 transaction reverted (expected — system posts batch separately)"

# Use L1 block as the reference block for both chains
BLOCK=$(cast block-number --rpc-url "$L1_RPC")
echo "Verification block: $BLOCK"

# ══════════════════════════════════════════════
#  Verify L1 batch + L2 table at the same block
# ══════════════════════════════════════════════
FAILED=false

echo ""
echo "====== Verify L1 Batch (block $BLOCK) ======"
L1_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
    --rpc-url "$L1_RPC" \
    --sig "run(uint256,address,bytes32[])" "$BLOCK" "$ROLLUPS" "$EXPECTED_L1_HASHES" 2>&1) \
    && L1_OK=true || L1_OK=false

if $L1_OK; then
    echo "$L1_VERIFY" | grep "PASS"
else
    FAILED=true
    echo "L1 VERIFICATION FAILED"
fi

echo ""
echo "====== Verify L2 Table (block $BLOCK) ======"
L2_VERIFY=$(forge script script/e2e/shared/Verify.s.sol:VerifyL2Table \
    --rpc-url "$L2_RPC" \
    --sig "run(uint256,address,bytes32[])" "$BLOCK" "$MANAGER_L2" "$EXPECTED_L2_HASHES" 2>&1) \
    && L2_OK=true || L2_OK=false

if $L2_OK; then
    echo "$L2_VERIFY" | grep "PASS"
else
    FAILED=true
    echo "L2 VERIFICATION FAILED"
fi

# ══════════════════════════════════════════════
#  On failure: show actual + expected tables
# ══════════════════════════════════════════════
if $FAILED; then
    if ! $L1_OK; then
        echo ""
        echo "────────── L1 DIAGNOSTICS ──────────"
        echo "$L1_VERIFY" | strip_traces
    fi
    if ! $L2_OK; then
        echo ""
        echo "────────── L2 DIAGNOSTICS ──────────"
        echo "$L2_VERIFY" | strip_traces
    fi
    echo ""
    echo "$COMPUTE_OUTPUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi

echo ""
echo "====== Done ======"
