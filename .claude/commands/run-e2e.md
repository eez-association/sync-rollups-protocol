# Daily E2E Test & Issue Workflow

Run all e2e tests against the devnet one by one. Diagnose failures using decode-block and error decoding. File results as TODO_FIXES (test bugs) or gh_issue/ files (contract/system bugs).

## Environment

Environment variables (`L1_RPC`, `L2_RPC`, `PK`, `ROLLUPS`, `MANAGER_L2`) must be provided before running. Check these sources in order:

1. **`.devnet.md`** — if it exists, read it and use the values defined there.
2. **User input** — if `.devnet.md` doesn't exist, ask the user to provide the values (or point to a file containing them).

Do NOT proceed without all five variables set.

## IMPORTANT: Sequential Execution Only

**DO NOT run tests in parallel.** All tests share the same deployer account and devnet nonce. Running in parallel causes nonce conflicts and spurious failures.

## Steps

### 1. Check devnet is up
Run `cast block-number` on both L1 and L2 RPCs. If either is down, stop and notify user.

**Block 0 = chain not running.** If L1 or L2 returns block number 0, it means the chain is stuck at genesis and not producing blocks. Wait ~5 seconds and retry once. If still 0, stop immediately and tell the user which chain appears down — do NOT proceed with prepare-network or any tests (it will just produce confusing errors like CREATE2 factory deploy failures).

### 2. Prepare output folders
```bash
rm -rf tmp/e2e-failures tmp/e2e-success && mkdir -p tmp/e2e-failures tmp/e2e-success
```

### 3. Prepare network
```bash
bash script/e2e/shared/prepare-network.sh \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK --rollups $ROLLUPS
```

### 4. Run each e2e test (one by one, ordered by difficulty)

Tests in order (simplest → most complex):
1. `script/e2e/counter/E2E.s.sol` — L1→L2 simple
2. `script/e2e/counterL2/E2E.s.sol` — L2→L1 simple
3. `script/e2e/bridge/E2E.s.sol` — L1→L2 with ETH transfer
4. `script/e2e/multi-call-twice/E2E.s.sol` — L1→L2 two sequential calls (same target)
5. `script/e2e/multi-call-two-diff/E2E.s.sol` — L1→L2 two calls (different targets)
6. `script/e2e/nestedCounter/E2E.s.sol` — L1→L2→L1 nested (scope)
7. `script/e2e/nestedCounterL2/E2E.s.sol` — L2→L1→L2 nested (scope)
8. `script/e2e/flash-loan/E2E.s.sol` — L1→L2→L1 with tokens (most complex)

Command:
```bash
bash script/e2e/shared/run-network.sh script/e2e/<test>/E2E.s.sol \
    --l1-rpc $L1_RPC --l2-rpc $L2_RPC --pk $PK \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2 2>&1 \
    | tee tmp/e2e-failures/<test>-output.txt
```

Save output to `tmp/e2e-failures/<test>-output.txt` first. If the test passes, move it to `tmp/e2e-success/`. If it fails, keep it in `tmp/e2e-failures/`. Any diagnosis output (like decode-block) also goes to `tmp/e2e-failures/`.

This way `tmp/e2e-failures/` only has failures + their diagnosis, and `tmp/e2e-success/` has passes for reference.

### 5. On failure — diagnose

#### 5a. Decode the block
Use the block numbers from the test output:
```bash
bash script/e2e/shared/decode-block.sh \
    --l1-block <BLOCK> --l1-rpc $L1_RPC --l2-rpc $L2_RPC \
    --rollups $ROLLUPS --manager-l2 $MANAGER_L2 2>&1 \
    | tee tmp/e2e-failures/<BLOCK>_<test>_decode.txt
```

Save decode output to `tmp/e2e-failures/<blockNum>_<testName>_decode.txt` (always in failures — it's diagnosing a failed test).

#### 5b. Decode error selectors
If the batch has `failed: true` with error data, decode it:
```bash
cast 4byte <selector>
```

Common errors:
- `0xed6bc750` = `ExecutionNotFound()` — no matching entry in the execution table
- `0xf9d330ad` = `ExecutionNotInCurrentBlock()` — entry exists but not in the current block's batch

#### 5c. Compare against the spec
Read `EXECUTION_TABLE_SPEC.md` and check:
- **Trigger type**: L2→L1 flows MUST use `L2TX` trigger on L1, never `CALL` from system address
- **System address**: Must NEVER appear as `sourceAddress` in L1 `CrossChainCallExecuted` events
- **Chaining**: Multi-call scenarios must chain RESULT→CALL on L2 (not independent terminal entries)
- **Scope entries**: Nested flows (L1→L2→L1) must have ALL scope entries in the same batch
- **Terminal entries**: Must propagate return data, not have empty data
- **1-to-1 rule**: Each user action = exactly 1 execution tx per chain involved

### 6. Classify failures

**Test script bug** (wrong expected hashes, wrong action construction, missing deploy):
- Append to `script/e2e/TODO_FIXES.md` with: test name, what's wrong, decoded errors, what to fix.

**Contract/system bug** (wrong trigger type, missing entries, spec violation):
- Write an issue file in `gh_issue/` following format from `gh_issue/gh-issue-guide.md`
- Filename: `gh_issue/<test-name>-<short-description>.md`
- **NEVER include explicit RPC URLs, private keys, or secrets in issue files.** Use variable names like `$RPC_L1`, `$RPC_L2`, `$PK`, `$ROLLUPS`, `$MANAGER_L2`.
- Include decoded error selectors and what they mean
- Include relevant decode-block excerpts

### 7. Report summary

Print a table:

| Test | Result | Action |
|------|--------|--------|
| counter | PASS/FAIL | none / TODO_FIX / gh_issue |
| ... | ... | ... |
