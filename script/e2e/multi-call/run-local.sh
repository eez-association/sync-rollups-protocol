#!/usr/bin/env bash
# End-to-end test: multi-call cross-chain scenarios (issue #256).
# Tests that an L1 contract making MULTIPLE cross-chain calls in a single
# execution works correctly.
#
# Test A: CallTwice → same proxy called twice → counter increments by 2
# Test B: CallTwoDifferent → two different proxies → each counter increments by 1
#
# Run from project root: bash script/e2e/multi-call/run-local.sh
source "$(dirname "$0")/../shared/E2EBase.sh"

SCRIPT="script/e2e/multi-call/MultiCallE2E.s.sol"
RPC="http://localhost:8545"

# ── 1. Start anvil ──
start_anvil 8545 ANVIL_PID

# ── 2. Deploy infrastructure ──
deploy_infra "$RPC" "$PK"

# ── 3. Deploy multi-call app contracts ──
echo ""
echo "====== Deploy Multi-Call Contracts ======"
DEPLOY_OUTPUT=$(forge script "$SCRIPT:MultiCallDeploy" \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

COUNTER_A=$(extract "$DEPLOY_OUTPUT" "COUNTER_A")
COUNTER_B=$(extract "$DEPLOY_OUTPUT" "COUNTER_B")
CALL_TWICE=$(extract "$DEPLOY_OUTPUT" "CALL_TWICE")
CALL_TWO_DIFF=$(extract "$DEPLOY_OUTPUT" "CALL_TWO_DIFF")
PROXY_A=$(extract "$DEPLOY_OUTPUT" "PROXY_A")
PROXY_B=$(extract "$DEPLOY_OUTPUT" "PROXY_B")

echo "Counter A:         $COUNTER_A"
echo "Counter B:         $COUNTER_B"
echo "CallTwice:         $CALL_TWICE"
echo "CallTwoDifferent:  $CALL_TWO_DIFF"
echo "Proxy A:           $PROXY_A"
echo "Proxy B:           $PROXY_B"

# ── 4. Test A: CallTwice (same proxy x2) ──
echo ""
echo "====== Test A: CallTwice (same proxy x2) ======"
forge script "$SCRIPT:MultiCallExecuteCallTwice" \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address)" \
    "$ROLLUPS" "$COUNTER_A" "$CALL_TWICE" "$PROXY_A" 2>&1 \
    | grep -E "done|first|second" || true

BLOCK_A=$(cast block-number --rpc-url "$RPC")
decode_block "$RPC" "$BLOCK_A" "$ROLLUPS" "Test A "

# ── 5. Test B: CallTwoDifferent (two different proxies) ──
# NOTE: Rollups state was updated by Test A. Test B entries use the
# current state as their starting point. We need a fresh infra deployment
# for a clean state, or accept that Test B runs independently. For
# simplicity in local mode, we redeploy infra for a clean state.
echo ""
echo "====== Redeploy infra for Test B (clean state) ======"
deploy_infra "$RPC" "$PK"

# Redeploy app contracts against new Rollups
DEPLOY_OUTPUT=$(forge script "$SCRIPT:MultiCallDeploy" \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

COUNTER_A=$(extract "$DEPLOY_OUTPUT" "COUNTER_A")
COUNTER_B=$(extract "$DEPLOY_OUTPUT" "COUNTER_B")
CALL_TWO_DIFF=$(extract "$DEPLOY_OUTPUT" "CALL_TWO_DIFF")
PROXY_A=$(extract "$DEPLOY_OUTPUT" "PROXY_A")
PROXY_B=$(extract "$DEPLOY_OUTPUT" "PROXY_B")

echo ""
echo "====== Test B: CallTwoDifferent (two proxies) ======"
forge script "$SCRIPT:MultiCallExecuteTwoDiff" \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address,address,address,address,address,address)" \
    "$ROLLUPS" "$COUNTER_A" "$COUNTER_B" "$CALL_TWO_DIFF" "$PROXY_A" "$PROXY_B" 2>&1 \
    | grep -E "done|counterA|counterB" || true

BLOCK_B=$(cast block-number --rpc-url "$RPC")
decode_block "$RPC" "$BLOCK_B" "$ROLLUPS" "Test B "

echo ""
echo "====== Done ======"
