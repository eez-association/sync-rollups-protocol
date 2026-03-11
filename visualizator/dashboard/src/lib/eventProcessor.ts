import type { EventRecord } from "../types/events";
import type { TableEntry } from "../types/visualization";
import { truncateHex } from "./actionFormatter";
import { computeActionHash, formatActionFields, actionFromEventArgs, actionSummary, type ActionFields } from "./actionHashDecoder";

/**
 * Processes an event into table entry mutations.
 * Returns { adds, consumes } for the appropriate chain.
 */
export type ConsumeInfo = {
  actionHash: string;
  actionDetail: Record<string, string>;
};

// Cache: actionHash -> decoded detail from ExecutionConsumed events.
// Allows entries added *after* their consumption was already seen (e.g. L2
// consumed before L1 BatchPosted is processed) to show decoded fields immediately.
const actionDetailCache = new Map<string, Record<string, string>>();

export function getActionDetailCache() {
  return actionDetailCache;
}

export function processEventForTables(
  event: EventRecord,
): {
  l1Adds: TableEntry[];
  l2Adds: TableEntry[];
  l1Consumes: ConsumeInfo[];
  l2Consumes: ConsumeInfo[];
} {
  const result = {
    l1Adds: [] as TableEntry[],
    l2Adds: [] as TableEntry[],
    l1Consumes: [] as ConsumeInfo[],
    l2Consumes: [] as ConsumeInfo[],
  };

  switch (event.eventName) {
    case "BatchPosted": {
      const entries = event.args.entries as Array<{
        stateDeltas: Array<{
          rollupId: bigint;
          currentState: string;
          newState: string;
          etherDelta: bigint;
        }>;
        actionHash: string;
        nextAction: {
          actionType: number;
          rollupId: bigint;
          destination: string;
          value: bigint;
          data: string;
          failed: boolean;
          sourceAddress: string;
          sourceRollup: bigint;
          scope: bigint[];
        };
      }>;
      if (!entries) break;
      for (const entry of entries) {
        const isImmediate =
          entry.actionHash ===
          "0x0000000000000000000000000000000000000000000000000000000000000000";
        if (isImmediate) continue; // Immediate entries don't go to table
        const te = entryToTableEntry(entry, event.id);
        result.l1Adds.push(te);
      }
      break;
    }

    case "ExecutionTableLoaded": {
      const entries = event.args.entries as Array<{
        stateDeltas: Array<{
          rollupId: bigint;
          currentState: string;
          newState: string;
          etherDelta: bigint;
        }>;
        actionHash: string;
        nextAction: {
          actionType: number;
          rollupId: bigint;
          destination: string;
          value: bigint;
          data: string;
          failed: boolean;
          sourceAddress: string;
          sourceRollup: bigint;
          scope: bigint[];
        };
      }>;
      if (!entries) break;
      for (const entry of entries) {
        const te = entryToTableEntry(entry, event.id);
        result.l2Adds.push(te);
      }
      break;
    }

    case "ExecutionConsumed": {
      const actionHash = event.args.actionHash as string;
      const actionArg = event.args.action as Record<string, unknown> | undefined;
      let actionDetail: Record<string, string> = {};
      if (actionArg) {
        const fields = actionFromEventArgs(actionArg);
        const computed = computeActionHash(fields);
        actionDetail = {
          computedHash: computed,
          ...formatActionFields(fields),
        };
      }
      if (Object.keys(actionDetail).length > 0) {
        actionDetailCache.set(actionHash.toLowerCase(), actionDetail);
      }
      const info: ConsumeInfo = { actionHash, actionDetail };
      if (event.chain === "l1") {
        result.l1Consumes.push(info);
      } else {
        result.l2Consumes.push(info);
      }
      break;
    }
  }

  return result;
}

function entryToTableEntry(
  entry: {
    stateDeltas: Array<{
      rollupId: bigint;
      currentState: string;
      newState: string;
      etherDelta: bigint;
    }>;
    actionHash: string;
    nextAction: {
      actionType: number;
      rollupId: bigint;
      destination: string;
      value: bigint;
      data: string;
      failed: boolean;
      sourceAddress: string;
      sourceRollup: bigint;
      scope: bigint[];
    };
  },
  eventId: string,
): TableEntry {
  const na = entry.nextAction;
  const naFields: ActionFields = {
    actionType: na.actionType,
    rollupId: BigInt(na.rollupId),
    destination: na.destination as `0x${string}`,
    value: BigInt(na.value),
    data: na.data as `0x${string}`,
    failed: na.failed,
    sourceAddress: na.sourceAddress as `0x${string}`,
    sourceRollup: BigInt(na.sourceRollup),
    scope: na.scope.map((s) => BigInt(s)),
  };

  const nextSummary = actionSummary(naFields);
  const deltas = entry.stateDeltas.map(
    (sd) => `r${sd.rollupId}: ${truncateHex(sd.currentState)} -> ${truncateHex(sd.newState)}`,
  );
  const rollupIds = entry.stateDeltas.map((sd) => sd.rollupId);

  // Check cache first — the action may have been decoded from an earlier ExecutionConsumed
  const cached = actionDetailCache.get(entry.actionHash.toLowerCase());
  const actionDetail: Record<string, string> = cached ?? {
    actionHash: entry.actionHash,
  };

  // Build next action detail with decoded fields + its computed hash
  const nextComputedHash = computeActionHash(naFields);
  const nextActionDetail: Record<string, string> = {
    computedHash: nextComputedHash,
    ...formatActionFields(naFields),
  };

  return {
    id: `${eventId}-${entry.actionHash}`,
    actionHash: truncateHex(entry.actionHash),
    nextActionHash: nextSummary,
    delta: deltas.length > 0 ? deltas.join("; ") : null,
    status: "ja",
    stateDeltas: deltas,
    rollupIds,
    actionDetail,
    nextActionDetail,
    fullActionHash: entry.actionHash,
    fullNextActionHash: nextComputedHash,
  };
}


/**
 * Extracts rollup state changes from events.
 */
export function extractRollupState(
  event: EventRecord,
): { rollupId: string; key: string; value: string }[] {
  const updates: { rollupId: string; key: string; value: string }[] = [];

  switch (event.eventName) {
    case "RollupCreated": {
      const rid = String(event.args.rollupId);
      updates.push(
        { rollupId: rid, key: `Rollup ${rid} state`, value: truncateHex(event.args.initialState as string) },
        { rollupId: rid, key: `Rollup ${rid} owner`, value: (event.args.owner as string) },
        { rollupId: rid, key: `Rollup ${rid} vk`, value: truncateHex(event.args.verificationKey as string) },
      );
      break;
    }
    case "StateUpdated": {
      const rid = String(event.args.rollupId);
      updates.push({
        rollupId: rid,
        key: `Rollup ${rid} state`,
        value: truncateHex(event.args.newStateRoot as string),
      });
      break;
    }
    case "L2ExecutionPerformed": {
      const rid = String(event.args.rollupId);
      updates.push({
        rollupId: rid,
        key: `Rollup ${rid} state`,
        value: truncateHex(event.args.newState as string),
      });
      break;
    }
    case "BatchPosted": {
      const entries = event.args.entries as Array<{
        stateDeltas: Array<{
          rollupId: bigint;
          currentState: string;
          newState: string;
          etherDelta: bigint;
        }>;
        actionHash: string;
      }>;
      if (!entries) break;
      for (const entry of entries) {
        const isImmediate =
          entry.actionHash ===
          "0x0000000000000000000000000000000000000000000000000000000000000000";
        if (!isImmediate) continue;
        for (const sd of entry.stateDeltas) {
          const rid = String(sd.rollupId);
          updates.push({
            rollupId: rid,
            key: `Rollup ${rid} state`,
            value: truncateHex(sd.newState),
          });
        }
      }
      break;
    }
  }

  return updates;
}
