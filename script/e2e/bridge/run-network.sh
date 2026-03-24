#!/usr/bin/env bash
# Network mode: deploy bridge to an existing network, bridge ether, verify post-facto.
#
# Usage (from project root):
#   bash script/e2e/bridge/run-network.sh \
#     --rpc <RPC_URL> \
#     --pk <PRIVATE_KEY> \
#     --rollups <ROLLUPS_ADDR>
source "$(dirname "$0")/../shared/E2EBase.sh"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)     RPC="$2"; shift 2;;
        --pk)      PK="$2"; shift 2;;
        --rollups) ROLLUPS="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in RPC PK ROLLUPS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ── 1. Ensure CREATE2 factory ──
ensure_create2_factory "$RPC" "L1" "$PK"

# ── 2. Deploy bridge app ──
echo "====== Deploy Bridge App ======"
DEPLOY_OUTPUT=$(forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

BRIDGE=$(extract "$DEPLOY_OUTPUT" "BRIDGE")
DEPLOYER=$(cast wallet address --private-key "$PK")
echo "Bridge: $BRIDGE"
echo "Deployer: $DEPLOYER"

# ── 3. Compute expected entries ──
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUTPUT=$(forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeComputeExpected \
    --sig "run(address,address)" "$BRIDGE" "$DEPLOYER" 2>&1)
EXPECTED_HASHES=$(extract "$COMPUTE_OUTPUT" "EXPECTED_HASHES")
echo "Expected hashes: $EXPECTED_HASHES"

# ── 4. Execute user transaction (no Batcher) ──
echo ""
echo "====== Execute (bridgeEther) ======"
EXEC_OUTPUT=$(forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeExecuteNetwork \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,uint256,address)" "$BRIDGE" 1 "$DEPLOYER" 2>&1) \
    && echo "Transaction succeeded" || echo "Transaction reverted (expected — system posts batch separately)"

BLOCK=$(cast block-number --rpc-url "$RPC")
echo "Execution at block $BLOCK"

# ── 5. Verify L1 BatchPosted contains our entry ──
echo ""
echo "====== Verify L1 Batch (block $BLOCK) ======"
VERIFY_OUTPUT=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
    --rpc-url "$RPC" \
    --sig "run(uint256,address,bytes32[])" "$BLOCK" "$ROLLUPS" "$EXPECTED_HASHES" 2>&1) \
    && VERIFY_OK=true || VERIFY_OK=false

if $VERIFY_OK; then
    echo "$VERIFY_OUTPUT" | grep "PASS"
    echo ""
    echo "====== Done ======"
else
    echo "$VERIFY_OUTPUT" | strip_traces
    echo ""
    echo "$COMPUTE_OUTPUT" | sed -n '/=== EXPECTED/,$ p'
    echo ""
    echo "====== FAILED ======"
    exit 1
fi
