#!/usr/bin/env bash
# End-to-end test: deploy bridge on anvil, bridge ether, decode with DecodeExecutions
# Run from project root: bash script/e2e-decode/test-bridge-decode.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC="http://localhost:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cleanup() {
    [[ -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Start anvil ──
echo "Starting anvil..."
anvil --silent &
ANVIL_PID=$!
sleep 1
echo "Anvil running (PID $ANVIL_PID)"

# ── 2. Deploy ──
echo ""
echo "====== Deploy ======"
DEPLOY_OUTPUT=$(forge script script/e2e-decode/E2EBridgeDecode.s.sol:E2EBridgeDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" 2>&1)

ROLLUPS=$(echo "$DEPLOY_OUTPUT" | grep "ROLLUPS=" | sed 's/.*ROLLUPS=//')
BRIDGE=$(echo "$DEPLOY_OUTPUT" | grep "BRIDGE=" | sed 's/.*BRIDGE=//')

echo "Rollups: $ROLLUPS"
echo "Bridge: $BRIDGE"

# ── 3. postBatch + bridgeEther (same broadcast = same block) ──
echo ""
echo "====== Execute (postBatch + bridgeEther) ======"
forge script script/e2e-decode/E2EBridgeDecode.s.sol:E2EBridgeExecute \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address)" "$ROLLUPS" "$BRIDGE" 2>&1 \
    | grep -E "done" || true

BLOCK=$(cast block-number --rpc-url "$RPC")

# ── 4. Decode ──
echo ""
echo "====== DecodeExecutions.runBlock($BLOCK, $ROLLUPS) ======"
echo ""

forge script script/DecodeExecutions.s.sol:DecodeExecutions \
    --rpc-url "$RPC" \
    --sig "runBlock(uint256,address)" "$BLOCK" "$ROLLUPS" 2>&1 \
    | sed -n '/^  /p'

echo ""
echo "====== Done ======"
