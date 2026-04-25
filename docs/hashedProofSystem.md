# Hashed Interaction: Cross-Proof-System Atomic Verification

## Problem

When a `postBatch` call involves multiple proof systems, each proof system independently proves state transitions for its own rollups. But cross-chain L2-L2 actions can span rollups belonging to *different* proof systems. Without a shared commitment, proof system A could prove a message "sent" to proof system B's rollup, while B's proof doesn't acknowledge receiving it.

The `hashedInteraction` solves this by giving every proof system a cryptographic commitment to all cross-boundary messages, included as a public input in each proof. Since all proofs must verify atomically in a single `postBatch` call, the contract guarantees that every proof system agrees on the same set of cross-proof-system interactions.

## Global Message Ordering

All cross-chain messages (L2-L2 actions) within a batch are assigned a **single global order** across all rollups. This ordering is deterministic and agreed upon off-chain before proving.

```
Global message list (ordered):
  msg_0: rollup 1 -> rollup 3   (PS_A -> PS_B)
  msg_1: rollup 2 -> rollup 2   (PS_A -> PS_A, same PS, not cross-boundary)
  msg_2: rollup 3 -> rollup 1   (PS_B -> PS_A)
  msg_3: rollup 1 -> rollup 4   (PS_A -> PS_B)
  msg_4: rollup 4 -> rollup 5   (PS_B -> PS_C)
```

## What Goes Into `hashedInteraction`

For a given proof system PS_k, the `hashedInteraction` is the hash of all **cross-proof-system** action hashes from the global ordered list that involve at least one rollup covered by PS_k.

Cross-proof-system means: the source rollup and destination rollup belong to different proof systems.

```
hashedInteraction[PS_A] = keccak256(
    actionHash(msg_0) ||   // PS_A -> PS_B
    actionHash(msg_2) ||   // PS_B -> PS_A
    actionHash(msg_3)      // PS_A -> PS_B
)

hashedInteraction[PS_B] = keccak256(
    actionHash(msg_0) ||   // PS_A -> PS_B
    actionHash(msg_2) ||   // PS_B -> PS_A
    actionHash(msg_3) ||   // PS_A -> PS_B
    actionHash(msg_4)      // PS_B -> PS_C
)

hashedInteraction[PS_C] = keccak256(
    actionHash(msg_4)      // PS_B -> PS_C
)
```

Key properties:
- **Global order preserved**: action hashes are concatenated in the same global order for every proof system
- **Only cross-boundary**: messages within a single proof system (msg_1 above) are excluded
- **Shared overlap**: if PS_A and PS_B both participate in a message, both include the same action hash at the same position in the ordering
- **bytes32(0)** if the proof system has no cross-boundary interactions in this batch

## How It Binds Proof Systems Together

Each proof system's ZK circuit must:

1. Compute its own view of the `hashedInteraction` from the execution it proves
2. Expose this hash as a public output
3. The on-chain verifier checks that the proof attests to the `hashedInteraction` value passed by the caller

Since `postBatch` requires ALL proofs to verify atomically:
- PS_A's proof commits to `hashedInteraction[PS_A]` which includes msg_0 (A->B)
- PS_B's proof commits to `hashedInteraction[PS_B]` which also includes msg_0 (A->B)
- If PS_A proves msg_0 was sent but PS_B's proof doesn't include msg_0 as received, PS_B's `hashedInteraction` won't match and its proof fails
- The batch reverts, preventing inconsistency

## On-Chain Integration

In `postBatch`, the `hashedInteractions` array (one `bytes32` per proof system) is folded into each proof system's `publicInputsHash`:

```solidity
publicInputsHash = keccak256(
    abi.encodePacked(
        blockhash(block.number - 1),
        block.timestamp,
        abi.encode(entryHashes),        // per-proof-system (uses that PS's vkeys)
        abi.encode(blobHashes),          // shared
        keccak256(callData),             // shared
        hashedInteractions[k]            // per-proof-system
    )
);
```

The contract does NOT independently verify the contents of `hashedInteraction` -- it trusts the ZK proof to attest correctness. The contract's role is to:
1. Pass the hash into the public inputs so the proof is bound to it
2. Ensure all proofs verify atomically (so no proof system can lie about interactions)
3. Enforce per-rollup threshold (so enough proof systems must agree)

## Example: Two Proof Systems, One Cross-Chain Call

Setup:
- PS_A covers rollups {1, 2}, threshold=1
- PS_B covers rollups {3, 4}, threshold=1
- Batch contains one cross-chain call: rollup 1 calls rollup 3

```
Global messages: [msg_0: rollup1 -> rollup3]

hashedInteractions[PS_A] = keccak256(actionHash(msg_0))
hashedInteractions[PS_B] = keccak256(actionHash(msg_0))
```

Both proof systems commit to the same interaction. PS_A's proof proves rollup 1 sent the message. PS_B's proof proves rollup 3 received it. The contract verifies both atomically.

## Example: No Cross-Boundary Interactions

If a batch only touches rollups within a single proof system (no L2-L2 calls crossing boundaries):

```
hashedInteractions[PS_A] = bytes32(0)
```

The proof system still includes this in its public inputs (as zero), but there are no cross-boundary action hashes to commit to.

## Open Ideas / Things to Resolve

### Cross-chain transaction identifier for ordering

The global ordering needs to be deterministic and verifiable. We likely need a **cross-chain transaction ID** (e.g. a monotonic counter or a sequence number scoped to the batch) assigned to each cross-chain action. This ID would:
- Be part of the action itself (or derived from it), so each proof system can independently sort its messages into the same global order
- Prevent ambiguity when two messages have identical source/destination/calldata but different intended positions in the execution
- Be assigned by the orchestrator/sequencer at batch construction time

Possible schemes:
- **Batch-scoped sequence number**: a simple `uint256 seqId` incremented for each cross-chain action in the batch. Cheap, unambiguous, but requires the orchestrator to assign upfront.
- **Deterministic from execution order**: derive the ID from the position in the execution table (entry index + delta index). No extra field needed, but ties ordering to the entry layout.
- **Hash-chain**: each message's ID = hash(previous message's ID, action). Self-verifying order, but more expensive in-circuit.

### Actions must include the initiator

Every cross-chain action in the `hashedInteraction` must carry the **initiator** — the original address (and rollup) that triggered the cross-chain call chain, not just the immediate source. This is important because:
- The same destination + calldata can be reached through different call paths (direct call vs. nested via proxy). The initiator disambiguates.
- Proof systems need to verify the full provenance of a message: "this action was initiated by address X on rollup Y, forwarded through Z". Without the initiator, a proof system could attribute a message to the wrong origin.
- For accountability and replay protection: the initiator is the entity whose state transition "caused" the cross-chain effect.

The `Action` struct already has `sourceAddress` and `sourceRollup`, but these represent the *immediate* caller (which may be a proxy or intermediate contract). We may need an additional `initiator` / `initiatorRollup` field — or the initiator could be the root of the scope tree (scope[0]).

Open question: should the initiator be explicit in the Action struct, or derived from the scope hierarchy? Explicit is simpler for the circuit but adds a field; scope-derived is implicit but requires the circuit to walk the scope tree.

### Interaction hash structure: flat vs. tree

Current design concatenates action hashes linearly. Alternative: a Merkle tree of action hashes, which would allow proof systems to prove inclusion of individual messages without revealing the full set. Probably overkill for now but worth considering if batch sizes grow large.

### What counts as "cross-boundary"?

Current definition: source rollup and destination rollup belong to different proof systems. Edge cases to consider:
- A rollup covered by multiple proof systems (M-of-N with overlapping sets) — is a message between two rollups that share *some* proof systems but not all considered cross-boundary? Likely yes: if any proof system covers one but not the other, that PS needs the interaction hash.
- Mainnet (rollupId=0) as source/destination — mainnet has no proof system. Messages to/from mainnet are handled by L1 execution directly, so they probably don't belong in `hashedInteraction`. But this needs confirmation.

## Design Decisions

1. **Why per-proof-system and not a single global hash?**
   Each proof system's circuit only knows about its own rollups' state. It can verify the messages it sends/receives but not messages between two other proof systems it doesn't cover. A per-PS hash scopes the commitment to what the circuit can actually verify.

2. **Why global ordering?**
   Without a canonical order, two proof systems could include the same action hashes in different orders and produce different `hashedInteraction` values, breaking the shared-overlap property. Global ordering ensures consistency.

3. **Why not verify on-chain?**
   The contract would need the full list of cross-chain actions and a mapping of which rollups belong to which proof system. This is expensive and redundant -- the ZK proofs already attest to correctness. The contract just needs the hash as a binding commitment.
