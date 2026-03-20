import type { EventRecord } from "../types/events";
import type { TableEntry } from "../types/visualization";
import { truncateHex } from "./actionFormatter";

/**
 * Processes an event into table entry mutations.
 * Returns { adds, consumes } for the appropriate chain.
 */
export type ConsumeInfo = {
  actionHash: string;
  actionDetail: Record<string, string>;
};

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
          newState: string;
          etherDelta: bigint;
        }>;
        actionHash: string;
        calls: unknown[];
        nestedActions: unknown[];
        callCount: bigint;
        returnData: string;
        failed: boolean;
        rollingHash: string;
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
          newState: string;
          etherDelta: bigint;
        }>;
        actionHash: string;
        calls: unknown[];
        nestedActions: unknown[];
        callCount: bigint;
        returnData: string;
        failed: boolean;
        rollingHash: string;
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
      const actionDetail: Record<string, string> = {
        actionHash,
        entryIndex: String(event.args.entryIndex ?? ""),
      };
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
      newState: string;
      etherDelta: bigint;
    }>;
    actionHash: string;
    calls: unknown[];
    nestedActions: unknown[];
    callCount: bigint;
    returnData: string;
    failed: boolean;
    rollingHash: string;
  },
  eventId: string,
): TableEntry {
  const deltas = entry.stateDeltas.map(
    (sd) => `r${sd.rollupId}: -> ${truncateHex(sd.newState)}`,
  );
  const rollupIds = entry.stateDeltas.map((sd) => sd.rollupId);

  const entryMeta: Record<string, string> = {
    callCount: String(entry.callCount ?? 0),
    callsLen: String(entry.calls?.length ?? 0),
    nestedLen: String(entry.nestedActions?.length ?? 0),
    failed: entry.failed ? "true" : "false",
    rollingHash: truncateHex(entry.rollingHash ?? "0x0"),
    returnData: entry.returnData && entry.returnData !== "0x"
      ? truncateHex(entry.returnData, 12)
      : "(empty)",
  };

  return {
    id: `${eventId}-${entry.actionHash}`,
    actionHash: truncateHex(entry.actionHash),
    delta: deltas.length > 0 ? deltas.join("; ") : null,
    status: "ja",
    stateDeltas: deltas,
    rollupIds,
    actionDetail: { actionHash: entry.actionHash },
    fullActionHash: entry.actionHash,
    entryMeta,
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
