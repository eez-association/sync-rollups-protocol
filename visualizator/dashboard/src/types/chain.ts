export const ActionType = {
  CALL: 0,
  RESULT: 1,
  L2TX: 2,
  REVERT: 3,
  REVERT_CONTINUE: 4,
} as const;

export type ActionType = (typeof ActionType)[keyof typeof ActionType];

export type Action = {
  actionType: ActionType;
  rollupId: bigint;
  destination: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  failed: boolean;
  sourceAddress: `0x${string}`;
  sourceRollup: bigint;
  scope: bigint[];
};

export type StateDelta = {
  rollupId: bigint;
  currentState: `0x${string}`;
  newState: `0x${string}`;
  etherDelta: bigint;
};

export type ExecutionEntry = {
  stateDeltas: StateDelta[];
  actionHash: `0x${string}`;
  nextAction: Action;
};
