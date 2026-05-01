export type Chain = "l1" | "l2";

export type NodeType = "user" | "contract" | "proxy" | "system" | "ghost";

export type ArchNode = {
  id: string;
  label: string;
  sub: string;
  type: NodeType;
  col: number;
};

export type ArchEdge = {
  from: string;
  to: string;
  label: string;
  back?: boolean;
  alt?: boolean;
  id?: string;
};

export type Architecture = {
  l1: ArchNode[];
  l2: ArchNode[];
  cols: number;
  edges: ArchEdge[];
};

export type EntryStatus = "ja" | "jc" | "ok" | "consumed";

export type TableEntry = {
  id: string;
  crossChainCallHash: string;
  delta: string | null;
  status: EntryStatus;
  stateDeltas: string[];
  rollupIds: bigint[];
  actionDetail?: Record<string, string>;
  /** Full untruncated cross-chain call hash for decoding/verification */
  fullCrossChainCallHash?: string;
  /** Entry metadata: callCount, nestedActions count, rollingHash */
  entryMeta?: Record<string, string>;
};

export type DiagramItem =
  | { kind: "node"; label: string; sub: string; type: string; chain: string }
  | { kind: "arrow"; label: string };

export type BundleDirection = "L1->L2" | "L2->L1" | "L1->L2->L1" | "L2->L1->L2" | "L1" | "L2" | "mixed";

export type TransactionBundle = {
  id: string;
  direction: BundleDirection;
  title: string;
  crossChainCallHashes: string[];
  events: string[]; // event IDs
  chains: Set<"l1" | "l2">;
  blockRange: { from: bigint; to: bigint };
  txHashes: Set<string>;
  status: "complete" | "in-progress";
};
