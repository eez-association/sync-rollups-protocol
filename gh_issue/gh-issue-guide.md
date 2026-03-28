# Guide: Creating GitHub Issues from Problem Files

## Prerequisites

```bash
# Install gh CLI (if not already)
# https://cli.github.com/

# Authenticate
gh auth login
```

## Repo

All issues go to: `https://github.com/eez-association/sync-rollup-composer`

## Check Devnet Health

Before creating an issue, verify the devnet is alive and capture the running git commit:

```bash
curl -s https://eez.dev/health
```

This returns the current git commit of the deployed devnet. Include this commit in the issue body so the team knows exactly which version exhibited the bug.

## Creating an Issue from a Problem File

Each problem file in `gh_issue/` can be used directly as the issue body:

```bash
gh issue create \
  --repo https://github.com/eez-association/sync-rollup-composer \
  --title "[bug] Short description here" \
  --label "bug" \
  --body-file gh_issue/my-problem-file.md
```

The `--body-file` flag reads the markdown file as the issue body — no need to inline it.

## IMPORTANT: No Secrets in Issue Files

Issue files are published to GitHub. **NEVER** include:
- Explicit RPC URLs (use `$RPC_L1`, `$RPC_L2`)
- Private keys (use `$PK`)
- Contract addresses from the devnet (use `$ROLLUPS`, `$MANAGER_L2`)
- Any credentials or tokens

Use variable names so the reader knows what goes where without exposing actual values.

## Adding Labels

Use `--label` (comma-separated or repeated):

```bash
--label "bug,cross-chain"
--label "bug" --label "cross-chain"
```

Available labels on the repo: `bug`, `documentation`, `duplicate`, `enhancement`, `good first issue`, `help wanted`, `invalid`, `question`, `wontfix`.

Note: `cross-chain`, `P1-high`, `contracts` do NOT exist yet. Use `bug` for now. Create new labels via `gh api` if needed:
```bash
gh api repos/eez-association/sync-rollup-composer/labels -f name="cross-chain" -f color="d73a4a"
```

## Examples

```bash
# Multi-call-two-diff bug
gh issue create \
  --repo https://github.com/eez-association/sync-rollup-composer \
  --title "[bug] L2 executes only 1 of 2 cross-chain calls despite both table entries consumed" \
  --label "bug,cross-chain" \
  --body-file gh_issue/multi-call-two-diff-missing-l2-call.md

# Flash-loan revert bug
gh issue create \
  --repo https://github.com/eez-association/sync-rollup-composer \
  --title "[bug] flash-loan user tx reverts on-chain (status 0x0)" \
  --label "bug,cross-chain" \
  --body-file gh_issue/flash-loan-user-tx-reverts.md

# Multi-call L2 table mismatch (issue #275)
gh issue create \
  --repo https://github.com/eez-association/sync-rollup-composer \
  --title "[bug] Multi-call scenarios produce separate L2 transactions instead of chained execution" \
  --label "bug,cross-chain" \
  --body-file gh_issue/multi-call-l2-table-mismatch.md
```

## Useful Commands

```bash
# List open issues
gh issue list --repo https://github.com/eez-association/sync-rollup-composer

# View an issue
gh issue view 256 --repo https://github.com/eez-association/sync-rollup-composer --json title,body,url

# Close an issue
gh issue close 123 --repo https://github.com/eez-association/sync-rollup-composer

# Add a comment
gh issue comment 256 --repo https://github.com/eez-association/sync-rollup-composer --body "Fixed in commit abc123"
```
