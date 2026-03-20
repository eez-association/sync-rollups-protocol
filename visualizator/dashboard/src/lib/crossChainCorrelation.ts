import type { EventRecord } from "../types/events";
import type { TransactionBundle, BundleDirection } from "../types/visualization";

/**
 * Cross-chain transaction correlation.
 *
 * Matching rule: when the same actionHash appears in ExecutionConsumed events
 * on BOTH L1 and L2, those two events represent the same cross-chain operation.
 *
 * In the new model:
 * - L1 postBatch loads entries keyed by actionHash
 * - L2 loadExecutionTable loads entries keyed by actionHash
 * - When a proxy call is triggered on one chain, the matching entry (same actionHash)
 *   is consumed from the execution table
 * - The actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))
 */

export type CorrelatedPair = {
  actionHash: string;
  l1Event: EventRecord;
  l2Event: EventRecord;
};

/**
 * Given all collected events, find correlated cross-chain pairs.
 * Two events are correlated when:
 * 1. Both are ExecutionConsumed
 * 2. They share the same actionHash
 * 3. One is on L1, the other on L2
 */
export function findCorrelatedPairs(events: EventRecord[]): CorrelatedPair[] {
  const l1Consumed = new Map<string, EventRecord>();
  const l2Consumed = new Map<string, EventRecord>();
  const pairs: CorrelatedPair[] = [];

  for (const event of events) {
    if (event.eventName !== "ExecutionConsumed") continue;
    const hash = event.args.actionHash as string;
    if (!hash) continue;

    if (event.chain === "l1") {
      l1Consumed.set(hash, event);
      const match = l2Consumed.get(hash);
      if (match) {
        pairs.push({ actionHash: hash, l1Event: event, l2Event: match });
      }
    } else {
      l2Consumed.set(hash, event);
      const match = l1Consumed.get(hash);
      if (match) {
        pairs.push({ actionHash: hash, l1Event: match, l2Event: event });
      }
    }
  }

  return pairs;
}

/**
 * Also correlates entries that appear in both BatchPosted (L1) and
 * ExecutionTableLoaded (L2) by actionHash — these represent the same
 * execution entry loaded on both chains.
 */
export type CorrelatedEntry = {
  actionHash: string;
  l1EventId: string; // BatchPosted event
  l2EventId: string; // ExecutionTableLoaded event
};

export function findCorrelatedEntries(events: EventRecord[]): CorrelatedEntry[] {
  // Collect all actionHashes from BatchPosted entries (L1)
  const l1Hashes = new Map<string, string>(); // actionHash -> eventId
  // Collect all actionHashes from ExecutionTableLoaded entries (L2)
  const l2Hashes = new Map<string, string>();
  const correlations: CorrelatedEntry[] = [];

  for (const event of events) {
    if (event.eventName === "BatchPosted" && event.chain === "l1") {
      const entries = event.args.entries as Array<{ actionHash: string }>;
      if (entries) {
        for (const entry of entries) {
          if (
            entry.actionHash !==
            "0x0000000000000000000000000000000000000000000000000000000000000000"
          ) {
            l1Hashes.set(entry.actionHash, event.id);
          }
        }
      }
    }
    if (event.eventName === "ExecutionTableLoaded" && event.chain === "l2") {
      const entries = event.args.entries as Array<{ actionHash: string }>;
      if (entries) {
        for (const entry of entries) {
          l2Hashes.set(entry.actionHash, event.id);
        }
      }
    }
  }

  // Find matches
  for (const [hash, l1EventId] of l1Hashes) {
    const l2EventId = l2Hashes.get(hash);
    if (l2EventId) {
      correlations.push({ actionHash: hash, l1EventId, l2EventId });
    }
  }

  return correlations;
}

/**
 * Build transaction bundles by grouping events that share actionHashes.
 *
 * Strategy:
 * 1. Build a map: actionHash -> [eventIds] from events that carry actionHashes
 *    (BatchPosted entries, ExecutionTableLoaded entries, ExecutionConsumed,
 *     CrossChainCallExecuted, L2TXExecuted)
 * 2. Build a map: eventId -> [actionHashes] (inverse)
 * 3. Use union-find (transitive closure) to group events that share any actionHash
 * 4. Each group becomes a TransactionBundle
 */
export function buildTransactionBundles(events: EventRecord[]): TransactionBundle[] {
  // Map: actionHash -> set of event IDs
  const hashToEvents = new Map<string, Set<string>>();
  // Map: eventId -> set of actionHashes
  const eventToHashes = new Map<string, Set<string>>();

  const ZERO_HASH = "0x0000000000000000000000000000000000000000000000000000000000000000";

  function link(eventId: string, actionHash: string) {
    if (!actionHash || actionHash === ZERO_HASH) return;
    const h = actionHash.toLowerCase();
    if (!hashToEvents.has(h)) hashToEvents.set(h, new Set());
    hashToEvents.get(h)!.add(eventId);
    if (!eventToHashes.has(eventId)) eventToHashes.set(eventId, new Set());
    eventToHashes.get(eventId)!.add(h);
  }

  for (const event of events) {
    switch (event.eventName) {
      case "BatchPosted": {
        const entries = event.args.entries as Array<{ actionHash: string }> | undefined;
        if (entries) {
          for (const entry of entries) {
            link(event.id, entry.actionHash);
          }
        }
        break;
      }
      case "ExecutionTableLoaded": {
        const entries = event.args.entries as Array<{ actionHash: string }> | undefined;
        if (entries) {
          for (const entry of entries) {
            link(event.id, entry.actionHash);
          }
        }
        break;
      }
      case "ExecutionConsumed":
        link(event.id, event.args.actionHash as string);
        break;
      case "CrossChainCallExecuted":
        link(event.id, event.args.actionHash as string);
        break;
      case "L2TXExecuted":
        // L2TXExecuted only has entryIndex now, no actionHash — skip linking
        break;
    }
  }

  // Union-Find for grouping event IDs
  const parent = new Map<string, string>();
  function find(x: string): string {
    if (!parent.has(x)) parent.set(x, x);
    while (parent.get(x) !== x) {
      parent.set(x, parent.get(parent.get(x)!)!);
      x = parent.get(x)!;
    }
    return x;
  }
  function union(a: string, b: string) {
    const ra = find(a), rb = find(b);
    if (ra !== rb) parent.set(ra, rb);
  }

  // Group events that share actionHashes
  for (const [, eventIds] of hashToEvents) {
    const arr = [...eventIds];
    for (let i = 1; i < arr.length; i++) {
      union(arr[0], arr[i]);
    }
  }

  // Collect groups
  const groups = new Map<string, Set<string>>();
  for (const eventId of eventToHashes.keys()) {
    const root = find(eventId);
    if (!groups.has(root)) groups.set(root, new Set());
    groups.get(root)!.add(eventId);
  }

  // Also add events that don't have actionHashes as standalone bundles
  const eventMap = new Map(events.map((e) => [e.id, e]));
  const bundledEventIds = new Set(eventToHashes.keys());

  // Build TransactionBundle from each group
  const bundles: TransactionBundle[] = [];
  let bundleIdx = 0;

  for (const [, eventIds] of groups) {
    const groupEvents = [...eventIds]
      .map((id) => eventMap.get(id))
      .filter((e): e is EventRecord => e !== undefined)
      .sort((a, b) => {
        if (a.blockNumber !== b.blockNumber) return a.blockNumber < b.blockNumber ? -1 : 1;
        return a.logIndex - b.logIndex;
      });

    if (groupEvents.length === 0) continue;

    // Collect all actionHashes in this group
    const allHashes = new Set<string>();
    for (const eid of eventIds) {
      const hashes = eventToHashes.get(eid);
      if (hashes) hashes.forEach((h) => allHashes.add(h));
    }

    // Determine chains involved
    const chains = new Set<"l1" | "l2">();
    const txHashes = new Set<string>();
    let minBlock = groupEvents[0].blockNumber;
    let maxBlock = groupEvents[0].blockNumber;
    for (const e of groupEvents) {
      chains.add(e.chain);
      txHashes.add(e.transactionHash);
      if (e.blockNumber < minBlock) minBlock = e.blockNumber;
      if (e.blockNumber > maxBlock) maxBlock = e.blockNumber;
    }

    // Determine direction
    const direction = inferDirection(groupEvents);

    // Determine status: complete if all consumed events have been seen
    const consumedHashes = new Set<string>();
    for (const e of groupEvents) {
      if (e.eventName === "ExecutionConsumed") {
        consumedHashes.add((e.args.actionHash as string).toLowerCase());
      }
    }
    // Check if batch/table entries are all consumed
    const loadedHashes = new Set<string>();
    for (const e of groupEvents) {
      if (e.eventName === "BatchPosted") {
        const entries = e.args.entries as Array<{ actionHash: string }> | undefined;
        if (entries) entries.forEach((en) => {
          if (en.actionHash !== ZERO_HASH) loadedHashes.add(en.actionHash.toLowerCase());
        });
      }
      if (e.eventName === "ExecutionTableLoaded") {
        const entries = e.args.entries as Array<{ actionHash: string }> | undefined;
        if (entries) entries.forEach((en) => loadedHashes.add(en.actionHash.toLowerCase()));
      }
    }
    const allConsumed = loadedHashes.size > 0 && [...loadedHashes].every((h) => consumedHashes.has(h));
    const status = allConsumed ? "complete" : "in-progress";

    // Generate title
    const title = generateBundleTitle(groupEvents, direction);

    bundles.push({
      id: `bundle-${bundleIdx++}`,
      direction,
      title,
      actionHashes: [...allHashes],
      events: groupEvents.map((e) => e.id),
      chains,
      blockRange: { from: minBlock, to: maxBlock },
      txHashes,
      status,
    });
  }

  // Add standalone events (no actionHash) as single-event bundles
  for (const event of events) {
    if (bundledEventIds.has(event.id)) continue;
    bundles.push({
      id: `bundle-${bundleIdx++}`,
      direction: event.chain === "l1" ? "L1" : "L2",
      title: event.eventName,
      actionHashes: [],
      events: [event.id],
      chains: new Set([event.chain]),
      blockRange: { from: event.blockNumber, to: event.blockNumber },
      txHashes: new Set([event.transactionHash]),
      status: "complete",
    });
  }

  // Sort bundles by earliest block
  bundles.sort((a, b) => {
    if (a.blockRange.from !== b.blockRange.from) return a.blockRange.from < b.blockRange.from ? -1 : 1;
    return 0;
  });

  return bundles;
}

function inferDirection(events: EventRecord[]): BundleDirection {
  // Track the chain sequence of "action" events (not just load events)
  const actionEvents = events.filter((e) =>
    e.eventName === "ExecutionConsumed" ||
    e.eventName === "CrossChainCallExecuted" ||
    e.eventName === "L2TXExecuted"
  );

  if (actionEvents.length === 0) {
    // Only setup events — check which chains
    const chains = new Set(events.map((e) => e.chain));
    if (chains.size === 1) return chains.has("l1") ? "L1" : "L2";
    return "mixed";
  }

  // Build chain sequence (dedup consecutive same-chain)
  const seq: string[] = [];
  for (const e of actionEvents) {
    if (seq.length === 0 || seq[seq.length - 1] !== e.chain) {
      seq.push(e.chain);
    }
  }

  if (seq.length === 1) return seq[0] === "l1" ? "L1" : "L2";
  if (seq.length === 2) {
    if (seq[0] === "l1" && seq[1] === "l2") return "L1->L2";
    if (seq[0] === "l2" && seq[1] === "l1") return "L2->L1";
  }
  if (seq.length === 3) {
    if (seq[0] === "l1" && seq[1] === "l2" && seq[2] === "l1") return "L1->L2->L1";
    if (seq[0] === "l2" && seq[1] === "l1" && seq[2] === "l2") return "L2->L1->L2";
  }
  return "mixed";
}

function generateBundleTitle(events: EventRecord[], direction: BundleDirection): string {
  // Try to find the most descriptive event
  const ccCall = events.find((e) => e.eventName === "CrossChainCallExecuted");
  if (ccCall) {
    const src = ccCall.args.sourceAddress as string;
    const proxy = ccCall.args.proxy as string;
    return `Cross-chain call ${src?.slice(0, 8)}... via proxy ${proxy?.slice(0, 8)}...`;
  }

  const l2tx = events.find((e) => e.eventName === "L2TXExecuted");
  if (l2tx) return `L2TX execution (entry ${String(l2tx.args.entryIndex)})`;

  const batch = events.find((e) => e.eventName === "BatchPosted");
  const load = events.find((e) => e.eventName === "ExecutionTableLoaded");
  if (batch && load) return `${direction} cross-chain batch`;
  if (batch) return "Batch posted";
  if (load) return "Execution table loaded";

  return `${direction} transaction`;
}
