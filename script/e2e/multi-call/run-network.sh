#!/usr/bin/env bash
# Network mode: deploy multi-call contracts to an existing network, execute, verify.
#
# Tests that an L1 contract making MULTIPLE cross-chain calls in a single
# execution works correctly (issue #256).
#
# Usage (from project root):
#   bash script/e2e/multi-call/run-network.sh \
#     --rpc <RPC_URL> \
#     --pk <PRIVATE_KEY> \
#     --rollups <ROLLUPS_ADDR> \
#     [--test calltwice|twodiff|all]
source "$(dirname "$0")/../shared/E2EBase.sh"

SCRIPT="script/e2e/multi-call/MultiCallE2E.s.sol"
TEST_MODE="all"

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rpc)     RPC="$2"; shift 2;;
        --pk)      PK="$2"; shift 2;;
        --rollups) ROLLUPS="$2"; shift 2;;
        --test)    TEST_MODE="$2"; shift 2;;
        *) echo "Unknown arg: $1"; exit 1;;
    esac
done

for var in RPC PK ROLLUPS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Missing required arg: --$(echo "$var" | tr '_' '-' | tr '[:upper:]' '[:lower:]')"
        exit 1
    fi
done

# ── 1. Deploy app contracts ──
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

# ── 2. Compute expected entries ──
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUTPUT=$(forge script "$SCRIPT:MultiCallComputeExpected" \
    --sig "run(address,address,address,address)" \
    "$COUNTER_A" "$COUNTER_B" "$CALL_TWICE" "$CALL_TWO_DIFF" 2>&1)

EXPECTED_HASHES_CALL_TWICE=$(extract "$COMPUTE_OUTPUT" "EXPECTED_HASHES_CALL_TWICE")
EXPECTED_HASHES_TWO_DIFF=$(extract "$COMPUTE_OUTPUT" "EXPECTED_HASHES_TWO_DIFF")
echo "CallTwice hashes:      $EXPECTED_HASHES_CALL_TWICE"
echo "CallTwoDifferent hashes: $EXPECTED_HASHES_TWO_DIFF"

FAILED=0

# ── 3. Test A: CallTwice ──
if [[ "$TEST_MODE" == "all" || "$TEST_MODE" == "calltwice" ]]; then
    echo ""
    echo "====== Test A: CallTwice (same proxy x2) ======"
    EXEC_OUTPUT=$(forge script "$SCRIPT:MultiCallExecuteNetworkCallTwice" \
        --rpc-url "$RPC" --broadcast --private-key "$PK" \
        --sig "run(address,address)" "$CALL_TWICE" "$PROXY_A" 2>&1) \
        && echo "Transaction succeeded" || echo "Transaction reverted (expected — system posts batch separately)"

    BLOCK=$(cast block-number --rpc-url "$RPC")
    echo "Execution at block $BLOCK"

    echo ""
    echo "====== Verify Test A (block $BLOCK) ======"
    VERIFY_OUTPUT=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
        --rpc-url "$RPC" \
        --sig "run(uint256,address,bytes32[])" "$BLOCK" "$ROLLUPS" "$EXPECTED_HASHES_CALL_TWICE" 2>&1) \
        && VERIFY_OK=true || VERIFY_OK=false

    if $VERIFY_OK; then
        echo "$VERIFY_OUTPUT" | grep "PASS"
    else
        echo "$VERIFY_OUTPUT" | strip_traces
        echo ""
        echo "$COMPUTE_OUTPUT" | sed -n '/=== EXPECTED: CallTwice/,/^$/p'
        FAILED=1
    fi
fi

# ── 4. Test B: CallTwoDifferent ──
if [[ "$TEST_MODE" == "all" || "$TEST_MODE" == "twodiff" ]]; then
    echo ""
    echo "====== Test B: CallTwoDifferent (two proxies) ======"
    EXEC_OUTPUT=$(forge script "$SCRIPT:MultiCallExecuteNetworkTwoDiff" \
        --rpc-url "$RPC" --broadcast --private-key "$PK" \
        --sig "run(address,address,address)" "$CALL_TWO_DIFF" "$PROXY_A" "$PROXY_B" 2>&1) \
        && echo "Transaction succeeded" || echo "Transaction reverted (expected — system posts batch separately)"

    BLOCK=$(cast block-number --rpc-url "$RPC")
    echo "Execution at block $BLOCK"

    echo ""
    echo "====== Verify Test B (block $BLOCK) ======"
    VERIFY_OUTPUT=$(forge script script/e2e/shared/Verify.s.sol:VerifyL1Batch \
        --rpc-url "$RPC" \
        --sig "run(uint256,address,bytes32[])" "$BLOCK" "$ROLLUPS" "$EXPECTED_HASHES_TWO_DIFF" 2>&1) \
        && VERIFY_OK=true || VERIFY_OK=false

    if $VERIFY_OK; then
        echo "$VERIFY_OUTPUT" | grep "PASS"
    else
        echo "$VERIFY_OUTPUT" | strip_traces
        echo ""
        echo "$COMPUTE_OUTPUT" | sed -n '/=== EXPECTED: CallTwoDifferent/,/^$/p'
        FAILED=1
    fi
fi

# ── Summary ──
echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "====== All Tests Passed ======"
else
    echo "====== FAILED ======"
    exit 1
fi
