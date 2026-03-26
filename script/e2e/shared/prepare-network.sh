#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Prepare a devnet for network-mode e2e tests
# ═══════════════════════════════════════════════════════════════════════
#
# Ensures the devnet has:
#   1. CREATE2 factory on L1
#   2. Test account funded with ETH on L2 (bridges from L1 if needed)
#   3. CREATE2 factory on L2
#
# Idempotent — skips steps that are already done.
#
# ── Usage ──
#   bash script/e2e/shared/prepare-network.sh \
#     --l1-rpc <L1_RPC> --l2-rpc <L2_RPC> --pk <PK> --rollups <ROLLUPS>
#
source "$(dirname "$0")/E2EBase.sh"

# ── Parse CLI args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --l1-rpc)   export L1_RPC="$2"; shift 2;;
        --l2-rpc)   export L2_RPC="$2"; shift 2;;
        --pk)       export PK="$2"; shift 2;;
        --rollups)  export ROLLUPS="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in L1_RPC L2_RPC PK ROLLUPS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

SENDER_ADDRESS=$(cast wallet address --private-key "$PK")
echo "Sender address: $SENDER_ADDRESS"

# ══════════════════════════════════════════════
#  1. Deploy CREATE2 factory on L1
# ══════════════════════════════════════════════
echo ""
echo "====== Step 1: CREATE2 Factory (L1) ======"
ensure_create2_factory "$L1_RPC" "L1" "$PK"

# ══════════════════════════════════════════════
#  2. Fund test account on L2
#     Check L2 balance — if zero or very low,
#     bridge ETH from L1 via cross-chain proxy.
# ══════════════════════════════════════════════
echo ""
echo "====== Step 2: Fund L2 Account ======"
L2_BALANCE=$(cast balance "$SENDER_ADDRESS" --rpc-url "$L2_RPC")
echo "Current L2 balance: $L2_BALANCE wei"

# Threshold: 0.01 ETH (10^16 wei)
MIN_BALANCE="10000000000000000"

if [[ "$L2_BALANCE" == "0" ]] || [[ $(echo "$L2_BALANCE < $MIN_BALANCE" | bc) -eq 1 ]]; then
    echo "L2 balance is insufficient, bridging 1 ETH from L1..."

    # Create a cross-chain proxy on L1 for our address on L2 (rollup ID 1)
    echo "Creating cross-chain proxy on L1..."
    cast send "$ROLLUPS" "createCrossChainProxy(address,uint256)" \
        "$SENDER_ADDRESS" 1 \
        --private-key "$PK" --rpc-url "$L1_RPC" > /dev/null 2>&1 || true

    # Compute the proxy address
    PROXY_ADDRESS=$(cast call "$ROLLUPS" \
        "computeCrossChainProxyAddress(address,uint256)(address)" \
        "$SENDER_ADDRESS" 1 \
        --rpc-url "$L1_RPC")
    echo "Proxy address: $PROXY_ADDRESS"

    # Send 1 ETH to the proxy — this triggers a cross-chain call that the
    # system intercepts. The tx will revert in simulation, so we hardcode gas.
    echo "Sending 1 ETH to proxy on L1 (triggers bridge)..."
    cast send "$PROXY_ADDRESS" \
        --value 1ether \
        --gas-limit 500000 \
        --private-key "$PK" --rpc-url "$L1_RPC" > /dev/null 2>&1 || true

    # Wait for the system to bridge the funds
    echo "Waiting for bridge to complete..."
    sleep 10

    # Verify L2 balance increased
    L2_BALANCE_AFTER=$(cast balance "$SENDER_ADDRESS" --rpc-url "$L2_RPC")
    echo "L2 balance after bridge: $L2_BALANCE_AFTER wei"

    if [[ "$L2_BALANCE_AFTER" == "0" ]] || [[ $(echo "$L2_BALANCE_AFTER < $MIN_BALANCE" | bc) -eq 1 ]]; then
        echo "WARNING: L2 balance is still low after bridging. The system may need more time."
    else
        echo "L2 funding successful"
    fi
else
    echo "L2 balance is sufficient, skipping bridge"
fi

# ══════════════════════════════════════════════
#  3. Deploy CREATE2 factory on L2
# ══════════════════════════════════════════════
echo ""
echo "====== Step 3: CREATE2 Factory (L2) ======"
ensure_create2_factory "$L2_RPC" "L2" "$PK"

echo ""
echo "====== Network Prepared ======"
