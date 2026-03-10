export const crossChainManagerL2Abi = [
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
    name: "ExecutionTableLoaded",
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
    name: "IncomingCrossChainCallExecuted",
    inputs: [
      { name: "actionHash", type: "bytes32", indexed: true },
      { name: "destination", type: "address", indexed: false },
      { name: "value", type: "uint256", indexed: false },
      { name: "data", type: "bytes", indexed: false },
      { name: "sourceAddress", type: "address", indexed: false },
      { name: "sourceRollup", type: "uint256", indexed: false },
      { name: "scope", type: "uint256[]", indexed: false },
    ],
  },
] as const;
