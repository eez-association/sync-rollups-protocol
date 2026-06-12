# Blob Format Specification

## 0. Introduction

The binary format for publishing cross-chain activity in data blobs. Each blob is a
fixed header (§1) followed by `message_count` uniform messages (§2). **Everything is a
message** — chain-local operations, cross-chain calls, results, reverts, and transaction
boundaries differ only by message type.

Blobs are the protocol's publication layer: they describe *what happened* across the
chain set, in execution order, for off-chain consumers — provers, nodes, indexers. They
are not parsed on-chain. This document specifies only the byte framing; carrier-specific
rules (e.g. packing bytes into blob field elements) are out of scope, and the same bytes
may equally travel as calldata. How the described activity is *verified* on-chain is the
subject of `CORE_PROTOCOL_SPEC.md` and `EXECUTION_ENTRY_SPEC.md`; §7 maps this
document's vocabulary onto theirs. A byte-exact test vector lives in §6.

Excalidraw: https://excalidraw.com/#json=Z3jnEhvOs2YNCW-kPD4D9,5ayFroISG8KGF0vY2UBf_Q

---

## 1. Initial header

Every blob opens with a fixed 16-byte header:

```c
struct HeaderV1 {            // offset  size
    u8   magic[4];           //   0      4    = "EMSG" (0x45 0x4D 0x53 0x47)
    u16  version;            //   4      2    = 1
    u16  flags;              //   6      2    = 0 in v1
    u32  message_count;      //   8      4    number of Messages following the header
    u32  blob_size;          //  12      4    bytes of this blob actually used
};                           // total size = 16 bytes (multiple of 8)
```

* **`magic`** — ASCII `"EMSG"`. Readers MUST reject any other value.
* **`version`** — `1` for this specification. Readers MUST reject unknown versions.
* **`flags`** — reserved feature flags; `0` in v1. Readers MUST reject unknown non-zero
  flags unless explicitly configured to ignore them.
* **`message_count`** — number of `Message` envelopes (§2) following the header.
* **`blob_size`** — total used length of the blob, header included: bytes
  `[0, blob_size)` are meaningful; anything after — e.g. carrier padding up to the
  EIP-4844 blob size — MUST be ignored.

---

## 2. Universal envelope

**Every** message — a chain-local operation, a cross-chain call, a return, a revert, the
transaction-boundary markers — MUST carry the same four fields:

```c
struct Message {
    u64      from_chain;       // source chain id (or MAX_CHAIN_ID sentinel — §3)
    u64      to_chain;         // destination chain id (or MAX_CHAIN_ID sentinel — §3)
    u8       message_type;     // one of §4
    bytes    message_params;   // type-specific payload (§4) — differs per message_type
}
```

There is no other container. Different *kinds* of activity differ only by `message_type`
and the shape of `message_params`.

### 2.1 Wire encoding

* All integers — header included — are **little-endian, fixed-width**. Chain ids and
  call numbers are `u64`.
* `address` is 20 raw bytes; `bool` is a `u8` that MUST be `0` or `1`.
* Every variable-length `bytes` field is prefixed with a `u32` byte length.
* Every array (e.g. `ChainOpItem[]`) is prefixed with a `u32` element count.
* An *optional* field (written `[+ field]`) is a `bytes` field whose length `0` means
  **absent**.
* When a payload (`message_params`, `item_data`) holds several fields, each field is
  encoded by these rules and concatenated **in declaration order**. A type with no
  params still carries the `u32` length prefix, as `0`.
* Messages are laid out back-to-back immediately after the header; the `message_params`
  length prefix lets a reader skip any message without understanding its type.

### 2.2 Message order

Messages appear in **global execution order**, and call/return matching is positional —
a `Result` carries no call reference:

* All activity caused by a `Call` — nested `Call`s included — appears **between** that
  `Call` and its `Result`. A `Result` closes the **most recently opened unmatched
  `Call`** (stack discipline).
* Cross-chain transactions do not nest or interleave: a new
  `InitiateCrossChainTransaction` MUST NOT appear before the previous one's
  `FinishCrossChainTransaction`, and `ChainOperation` messages MUST NOT appear inside an
  Initiate…Finish window.

In v1 a window opens and closes within a single blob; multi-blob windows are future
work (§9).

---

## 3. Sentinel chain id

The reserved value `MAX_CHAIN_ID = 2^64 - 1` (`0xFFFFFFFFFFFFFFFF`, the largest
representable chain id) means **"no real chain — system / boundary"**. It is used by
messages that enter from, or exit to, outside the chain set:

* `ChainOperation`                 → `from_chain = MAX_CHAIN_ID` (system-originated, no source chain).
* `InitiateCrossChainTransaction`  → `from_chain = MAX_CHAIN_ID` (the tx is *born*, no source).
* `FinishCrossChainTransaction`    → `to_chain   = MAX_CHAIN_ID` (the tx *ends*, no destination).

The two boundary markers mirror each other: Initiate has no real *source*, Finish has no
real *destination*.

---

## 4. Message types

| # | `message_type` | `from_chain` | `to_chain` | `message_params` (fields) |
|---|---|---|---|---|
| 1 | `ChainOperation` | `MAX_CHAIN_ID` | executing chain | `ChainOpItem[]` (transactions / new-block markers) |
| 2 | `InitiateCrossChainTransaction` | `MAX_CHAIN_ID` | originating chain | `TxData` [+ `signature`] |
| 3 | `Call` | source chain | target chain | `fromAddress`, `toAddress`, `data`, `value`, `call_number` |
| 4 | `Result` | callee chain | caller chain | `success`, `return_data` |
| 5 | `Revert` | reverting chain | chain that executed the call being reverted | `chain_callNumber` (the top-level call to revert) |
| 6 | `FinishCrossChainTransaction` | finishing chain | `MAX_CHAIN_ID` | — (none) |

> **Pairing.** Two types always come matched: every `Call` has a `Result`, and every
> `InitiateCrossChainTransaction` has a `FinishCrossChainTransaction`. The other types
> (`ChainOperation`, `Revert`) have no pair — they stand alone.

### 4.1 `ChainOperation`
The single message type for every **chain-specific** operation — anything that affects
`to_chain` alone and no other chain: pure transactions, starting a block, "closing" a
block, and the like. The payload is an ordered **list** whose items are each either a
transaction or a new-block marker:

```c
message_params = ChainOpItem[]       // ordered list

ChainOpItem {
    u8     item_type;                // 1 = Transaction, 2 = NewBlock
    bytes  item_data;                // shape per item_type, below
}

// item_type 1 — Transaction
item_data = rlp_transaction [+ signature]   // RLP-encoded transaction; signature OPTIONAL

// item_type 2 — NewBlock
item_data = block_params                    // new-block parameters (e.g. timestamp, ...)
```

A `NewBlock` item starts a new block on `to_chain` — implicitly closing the previous one
— and the transactions that follow it belong to that block. The transaction signature is
optional (same as `InitiateCrossChainTransaction`, §4.2).

In v1 the *internal* schema of `rlp_transaction`, `TxData` (§4.2), and `block_params`
is chain-specific and out of scope for this envelope format — readers treat them as
opaque, length-prefixed bytes.

### 4.2 `InitiateCrossChainTransaction`
Opens one cross-chain transaction. Born from the system, so
`from_chain = MAX_CHAIN_ID`; `to_chain` is the chain where the originating tx lives.

```c
message_params = TxData [+ signature]    // the originating transaction; signature OPTIONAL
```

### 4.3 `Call`
A cross-chain call.

```c
call_fields {
    address  fromAddress;
    address  toAddress;
    bytes    data;
    uint256  value;
}
u64 call_number      // per-chain counter: the from_chain's own call index
```

**Call numbering is per chain.** Each chain keeps its own call counter; `call_number` is
that chain's index for this call. The counter is **1-based**, increments on every `Call`
the chain emits, and **never resets** — not per block, not per cross-chain transaction,
**not per blob**: it persists across blobs, so the pair *(chain, call_number)* is unique
across the entire published history. A `Revert` references a call by exactly that pair —
possibly a call published in an earlier blob.

### 4.4 `Result`  (a.k.a. Return)
The return of a finished `Call`, flowing back to the caller chain.

```c
result_fields {
    bool     success;        // false = the call itself reverted on the callee chain
    bytes    return_data;
}
```

A `Result` carries no call reference: it closes the most recently opened unmatched
`Call` by position in the blob (§2.2).

`success = false` means the call **finished by reverting** on the callee chain: the
caller receives the failure and handles it; nothing is unwound. This is a different
thing from `Revert` (§4.5), which unwinds a call that already *succeeded*.

### 4.5 `Revert`
Advises `to_chain` that an already-executed **top-level call** must revert. The params
are **just the call identifier** — nothing else:

```c
message_params = chain_callNumber      // the top-level call that must revert: (u64 chain, u64 call_number)
```

A `chain_callNumber` references a specific call as the pair *(chain, call_number)*.
Because call numbering is per chain (§4.3), the chain is required to disambiguate which
call the number refers to. A `Revert` carries nothing else — no revert data.

A `Revert` is **not** a failed `Result`. A call that fails by itself reports back as
`Result { success: false }` (§4.4). `Revert` covers the opposite case: the call already
completed with `success = true` on the destination chain, but the calling rollup
*afterwards* reverted — so the previously-done call must be reverted too, and the
`Revert` message forwards that unwinding.

**Chained reverts.** Reverts cascade, and the unit of reverting is the **top-level
call** — the outermost frame a chain executed for a remote caller. The rule is:

* **Same-chain nesting unwinds for free.** Reverting a top-level call unwinds everything
  done under it *on that chain*; a call nested inside an already-reverted frame on the
  same chain never gets a `Revert` of its own.
* **Cross-chain effects need their own `Revert`.** Work done under the reverted frame
  that left the chain — outgoing calls to *other* chains — cannot be unwound locally, so
  each affected outgoing call gets a `Revert` of its own.

So when a chain reverts internally, it sends one `Revert` per affected outgoing call,
addressed to the chain that executed it (fan-out — §5.2.1). A chain *receiving* a
`Revert` unwinds the call locally, and if that execution had made outgoing calls of its
own it forwards further `Revert`s to *its* callees — and so on down the dependency chain
(forwarding — §5.2.1).

### 4.6 `FinishCrossChainTransaction`
Closes the cross-chain transaction. `to_chain = MAX_CHAIN_ID`. Carries **no**
`message_params` — on the wire, the `u32` length prefix is `0` (§2.1).

---

## 5. Reference examples

### 5.1 A transaction is framed by Initiate / Finish

```
L2_A
  - ChainOperation (from: MAX_CHAIN_ID, to: L2_A, params: [NewBlock{timestamp}, Transaction, Transaction])
  - Process one cross-chain transaction:
      InitiateCrossChainTransaction (from: MAX_CHAIN_ID, to: L2_A, params: TxData [+ signature])
        ... messages ...
      FinishCrossChainTransaction   (from: L2_A, to: MAX_CHAIN_ID, params: —)
```

### 5.2 Call then Revert

```
Call#A_1 (from L2_A, to L2_B, call_fields: fromAddress, toAddress, data, value)
Result   (from L2_B, to L2_A, params: success: true, return_data)
             # L2_A then reverts
Revert   (from L2_A, to L2_B, params: chain_callNumber → Call#A_1)
```

### 5.2.1 Chained reverts

**Fan-out** — A made two calls, then reverts internally; A itself advises both callees:

```
Call#A_1 (from L2_A, to L2_B, ...)
Call#A_2 (from L2_A, to L2_C, ...)
             # L2_A reverts internally
Revert   (from L2_A, to L2_B, params: chain_callNumber → Call#A_1)
Revert   (from L2_A, to L2_C, params: chain_callNumber → Call#A_2)
```

**Forwarding** — A called B, B called C, both returned normally; when A reverts, B must
unwind `Call#A_1`, which drags B's own dependent call along:

```
Call#A_1 (from L2_A, to L2_B, ...)
Call#B_1 (from L2_B, to L2_C, ...)
             # both return normally; then L2_A reverts
Revert   (from L2_A, to L2_B, params: chain_callNumber → Call#A_1)
Revert   (from L2_B, to L2_C, params: chain_callNumber → Call#B_1)
```

### 5.3 Two calls (per-chain numbering)

```
Call#A_1 (from L2_A, to L2_B, call_fields: ...)
Call#A_2 (from L2_A, to L2_B, call_fields: ...)
```

`#A_n` = chain A's own call counter; numbering is per chain (§4.3). A `chain_callNumber`
(the sole content of a `Revert`, §4.5) references one such call as the pair *(chain, n)*
— e.g. `Call#A_1` is `(A, 1)`.

---

## 6. Test vector

A complete 242-byte blob — one cross-chain transaction on chains `1` (L2_A) and `2`
(L2_B): a `Call` that succeeds and is then force-reverted (the §5.2 scenario, framed by
Initiate/Finish). Implementations MUST reproduce these bytes exactly.

Logical content:

```
Initiate (from MAX_CHAIN_ID, to 1, TxData: 0xc0ffee, signature absent)
Call#1_1 (from 1, to 2, fromAddress 0x11…11, toAddress 0x22…22, data 0xdeadbeef, value 1000)
Result   (from 2, to 1, success: true, return_data: 0x2a)
Revert   (from 1, to 2, chain_callNumber → (1, 1))
Finish   (from 1, to MAX_CHAIN_ID, params: —)
```

Encoded, per part (header 16 B; messages 32 + 109 + 27 + 37 + 21 B):

```
header   454d5347 0100 0000 05000000 f2000000
                                              # magic "EMSG", v1, flags 0, count 5, size 242
initiate ffffffffffffffff 0100000000000000 02 0b000000
         03000000 c0ffee                      # TxData, len 3
         00000000                             # signature absent (len 0)
call     0100000000000000 0200000000000000 03 58000000
         1111111111111111111111111111111111111111   # fromAddress
         2222222222222222222222222222222222222222   # toAddress
         04000000 deadbeef                    # data, len 4
         e803000000000000…00 (32 B)           # value = 1000, u256 LE
         0100000000000000                     # call_number = 1
result   0200000000000000 0100000000000000 04 06000000
         01                                   # success = true
         01000000 2a                          # return_data, len 1
revert   0100000000000000 0200000000000000 05 10000000
         0100000000000000 0100000000000000    # chain_callNumber = (1, 1)
finish   0100000000000000 ffffffffffffffff 06 00000000
```

Full blob (242 bytes):

```
454d53470100000005000000f2000000ffffffffffffffff0100000000000000020b00000003000000c0ffee
0000000001000000000000000200000000000000035800000011111111111111111111111111111111111111
11222222222222222222222222222222222222222204000000deadbeefe80300000000000000000000000000
0000000000000000000000000000000000010000000000000002000000000000000100000000000000040600
000001010000002a010000000000000002000000000000000510000000010000000000000001000000000000
000100000000000000ffffffffffffffff0600000000
```

---

## 7. Relation to the on-chain protocol

Blobs *describe* execution; the contracts *verify* it via execution entries
(`EXECUTION_ENTRY_SPEC.md`). Rough vocabulary mapping:

| Blob | Entry / contract vocabulary |
|---|---|
| `Call` + `Result { success: true }` | flat-array call, `CALL_END(true, retData)` |
| `Call` + `Result { success: false }` | natural revert — flat-array call with `revertSpan = 0`, `CALL_END(false, retData)` |
| `Revert` | the `revertSpan > 0` forced-revert mechanism on the destination |
| `Initiate` / `Finish` | the boundaries of the entries a cross-chain transaction compiles into |

Caveats:

* **Terminology.** "Top-level call" here means *the outermost frame executed on the
  destination chain* — not the same use as "top-level" (vs reentrant/nested) in the
  entry and lookup specs.
* **Lookups are not represented.** Cross-chain static reads (`LOOKUP_SPEC.md`) are
  read-only and deliberately absent from v1 blobs; a future revision may add a
  `StaticCall` type.
* **Chain id width.** `from_chain` / `to_chain` are `u64`, while contracts use
  `uint256 rollupId`. Registry-assigned ids fit; larger ids don't fit in `u64`, and
  `MAX_CHAIN_ID` itself is reserved as the sentinel — it must never be a valid
  rollup id.

---

## 8. Pending discussions

* **Endianness — LE vs BE.** v1 specifies little-endian throughout (§2.1); whether to
  switch to big-endian (the EVM convention) is still under discussion. The §6 test
  vector would change accordingly.

Further open questions live in `docs/openquestions.md`.

---

## 9. Future work: multi-blob transactions

An Initiate…Finish window **will be allowed to span blobs** — but not in v1, where
every window opens and closes within a single blob (§2.2). v1 readers stay safe when
this lands: they MUST reject non-zero header `flags` (§1), so continuation blobs are
rejected rather than misparsed.

The planned expansion:

* **Continuation flags.** Two bits in the header's `flags` field: `CONTINUES` (bit 0) —
  this blob ends with an open window (and possibly unmatched `Call`s) that resumes in
  the next blob; `CONTINUATION` (bit 1) — this blob resumes the window left open by its
  predecessor instead of starting fresh.
* **Messages are never split.** The cut point is always a message boundary —
  `message_count` and `blob_size` already enforce that a blob holds whole messages, and
  that stays true.
* **Carried state.** A reader carries three things across the boundary: the open
  Initiate…Finish window, the stack of unmatched `Call`s (§2.2 matching continues as if
  the two blobs' messages were laid end to end), and the per-chain call counters —
  which already persist across blobs today (§4.3).
* **Adjacency.** A `CONTINUATION` blob is only valid as the immediate successor of a
  `CONTINUES` blob in consumption order; any other arrangement MUST be rejected.
* **Atomicity on failure.** Cross-chain transactions are atomic: if the continuation
  blob is missing or malformed, the spanning transaction is invalid all the way back to
  its `Initiate` — a partial window is never executed.

When this ships, §2.2's "most recently opened unmatched `Call`" rule reads across the
blob sequence rather than within one blob, and the `flags` bits say which mode each
blob is in.
