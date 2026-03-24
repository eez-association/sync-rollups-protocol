import type { Chain } from "./visualization";
import type { Action, ExecutionEntry } from "./chain";

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
  | "IncomingCrossChainCallExecuted";

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
  action: Action;
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

export type IncomingCrossChainCallExecutedArgs = {
  actionHash: `0x${string}`;
  destination: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  sourceAddress: `0x${string}`;
  sourceRollup: bigint;
  scope: bigint[];
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
  currentState: `0x${string}`;
  newState: `0x${string}`;
};

export type L2TXExecutedArgs = {
  actionHash: `0x${string}`;
  rollupId: bigint;
  rlpEncodedTx: `0x${string}`;
};
