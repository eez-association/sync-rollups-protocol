#!/usr/bin/env bash
# End-to-end test: deploy on anvil, bridge ether, decode events.
# Run from project root: bash script/e2e/bridge/run-local.sh
source "$(dirname "$0")/../shared/E2EBase.sh"

RPC="http://localhost:8545"

# ── 1. Start anvil ──
start_anvil 8545 ANVIL_PID

# ── 2. Deploy infrastructure ──
deploy_infra "$RPC" "$PK"

# ── 3. Ensure CREATE2 factory ──
ensure_create2_factory "$RPC" "L1" "$PK"

# ── 4. Deploy bridge app ──
echo ""
echo "====== Deploy Bridge App ======"
DEPLOY_OUTPUT=$(forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

BRIDGE=$(extract "$DEPLOY_OUTPUT" "BRIDGE")
echo "Bridge: $BRIDGE"

# ── 5. Execute (postBatch + bridgeEther via BridgeBatcher) ──
echo ""
echo "====== Execute (postBatch + bridgeEther) ======"
forge script script/e2e/bridge/BridgeE2E.s.sol:BridgeExecute \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address)" "$ROLLUPS" "$BRIDGE" 2>&1 \
    | grep -E "done" || true

BLOCK=$(cast block-number --rpc-url "$RPC")

# ── 6. Decode ──
decode_block "$RPC" "$BLOCK" "$ROLLUPS"

echo ""
echo "====== Done ======"
