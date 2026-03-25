# Flash Loan Deployment

Deploys the cross-chain flash loan demo across L1 and L2: Bridge, TestToken, FlashLoan pool, FlashLoanBridgeExecutor, and FlashLoanersNFT.

## Prerequisites

- Rollups deployed on L1
- CrossChainManagerL2 deployed on L2
- Private key with ETH on both chains

## Deploy

```bash
bash script/deployment/flash-loan/deploy-app.sh \
    --l1-rpc $L1_RPC \
    --l2-rpc $L2_RPC \
    --pk $PK \
    --rollups $ROLLUPS \
    --manager-l2 $MANAGER_L2 \
    --l2-rollup-id 1
```

### What it deploys

| Step | Chain | Contracts |
|------|-------|-----------|
| 0 | L1 + L2 | CREATE2 factory (if missing) |
| 1 | L1 | TestToken (1M supply) + Bridge (CREATE2) |
| 2 | L2 | Bridge (same CREATE2 address) |
| 3 | L1 + L2 | Set canonical bridge addresses (cross-chain refs) |
| 4 | - | Pre-compute WrappedToken L2 address |
| 5 | L2 | FlashLoanBridgeExecutor + FlashLoanersNFT |
| 6 | L1 | FlashLoan pool (funded 10k tokens) + CrossChainProxy for executorL2 + FlashLoanBridgeExecutor |

### Output

The script prints all deployed addresses:

```
TOKEN=0x...
BRIDGE_L1=0x...
BRIDGE_L2=0x...
FLASH_LOAN_POOL=0x...
EXECUTOR_L1=0x...
EXECUTOR_L2=0x...
EXECUTOR_L2_PROXY=0x...
FLASH_LOANERS_NFT=0x...
WRAPPED_TOKEN_L2=0x...
TOKEN_NAME=Test Token
TOKEN_SYMBOL=TT
TOKEN_DECIMALS=18
```

## Trigger the Flash Loan

After deployment, trigger the flash loan by calling `execute()` on the L1 executor:

```bash
cast send --rpc-url $L1_RPC --private-key $PK $EXECUTOR_L1 'execute()'
```

This initiates the full cross-chain flow:

1. L1: Request flash loan (borrow 10k tokens from pool)
2. L1: Bridge tokens to L2 via `Bridge.bridgeTokens()`
3. L2: Receive tokens, claim FlashLoanersNFT, bridge tokens back
4. L1: Receive returned tokens, repay flash loan

On a real network, the system/sequencer posts the batch and loads execution tables in the same block. The `execute()` call triggers the user-side flow that consumes those entries.

## E2E Test

To run the full end-to-end test (deploy + execute + verify):

```bash
# Local (anvil)
bash script/e2e/shared/run-local.sh script/e2e/flash-loan/E2E.s.sol

# Network
bash script/e2e/shared/run-network.sh script/e2e/flash-loan/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2
```
