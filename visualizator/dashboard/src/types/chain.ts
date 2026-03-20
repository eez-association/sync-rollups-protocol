// New model: no more ActionType/Action enums.
// actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))

export type CrossChainCall = {
  destination: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  sourceAddress: `0x${string}`;
  sourceRollup: bigint;
  revertSpan: bigint;
};

export type NestedAction = {
  actionHash: `0x${string}`;
  callCount: bigint;
  returnData: `0x${string}`;
};

export type StateDelta = {
  rollupId: bigint;
  newState: `0x${string}`;
  etherDelta: bigint;
};

export type ExecutionEntry = {
  stateDeltas: StateDelta[];
  actionHash: `0x${string}`;
  calls: CrossChainCall[];
  nestedActions: NestedAction[];
  callCount: bigint;
  returnData: `0x${string}`;
  failed: boolean;
  rollingHash: `0x${string}`;
};

export type StaticCallEntry = {
  actionHash: `0x${string}`;
  returnData: `0x${string}`;
  failed: boolean;
  stateRoot: `0x${string}`;
  callNumber: bigint;
  lastNestedActionConsumed: bigint;
  calls: CrossChainCall[];
  rollingHash: `0x${string}`;
};
