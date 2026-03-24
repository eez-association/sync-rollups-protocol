#!/usr/bin/env bash
# Deploy bridge + flash loan contracts across L1 and L2.
#
# Prerequisites:
#   - Rollups deployed on L1, CrossChainManagerL2 deployed on L2
#   - Private key with ETH on both chains
#
# Usage:
#   bash script/flash-loan-test/deploy.sh \
#     --l1-rpc <L1_RPC> \
#     --l2-rpc <L2_RPC> \
#     --pk <PRIVATE_KEY> \
#     --rollups <ROLLUPS_ADDR> \
#     --manager-l2 <MANAGER_L2_ADDR> \
#     --l2-rollup-id <ROLLUP_ID> \
#     [--salt <BRIDGE_SALT>]
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

SCRIPT_DIR="script/flash-loan-test"

# ── Parse args ──
SALT="0x$(printf '%-64s' "$(echo -n 'sync-rollups-bridge-v1' | xxd -p)" | tr ' ' '0')"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-rpc)       L1_RPC="$2"; shift 2;;
        --l2-rpc)       L2_RPC="$2"; shift 2;;
        --pk)           PK="$2"; shift 2;;
        --rollups)      ROLLUPS="$2"; shift 2;;
        --manager-l2)   MANAGER_L2="$2"; shift 2;;
        --l2-rollup-id) L2_ROLLUP_ID="$2"; shift 2;;
        --salt)         SALT="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_RPC L2_RPC PK ROLLUPS MANAGER_L2 L2_ROLLUP_ID; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

extract() { echo "$1" | grep "$2=" | sed "s/.*$2=//"; }

# ══════════════════════════════════════════════
#  Step 0: Ensure CREATE2 factory on both chains
# ══════════════════════════════════════════════
CREATE2_FACTORY="0x4e59b44847b379578588920cA78FbF26c0B4956C"

ensure_create2_factory() {
    local rpc="$1"
    local label="$2"
    local code
    code=$(cast code "$CREATE2_FACTORY" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    if [[ "$code" != "0x" && ${#code} -gt 2 ]]; then
        echo "$label: CREATE2 factory already deployed"
        return
    fi
    echo "$label: Deploying CREATE2 factory..."
    # Run twice: first funds the signer, second deploys
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$PK" 2>&1 | tail -1
    forge script script/DeployBridge.s.sol:DeployCreate2Factory \
        --rpc-url "$rpc" --broadcast --private-key "$PK" 2>&1 | tail -1
}

echo "====== Step 0: Ensure CREATE2 factory ======"
ensure_create2_factory "$L1_RPC" "L1"
ensure_create2_factory "$L2_RPC" "L2"

# ══════════════════════════════════════════════
#  Step 1: Deploy Token + Bridge on L1
# ══════════════════════════════════════════════
echo ""
echo "====== Step 1: Deploy Token + Bridge L1 ======"
L1_BRIDGE_OUTPUT=$(forge script "$SCRIPT_DIR/DeployFlashLoan.s.sol:DeployTokenAndBridgeL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,bytes32)" "$ROLLUPS" "$SALT" 2>&1)
TOKEN=$(extract "$L1_BRIDGE_OUTPUT" "TOKEN")
BRIDGE_L1=$(extract "$L1_BRIDGE_OUTPUT" "BRIDGE_L1")
echo "TOKEN=$TOKEN"
echo "BRIDGE_L1=$BRIDGE_L1"

# ══════════════════════════════════════════════
#  Step 2: Deploy Bridge on L2
# ══════════════════════════════════════════════
echo ""
echo "====== Step 2: Deploy Bridge L2 ======"
L2_BRIDGE_OUTPUT=$(forge script "$SCRIPT_DIR/DeployFlashLoan.s.sol:DeployBridgeL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,uint256,bytes32)" "$MANAGER_L2" "$L2_ROLLUP_ID" "$SALT" 2>&1)
BRIDGE_L2=$(extract "$L2_BRIDGE_OUTPUT" "BRIDGE_L2")
echo "BRIDGE_L2=$BRIDGE_L2"

# ══════════════════════════════════════════════
#  Step 3: Set canonical bridge addresses
# ══════════════════════════════════════════════
echo ""
echo "====== Step 3: Set canonical bridge addresses ======"
cast send --rpc-url "$L1_RPC" --private-key "$PK" \
    "$BRIDGE_L1" "setCanonicalBridgeAddress(address)" "$BRIDGE_L2" > /dev/null
echo "L1 Bridge → canonical = $BRIDGE_L2"

cast send --rpc-url "$L2_RPC" --private-key "$PK" \
    "$BRIDGE_L2" "setCanonicalBridgeAddress(address)" "$BRIDGE_L1" > /dev/null
echo "L2 Bridge → canonical = $BRIDGE_L1"

# ══════════════════════════════════════════════
#  Step 4: Pre-compute WrappedToken address (reads token metadata from L1)
# ══════════════════════════════════════════════
echo ""
echo "====== Step 4: Pre-compute WrappedToken address ======"
WRAPPED_OUTPUT=$(forge script "$SCRIPT_DIR/DeployFlashLoan.s.sol:ComputeWrappedTokenAddress" \
    --rpc-url "$L1_RPC" \
    --sig "run(address,address,uint256)" "$BRIDGE_L2" "$TOKEN" "0" 2>&1)
WRAPPED_TOKEN_L2=$(extract "$WRAPPED_OUTPUT" "WRAPPED_TOKEN_L2")
echo "WRAPPED_TOKEN_L2=$WRAPPED_TOKEN_L2"

# ══════════════════════════════════════════════
#  Step 5: Deploy L2 contracts (executorL2 + FlashLoanersNFT)
# ══════════════════════════════════════════════
echo ""
echo "====== Step 5: Deploy L2 contracts ======"
L2_OUTPUT=$(forge script "$SCRIPT_DIR/DeployFlashLoan.s.sol:DeployFlashLoanL2" \
    --rpc-url "$L2_RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$WRAPPED_TOKEN_L2" 2>&1)
EXECUTOR_L2=$(extract "$L2_OUTPUT" "EXECUTOR_L2")
FLASH_LOANERS_NFT=$(extract "$L2_OUTPUT" "FLASH_LOANERS_NFT")
echo "EXECUTOR_L2=$EXECUTOR_L2"
echo "FLASH_LOANERS_NFT=$FLASH_LOANERS_NFT"

# ══════════════════════════════════════════════
#  Step 6: Deploy L1 contracts (FlashLoan pool + executor)
# ══════════════════════════════════════════════
echo ""
echo "====== Step 6: Deploy L1 contracts ======"
L1_OUTPUT=$(forge script "$SCRIPT_DIR/DeployFlashLoan.s.sol:DeployFlashLoanL1" \
    --rpc-url "$L1_RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address,address,address,uint256,address)" \
    "$ROLLUPS" "$BRIDGE_L1" "$EXECUTOR_L2" "$WRAPPED_TOKEN_L2" "$FLASH_LOANERS_NFT" "$BRIDGE_L2" "$L2_ROLLUP_ID" "$TOKEN" 2>&1)
FLASH_LOAN_POOL=$(extract "$L1_OUTPUT" "FLASH_LOAN_POOL")
EXECUTOR_L2_PROXY=$(extract "$L1_OUTPUT" "EXECUTOR_L2_PROXY")
EXECUTOR_L1=$(extract "$L1_OUTPUT" "EXECUTOR_L1")
echo "FLASH_LOAN_POOL=$FLASH_LOAN_POOL"
echo "EXECUTOR_L2_PROXY=$EXECUTOR_L2_PROXY"
echo "EXECUTOR_L1=$EXECUTOR_L1"

# ══════════════════════════════════════════════
#  Summary
# ══════════════════════════════════════════════
echo ""
echo "====== Deployment Complete ======"
echo ""
echo "L1 Contracts:"
echo "  TOKEN=$TOKEN"
echo "  BRIDGE_L1=$BRIDGE_L1"
echo "  FLASH_LOAN_POOL=$FLASH_LOAN_POOL"
echo "  EXECUTOR_L1=$EXECUTOR_L1"
echo "  EXECUTOR_L2_PROXY=$EXECUTOR_L2_PROXY"
echo ""
echo "L2 Contracts:"
echo "  BRIDGE_L2=$BRIDGE_L2"
echo "  EXECUTOR_L2=$EXECUTOR_L2"
echo "  FLASH_LOANERS_NFT=$FLASH_LOANERS_NFT"
echo "  WRAPPED_TOKEN_L2=$WRAPPED_TOKEN_L2 (pre-computed)"
echo ""
echo "To trigger the flash loan:"
echo "  cast send --rpc-url \$L1_RPC --private-key \$PK $EXECUTOR_L1 'execute()'"
