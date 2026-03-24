import type { EventRecord } from "../types/events";
import type { DiagramItem } from "../types/visualization";
import { actionTypeName, truncateAddress, formatScope } from "./actionFormatter";
import { actionFromEventArgs, type ActionFields } from "./actionHashDecoder";

const KNOWN_SELECTORS: Record<string, string> = {
  "0xd09de08a": "increment()",
  "0x06661abd": "counter()",
};

export type CallFlowNode = {
  address: string;
  label: string;
  chain: "l1" | "l2";
  type: "user" | "contract" | "proxy" | "system";
};

export type CallFlowStep = {
  from: CallFlowNode;
  to: CallFlowNode;
  label: string;
  actionType: string;
  isReturn: boolean;
};

/**
 * Build a call flow diagram from a bundle's events.
 * Extracts Actions from ExecutionConsumed events and orders them to form a call chain.
 */
export function buildCallFlow(
  events: EventRecord[],
  knownAddresses: Map<string, { label: string; type: string; chain: string }>,
): DiagramItem[] {
  const items: DiagramItem[] = [];

  // Extract actions from ExecutionConsumed events
  const consumedActions: { action: ActionFields; chain: "l1" | "l2"; hash: string }[] = [];
  for (const event of events) {
    if (event.eventName !== "ExecutionConsumed") continue;
    try {
      const actionArg = event.args.action as Record<string, unknown>;
      if (!actionArg) continue;
      const fields = actionFromEventArgs(actionArg);
      consumedActions.push({
        action: fields,
        chain: event.chain,
        hash: event.args.actionHash as string,
      });
    } catch {
      continue;
    }
  }

  if (consumedActions.length === 0) return items;

  // Build diagram from action sequence
  for (let i = 0; i < consumedActions.length; i++) {
    const { action, chain } = consumedActions[i];
    const rollupChain = action.rollupId === 0n ? "l1" : "l2";

    if (action.actionType === 0) {
      // CALL
      const srcInfo = resolveAddress(action.sourceAddress, knownAddresses);
      const destInfo = resolveAddress(action.destination, knownAddresses);

      if (i === 0 || items.length === 0) {
        // First node: source
        items.push({
          kind: "node",
          label: srcInfo.label,
          sub: srcInfo.type,
          type: srcInfo.type,
          chain: srcInfo.chain || chain,
        });
      }

      // Arrow with function call
      const selector = action.data.length >= 10 ? action.data.slice(0, 10) : action.data;
      const fnName = KNOWN_SELECTORS[selector.toLowerCase()] ?? selector;
      items.push({ kind: "arrow", label: fnName });

      // Destination node
      items.push({
        kind: "node",
        label: destInfo.label,
        sub: destInfo.type,
        type: destInfo.type,
        chain: rollupChain,
      });
    } else if (action.actionType === 1) {
      // RESULT - add return arrow
      const dataPreview = action.data === "0x" ? "void" : `data=${action.data.slice(0, 10)}...`;
      items.push({ kind: "arrow", label: `return(${dataPreview})` });
    } else if (action.actionType === 2) {
      // L2TX
      items.push({
        kind: "node",
        label: "L2TX",
        sub: `rlp=${action.data.slice(0, 8)}...`,
        type: "system",
        chain: rollupChain,
      });
    }
  }

  return items;
}

function resolveAddress(
  addr: string,
  known: Map<string, { label: string; type: string; chain: string }>,
): { label: string; type: string; chain: string } {
  const info = known.get(addr.toLowerCase());
  if (info) return info;
  return {
    label: truncateAddress(addr),
    type: "contract",
    chain: "l1",
  };
}

/**
 * Build a step-by-step description list from bundle events.
 */
export type BundleStep = {
  eventId: string;
  chain: "l1" | "l2";
  title: string;
  detail: string;
  eventName: string;
  txHash: string;
};

export function buildBundleSteps(events: EventRecord[]): BundleStep[] {
  return events.map((event) => ({
    eventId: event.id,
    chain: event.chain,
    title: stepTitle(event),
    detail: stepDetail(event),
    eventName: event.eventName,
    txHash: event.transactionHash,
  }));
}

function stepTitle(event: EventRecord): string {
  switch (event.eventName) {
    case "BatchPosted": {
      const entries = event.args.entries as unknown[] | undefined;
      return `Post batch (${entries?.length ?? 0} entries)`;
    }
    case "ExecutionTableLoaded": {
      const entries = event.args.entries as unknown[] | undefined;
      return `Load execution table (${entries?.length ?? 0} entries)`;
    }
    case "ExecutionConsumed":
      return "Entry consumed";
    case "CrossChainCallExecuted":
      return "Cross-chain call executed";
    case "L2TXExecuted":
      return "L2TX executed";
    case "IncomingCrossChainCallExecuted":
      return "Incoming cross-chain call";
    case "CrossChainProxyCreated":
      return "Proxy created";
    default:
      return event.eventName;
  }
}

function stepDetail(event: EventRecord): string {
  switch (event.eventName) {
    case "ExecutionConsumed": {
      try {
        const actionArg = event.args.action as Record<string, unknown>;
        if (actionArg) {
          const fields = actionFromEventArgs(actionArg);
          const typeName = actionTypeName(fields.actionType);
          const dest = fields.destination !== "0x0000000000000000000000000000000000000000"
            ? truncateAddress(fields.destination) : "";
          const scope = fields.scope.length > 0 ? ` scope=${formatScope(fields.scope)}` : "";
          return `${typeName} → rollup ${fields.rollupId}${dest ? ` → ${dest}` : ""}${scope}`;
        }
      } catch { /* fallthrough */ }
      return `actionHash: ${(event.args.actionHash as string)?.slice(0, 18)}...`;
    }
    case "CrossChainCallExecuted":
      return `proxy=${truncateAddress(event.args.proxy as string)} src=${truncateAddress(event.args.sourceAddress as string)}`;
    case "L2TXExecuted":
      return `rollup=${String(event.args.rollupId)}`;
    case "IncomingCrossChainCallExecuted":
      return `dest=${truncateAddress(event.args.destination as string)} src=${truncateAddress(event.args.sourceAddress as string)}`;
    default:
      return `block ${event.blockNumber.toString()}, tx ${event.transactionHash.slice(0, 10)}...`;
  }
}
