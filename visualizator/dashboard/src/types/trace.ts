import type { Chain } from "./visualization";

export type CallNode = {
  type: string; // CALL, STATICCALL, DELEGATECALL, CREATE, CREATE2
  from: string;
  to: string;
  value: string;
  error: string | null;
  label: string;
  funcName: string;
  returnDecoded: string | null;
  depth: number;
  isCrossChainCall: boolean;
  proxyTargetLabel: string | null;
  proxyTargetAddr: string | null;
  proxyRollupId: number | null;
  inlinedL2: InlinedL2Execution | null;
  logs: TraceEvent[];
  calls: CallNode[];
};

export type InlinedL2Execution = {
  txHash: string;
  blockNumber: number;
  userCall: CallNode | null;
  proxyInfo: string | null;
};

export type TraceEvent = {
  chain: Chain;
  name: string | null;
  address: string;
  params: { name: string; value: string }[];
};

export type TraceResponse = {
  txHash: string;
  chain: Chain;
  blockNumber: number;
  status: "success" | "revert";
  from: string;
  to: string;
  callTree: CallNode;
  events: TraceEvent[];
  blockContext: BlockContext | null;
  systemContracts: { rollups: string | null; managerL2: string | null };
};

export type BlockContext = {
  l1Block: number;
  l2Blocks: number[];
  batchTxHash: string | null;
};

export type BlockInfoResponse = {
  blockNumber: number;
  timestamp: number;
  txs: BlockTxSummary[];
  batchInfo: BatchInfo | null;
};

export type BlockTxSummary = {
  hash: string;
  from: string;
  to: string | null;
  funcName: string | null;
};

export type BatchInfo = {
  hasBatch: boolean;
  batchTxHash: string | null;
  l2Blocks: number[];
};
