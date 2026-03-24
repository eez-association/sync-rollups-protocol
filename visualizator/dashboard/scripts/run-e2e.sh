#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Cross-Chain Dashboard E2E Test
#
# Starts 2 Anvil nodes, deploys contracts, runs Scenario 1,
# updates dashboard config, starts dev server.
#
# Usage: ./scripts/run-e2e.sh
# ═══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$DASHBOARD_DIR/../.." && pwd)"

L1_RPC="http://localhost:8545"
L2_RPC="http://localhost:8546"
# Anvil default account 0
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
SYSTEM_ADDRESS="0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF"
DEPLOY_SCRIPT="visualizator/dashboard/scripts/Deploy.s.sol"

cd "$ROOT_DIR"

echo "=== Cross-Chain Dashboard E2E Test ==="
echo ""

# ─── Helper: parse address from forge output ───
parse_addr() {
    local output="$1"
    local var_name="$2"
    echo "$output" | grep "${var_name}=" | sed "s/.*${var_name}=//" | tr -d '[:space:]'
}

# ─── 1. Start Anvil nodes ───
echo "[1/7] Starting Anvil nodes..."

lsof -ti:8545 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -ti:8546 2>/dev/null | xargs kill -9 2>/dev/null || true
sleep 1

anvil --port 8545 --chain-id 31337 --silent &
ANVIL_L1_PID=$!

anvil --port 8546 --chain-id 31338 --silent &
ANVIL_L2_PID=$!

cleanup() {
    echo ""
    echo "Cleaning up Anvil nodes..."
    kill $ANVIL_L1_PID 2>/dev/null || true
    kill $ANVIL_L2_PID 2>/dev/null || true
}
trap cleanup EXIT

sleep 2
echo "  L1 Anvil PID=$ANVIL_L1_PID (port 8545, chainId 31337)"
echo "  L2 Anvil PID=$ANVIL_L2_PID (port 8546, chainId 31338)"

# ─── 2. Deploy L2 base (ManagerL2 + CounterL2) ───
echo ""
echo "[2/7] Deploying L2 base contracts..."

L2_BASE_OUTPUT=$(forge script "$DEPLOY_SCRIPT:DeployL2Base" \
    --rpc-url "$L2_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1)

MANAGER_L2=$(parse_addr "$L2_BASE_OUTPUT" "MANAGER_L2")
COUNTER_L2=$(parse_addr "$L2_BASE_OUTPUT" "COUNTER_L2")

echo "  ManagerL2:  $MANAGER_L2"
echo "  CounterL2 (B): $COUNTER_L2"

if [ -z "$MANAGER_L2" ] || [ -z "$COUNTER_L2" ]; then
    echo "ERROR: Failed to parse L2 addresses"
    echo "$L2_BASE_OUTPUT"
    exit 1
fi

# ─── 3. Deploy L1 (Rollups + CounterL1 + proxies + A) ───
echo ""
echo "[3/7] Deploying L1 contracts..."

L1_OUTPUT=$(COUNTER_L2="$COUNTER_L2" forge script "$DEPLOY_SCRIPT:DeployL1" \
    --rpc-url "$L1_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1)

ROLLUPS=$(parse_addr "$L1_OUTPUT" "ROLLUPS")
COUNTER_L1=$(parse_addr "$L1_OUTPUT" "COUNTER_L1")
COUNTER_PROXY=$(parse_addr "$L1_OUTPUT" "COUNTER_PROXY")
COUNTER_AND_PROXY=$(parse_addr "$L1_OUTPUT" "COUNTER_AND_PROXY")

echo "  Rollups:          $ROLLUPS"
echo "  CounterL1 (C):    $COUNTER_L1"
echo "  CounterProxy (B'): $COUNTER_PROXY"
echo "  CounterAndProxy (A): $COUNTER_AND_PROXY"

if [ -z "$ROLLUPS" ] || [ -z "$COUNTER_AND_PROXY" ]; then
    echo "ERROR: Failed to parse L1 addresses"
    echo "$L1_OUTPUT"
    exit 1
fi

# ─── 4. Deploy L2 apps (C' proxy + D) ───
echo ""
echo "[4/7] Deploying L2 application contracts..."

L2_APPS_OUTPUT=$(COUNTER_L1="$COUNTER_L1" MANAGER_L2="$MANAGER_L2" \
    forge script "$DEPLOY_SCRIPT:DeployL2Apps" \
    --rpc-url "$L2_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1)

COUNTER_PROXY_L2=$(parse_addr "$L2_APPS_OUTPUT" "COUNTER_PROXY_L2")
COUNTER_AND_PROXY_L2=$(parse_addr "$L2_APPS_OUTPUT" "COUNTER_AND_PROXY_L2")

echo "  CounterProxyL2 (C'): $COUNTER_PROXY_L2"
echo "  CounterAndProxyL2 (D): $COUNTER_AND_PROXY_L2"

# ─── 5. Run Scenario 1 — L2 Phase (SYSTEM operations) ───
echo ""
echo "[5/7] Running Scenario 1 — L2 Phase..."
echo "  Impersonating SYSTEM address for L2 operations..."

# Fund SYSTEM address on L2 so it can send txs
cast send --private-key "$PRIVATE_KEY" --rpc-url "$L2_RPC" \
    "$SYSTEM_ADDRESS" --value 10ether > /dev/null 2>&1

# Impersonate SYSTEM on L2 Anvil
cast rpc anvil_impersonateAccount "$SYSTEM_ADDRESS" --rpc-url "$L2_RPC" > /dev/null 2>&1

# Run L2 phase as SYSTEM
S1_L2_OUTPUT=$(MANAGER_L2="$MANAGER_L2" COUNTER_L2="$COUNTER_L2" \
    COUNTER_AND_PROXY="$COUNTER_AND_PROXY" \
    forge script "$DEPLOY_SCRIPT:Scenario1_L2" \
    --rpc-url "$L2_RPC" \
    --sender "$SYSTEM_ADDRESS" \
    --unlocked \
    --broadcast 2>&1)

cast rpc anvil_stopImpersonatingAccount "$SYSTEM_ADDRESS" --rpc-url "$L2_RPC" > /dev/null 2>&1

echo "$S1_L2_OUTPUT" | grep -E "(B\.counter|pending)" || true

# Check for errors
if echo "$S1_L2_OUTPUT" | grep -q "Error\|revert\|FAIL"; then
    echo "ERROR: L2 phase failed!"
    echo "$S1_L2_OUTPUT"
    exit 1
fi

# ─── 6. Run Scenario 1 — L1 Phase ───
echo ""
echo "[6/7] Running Scenario 1 — L1 Phase..."

S1_L1_OUTPUT=$(ROLLUPS="$ROLLUPS" COUNTER_L2="$COUNTER_L2" \
    COUNTER_AND_PROXY="$COUNTER_AND_PROXY" \
    forge script "$DEPLOY_SCRIPT:Scenario1_L1" \
    --rpc-url "$L1_RPC" \
    --private-key "$PRIVATE_KEY" \
    --broadcast 2>&1)

echo "$S1_L1_OUTPUT" | grep -E "(A\.counter|A\.target)" || true

if echo "$S1_L1_OUTPUT" | grep -q "Error\|revert\|FAIL"; then
    echo "ERROR: L1 phase failed!"
    echo "$S1_L1_OUTPUT"
    exit 1
fi

# ─── 7. Update dashboard config and print summary ───
echo ""
echo "[7/7] Updating dashboard config..."

cat > "$DASHBOARD_DIR/public/config.json" << EOF
{
  "l1RpcUrl": "$L1_RPC",
  "l2RpcUrl": "$L2_RPC",
  "l1ContractAddress": "$ROLLUPS",
  "l2ContractAddress": "$MANAGER_L2"
}
EOF

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  E2E Deployment Complete!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  L1 Contracts (port 8545):"
echo "    Rollups:           $ROLLUPS"
echo "    Counter (C):       $COUNTER_L1"
echo "    CounterProxy (B'): $COUNTER_PROXY"
echo "    CounterAndProxy (A): $COUNTER_AND_PROXY"
echo ""
echo "  L2 Contracts (port 8546):"
echo "    ManagerL2:         $MANAGER_L2"
echo "    Counter (B):       $COUNTER_L2"
echo "    CounterProxyL2 (C'): $COUNTER_PROXY_L2"
echo "    CounterAndProxyL2 (D): $COUNTER_AND_PROXY_L2"
echo ""
echo "  Dashboard config: $DASHBOARD_DIR/public/config.json"
echo ""
echo "  To start dashboard:  cd $DASHBOARD_DIR && npm run dev"
echo "  Anvil nodes are running. Press Ctrl+C to stop."
echo ""

# Keep Anvil nodes alive
wait
