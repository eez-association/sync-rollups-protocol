export const rollupsAbi = [
  {
    type: "event",
    name: "RollupCreated",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "verificationKey", type: "bytes32", indexed: false },
      { name: "initialState", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "StateUpdated",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "newStateRoot", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "VerificationKeyUpdated",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "newVerificationKey", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "OwnershipTransferred",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "previousOwner", type: "address", indexed: true },
      { name: "newOwner", type: "address", indexed: true },
    ],
  },
  {
    type: "event",
    name: "CrossChainProxyCreated",
    inputs: [
      { name: "proxy", type: "address", indexed: true },
      { name: "originalAddress", type: "address", indexed: true },
      { name: "originalRollupId", type: "uint256", indexed: true },
    ],
  },
  {
    type: "event",
    name: "L2ExecutionPerformed",
    inputs: [
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "currentState", type: "bytes32", indexed: false },
      { name: "newState", type: "bytes32", indexed: false },
    ],
  },
  {
    type: "event",
    name: "ExecutionConsumed",
    inputs: [
      { name: "actionHash", type: "bytes32", indexed: true },
      {
        name: "action",
        type: "tuple",
        indexed: false,
        components: [
          { name: "actionType", type: "uint8" },
          { name: "rollupId", type: "uint256" },
          { name: "destination", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
          { name: "failed", type: "bool" },
          { name: "sourceAddress", type: "address" },
          { name: "sourceRollup", type: "uint256" },
          { name: "scope", type: "uint256[]" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "CrossChainCallExecuted",
    inputs: [
      { name: "actionHash", type: "bytes32", indexed: true },
      { name: "proxy", type: "address", indexed: true },
      { name: "sourceAddress", type: "address", indexed: false },
      { name: "callData", type: "bytes", indexed: false },
      { name: "value", type: "uint256", indexed: false },
    ],
  },
  {
    type: "event",
    name: "L2TXExecuted",
    inputs: [
      { name: "actionHash", type: "bytes32", indexed: true },
      { name: "rollupId", type: "uint256", indexed: true },
      { name: "rlpEncodedTx", type: "bytes", indexed: false },
    ],
  },
  {
    type: "event",
    name: "BatchPosted",
    inputs: [
      {
        name: "entries",
        type: "tuple[]",
        indexed: false,
        components: [
          {
            name: "stateDeltas",
            type: "tuple[]",
            components: [
              { name: "rollupId", type: "uint256" },
              { name: "currentState", type: "bytes32" },
              { name: "newState", type: "bytes32" },
              { name: "etherDelta", type: "int256" },
            ],
          },
          { name: "actionHash", type: "bytes32" },
          {
            name: "nextAction",
            type: "tuple",
            components: [
              { name: "actionType", type: "uint8" },
              { name: "rollupId", type: "uint256" },
              { name: "destination", type: "address" },
              { name: "value", type: "uint256" },
              { name: "data", type: "bytes" },
              { name: "failed", type: "bool" },
              { name: "sourceAddress", type: "address" },
              { name: "sourceRollup", type: "uint256" },
              { name: "scope", type: "uint256[]" },
            ],
          },
        ],
      },
      { name: "publicInputsHash", type: "bytes32", indexed: false },
    ],
  },
] as const;
