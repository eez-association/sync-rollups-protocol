import { encodeAbiParameters, keccak256 } from "viem";
import { actionTypeName, truncateAddress, truncateHex, formatScope } from "./actionFormatter";

const ACTION_TUPLE_TYPE = [
  {
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
] as const;

// Known function selectors from the contracts
const KNOWN_SELECTORS: Record<string, string> = {
  "0xd09de08a": "increment()",
  "0x06661abd": "counter()",
  "0x5a6a9e05": "targetCounter()",
};

export type ActionFields = {
  actionType: number;
  rollupId: bigint;
  destination: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  failed: boolean;
  sourceAddress: `0x${string}`;
  sourceRollup: bigint;
  scope: bigint[];
};

export type DecodedActionHash = {
  computedHash: `0x${string}`;
  verified: boolean; // computed === stored
  fields: ActionFields;
  display: Record<string, string>;
};

/**
 * Compute actionHash = keccak256(abi.encode(action)) from Action fields.
 */
export function computeActionHash(action: ActionFields): `0x${string}` {
  const encoded = encodeAbiParameters(ACTION_TUPLE_TYPE, [
    {
      actionType: action.actionType,
      rollupId: action.rollupId,
      destination: action.destination,
      value: action.value,
      data: action.data,
      failed: action.failed,
      sourceAddress: action.sourceAddress,
      sourceRollup: action.sourceRollup,
      scope: action.scope,
    },
  ]);
  return keccak256(encoded);
}

/**
 * Decode and verify an action hash given the action fields and the stored hash.
 */
export function decodeActionHash(
  storedHash: string,
  action: ActionFields,
): DecodedActionHash {
  const computedHash = computeActionHash(action);
  const verified = computedHash.toLowerCase() === storedHash.toLowerCase();

  return {
    computedHash,
    verified,
    fields: action,
    display: formatActionFields(action),
  };
}

/**
 * Format action fields for display, with human-readable labels.
 */
export function formatActionFields(action: ActionFields): Record<string, string> {
  const dataSelector = action.data.length >= 10 ? action.data.slice(0, 10) : action.data;
  const selectorName = KNOWN_SELECTORS[dataSelector.toLowerCase()];
  const dataDisplay = selectorName
    ? `${dataSelector} (${selectorName})`
    : action.data.length > 20
      ? truncateHex(action.data)
      : action.data;

  const zeroAddr = "0x0000000000000000000000000000000000000000";

  return {
    actionType: actionTypeName(action.actionType),
    rollupId: action.rollupId.toString(),
    destination: action.destination === zeroAddr ? "address(0)" : truncateAddress(action.destination),
    value: action.value.toString(),
    data: dataDisplay,
    failed: action.failed ? "true" : "false",
    sourceAddress: action.sourceAddress === zeroAddr ? "address(0)" : truncateAddress(action.sourceAddress),
    sourceRollup: action.sourceRollup.toString(),
    scope: formatScope(action.scope),
  };
}

/**
 * Extract ActionFields from an ExecutionConsumed event's action arg.
 */
export function actionFromEventArgs(actionArg: Record<string, unknown>): ActionFields {
  return {
    actionType: Number(actionArg.actionType),
    rollupId: BigInt(actionArg.rollupId as bigint),
    destination: actionArg.destination as `0x${string}`,
    value: BigInt(actionArg.value as bigint),
    data: actionArg.data as `0x${string}`,
    failed: Boolean(actionArg.failed),
    sourceAddress: actionArg.sourceAddress as `0x${string}`,
    sourceRollup: BigInt(actionArg.sourceRollup as bigint),
    scope: (actionArg.scope as bigint[]).map((s) => BigInt(s)),
  };
}

/**
 * Build a compact one-line summary of an action, like index.html's hash format:
 * "CALL{L2, B, inc(), src=A}"
 */
export function actionSummary(action: ActionFields): string {
  const type = actionTypeName(action.actionType);
  const rollup = action.rollupId === 0n ? "MAIN" : `L2(${action.rollupId})`;
  const zeroAddr = "0x0000000000000000000000000000000000000000";

  if (action.actionType === 1 || action.actionType === 3 || action.actionType === 4) {
    // RESULT / REVERT / REVERT_CONTINUE
    const dataPreview = action.data === "0x" ? '""' : truncateHex(action.data, 6);
    return `${type}{${rollup}, data=${dataPreview}}`;
  }

  if (action.actionType === 2) {
    // L2TX
    return `${type}{${rollup}, rlp=${truncateHex(action.data, 6)}}`;
  }

  // CALL
  const dest = action.destination === zeroAddr ? "0x0" : truncateAddress(action.destination);
  const selector = action.data.length >= 10 ? action.data.slice(0, 10) : action.data;
  const fnName = KNOWN_SELECTORS[selector.toLowerCase()] ?? selector;
  const src = action.sourceAddress === zeroAddr ? "0x0" : truncateAddress(action.sourceAddress);
  const scopeStr = action.scope.length > 0 ? `, scope=${formatScope(action.scope)}` : "";
  return `${type}{${rollup}, ${dest}, ${fnName}, src=${src}${scopeStr}}`;
}

/**
 * Register additional known selectors at runtime.
 */
export function registerSelector(selector: string, name: string) {
  KNOWN_SELECTORS[selector.toLowerCase()] = name;
}
