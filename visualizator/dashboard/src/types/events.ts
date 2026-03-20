import type { Chain } from "./visualization";
import type { ExecutionEntry } from "./chain";

export type EventName =
  | "RollupCreated"
  | "StateUpdated"
  | "VerificationKeyUpdated"
  | "OwnershipTransferred"
  | "CrossChainProxyCreated"
  | "L2ExecutionPerformed"
  | "ExecutionConsumed"
  | "CrossChainCallExecuted"
  | "L2TXExecuted"
  | "BatchPosted"
  | "ExecutionTableLoaded"
  | "CallResult"
  | "NestedActionConsumed"
  | "EntryExecuted"
  | "RevertSpanExecuted";

export type EventRecord = {
  id: string;
  chain: Chain;
  eventName: EventName;
  blockNumber: bigint;
  logIndex: number;
  transactionHash: `0x${string}`;
  args: Record<string, unknown>;
  timestamp?: number;
};

export type DecodedLog = {
  eventName: string;
  args: Record<string, unknown>;
  address: `0x${string}`;
  logIndex: number;
};

export type TxMetadata = {
  hash: `0x${string}`;
  blockNumber: bigint;
  from: `0x${string}`;
  to: `0x${string}` | null;
  gasUsed: bigint;
  logs: DecodedLog[];
};

// Parsed event payloads for typed access
export type BatchPostedArgs = {
  entries: ExecutionEntry[];
  publicInputsHash: `0x${string}`;
};

export type ExecutionTableLoadedArgs = {
  entries: ExecutionEntry[];
};

export type ExecutionConsumedArgs = {
  actionHash: `0x${string}`;
  entryIndex: bigint;
};

export type CrossChainProxyCreatedArgs = {
  proxy: `0x${string}`;
  originalAddress: `0x${string}`;
  originalRollupId: bigint;
};

export type CrossChainCallExecutedArgs = {
  actionHash: `0x${string}`;
  proxy: `0x${string}`;
  sourceAddress: `0x${string}`;
  callData: `0x${string}`;
  value: bigint;
};

export type CallResultArgs = {
  entryIndex: bigint;
  callNumber: bigint;
  success: boolean;
  returnData: `0x${string}`;
};

export type NestedActionConsumedArgs = {
  entryIndex: bigint;
  nestedNumber: bigint;
  actionHash: `0x${string}`;
  callCount: bigint;
};

export type EntryExecutedArgs = {
  entryIndex: bigint;
  rollingHash: `0x${string}`;
  callsProcessed: bigint;
  nestedActionsConsumed: bigint;
};

export type RollupCreatedArgs = {
  rollupId: bigint;
  owner: `0x${string}`;
  verificationKey: `0x${string}`;
  initialState: `0x${string}`;
};

export type StateUpdatedArgs = {
  rollupId: bigint;
  newStateRoot: `0x${string}`;
};

export type L2ExecutionPerformedArgs = {
  rollupId: bigint;
  newState: `0x${string}`;
};

export type L2TXExecutedArgs = {
  entryIndex: bigint;
};
