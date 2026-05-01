// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ════════════════════════════════════════════════════════════════════════
//  TableTransformer — OBSOLETE
// ════════════════════════════════════════════════════════════════════════
//
// This file used to convert legacy scope-tree-format execution tables (from the
// pre-flatten `main` branch) into flatten-model entries. The legacy format no
// longer exists in this branch — all on-chain code consumes flatten-model
// entries directly, and all e2e ComputeExpected scripts emit them directly.
//
// The full conversion logic was removed because:
//   - It depended on the now-deleted `Action` struct and on the legacy
//     `nextAction` chain semantics that the flatten model replaced.
//   - It depended on `ExecutionEntry.failed` (also removed).
//   - It would need a complete rewrite to map between off-chain legacy
//     traces and the multi-prover sub-batch shape, which is out of scope.
//
// Kept as a stub so the file path doesn't 404 from any historical references;
// safe to delete in a manual cleanup pass.
//
// If you need legacy → flatten conversion: do it off-chain (Python/TypeScript
// tooling) — Solidity isn't the right place to do format translation, and the
// orchestrator's job is to emit flatten-model entries directly.

contract TableTransformerObsolete {
    // intentionally empty

    }
