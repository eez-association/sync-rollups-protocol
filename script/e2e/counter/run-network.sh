#!/usr/bin/env bash
# Network mode: deploy counter app to an existing network, execute, verify post-facto.
#
# Usage (from project root):
#   bash script/e2e/counter/run-network.sh \
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

# ── 1. Deploy counter app ──
echo "====== Deploy Counter App ======"
DEPLOY_OUTPUT=$(forge script script/e2e/counter/CounterE2E.s.sol:CounterDeploy \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$ROLLUPS" 2>&1)

COUNTER_L2=$(extract "$DEPLOY_OUTPUT" "COUNTER_L2")
COUNTER_AND_PROXY=$(extract "$DEPLOY_OUTPUT" "COUNTER_AND_PROXY")
echo "CounterL2: $COUNTER_L2"
echo "CounterAndProxy: $COUNTER_AND_PROXY"

# ── 2. Compute expected entries ──
echo ""
echo "====== Compute Expected Entries ======"
COMPUTE_OUTPUT=$(forge script script/e2e/counter/CounterE2E.s.sol:CounterComputeExpected \
    --sig "run(address,address)" "$COUNTER_L2" "$COUNTER_AND_PROXY" 2>&1)
EXPECTED_HASHES=$(extract "$COMPUTE_OUTPUT" "EXPECTED_HASHES")
echo "Expected hashes: $EXPECTED_HASHES"

# ── 3. Execute user transaction (no Batcher — system handles batch posting) ──
echo ""
echo "====== Execute (incrementProxy) ======"
EXEC_OUTPUT=$(forge script script/e2e/counter/CounterE2E.s.sol:CounterExecuteNetwork \
    --rpc-url "$RPC" --broadcast --private-key "$PK" \
    --sig "run(address)" "$COUNTER_AND_PROXY" 2>&1) \
    && echo "Transaction succeeded" || echo "Transaction reverted (expected — system posts batch separately)"

BLOCK=$(cast block-number --rpc-url "$RPC")
echo "Execution at block $BLOCK"

# ── 4. Verify L1 BatchPosted contains our entry ──
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
