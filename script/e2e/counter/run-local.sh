#!/usr/bin/env bash
# End-to-end test: deploy on anvil, execute counter scenario, decode events.
# Run from project root: bash script/e2e/counter/run-local.sh
source "$(dirname "$0")/../shared/E2EBase.sh"

RPC="http://localhost:8545"

# ── 1. Start anvil ──
start_anvil 8545 ANVIL_PID

# ── 2. Deploy infrastructure ──
deploy_infra "$RPC" "$PK"

# ── 3. Deploy counter app ──
echo ""
echo "====== Deploy Counter App ======"
DEPLOY_OUTPUT=$(forge script script/e2e/counter/CounterE2E.s.sol:CounterDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

COUNTER_L2=$(extract "$DEPLOY_OUTPUT" "COUNTER_L2")
COUNTER_AND_PROXY=$(extract "$DEPLOY_OUTPUT" "COUNTER_AND_PROXY")

echo "CounterL2: $COUNTER_L2"
echo "CounterAndProxy: $COUNTER_AND_PROXY"

# ── 4. Execute (postBatch + incrementProxy via Batcher) ──
echo ""
echo "====== Execute (postBatch + incrementProxy) ======"
forge script script/e2e/counter/CounterE2E.s.sol:CounterExecute \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address)" "$ROLLUPS" "$COUNTER_L2" "$COUNTER_AND_PROXY" 2>&1 \
    | grep -E "done|counter" || true

BLOCK=$(cast block-number --rpc-url "$RPC")

# ── 5. Decode ──
decode_block "$RPC" "$BLOCK" "$ROLLUPS"

echo ""
echo "====== Done ======"
