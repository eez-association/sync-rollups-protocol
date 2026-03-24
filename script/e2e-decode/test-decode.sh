#!/usr/bin/env bash
# End-to-end test: deploy on anvil, execute scenario 1, decode with DecodeExecutions
# Run from project root: bash script/e2e-decode/test-decode.sh
set -euo pipefail
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

RPC="http://localhost:8545"
PK="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

cleanup() {
    [[ -n "${ANVIL_PID:-}" ]] && kill "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Start anvil (all txs in one broadcast go in the same block) ──
echo "Starting anvil..."
anvil --silent &
ANVIL_PID=$!
sleep 1
echo "Anvil running (PID $ANVIL_PID)"

# ── 2. Deploy ──
echo ""
echo "====== Deploy ======"
DEPLOY_OUTPUT=$(forge script script/e2e-decode/E2EDecode.s.sol:E2EDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" 2>&1)

ROLLUPS=$(echo "$DEPLOY_OUTPUT" | grep "ROLLUPS=" | sed 's/.*ROLLUPS=//')
COUNTER_L2=$(echo "$DEPLOY_OUTPUT" | grep "COUNTER_L2=" | sed 's/.*COUNTER_L2=//')
COUNTER_AND_PROXY=$(echo "$DEPLOY_OUTPUT" | grep "COUNTER_AND_PROXY=" | sed 's/.*COUNTER_AND_PROXY=//')

echo "Rollups: $ROLLUPS"
echo "CounterL2: $COUNTER_L2"
echo "CounterAndProxy: $COUNTER_AND_PROXY"

# ── 3. postBatch + incrementProxy (same broadcast = same block) ──
echo ""
echo "====== Execute (postBatch + incrementProxy) ======"
forge script script/e2e-decode/E2EDecode.s.sol:E2EExecute \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address)" "$ROLLUPS" "$COUNTER_L2" "$COUNTER_AND_PROXY" 2>&1 \
    | grep -E "done|counter" || true

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
