import { encodeAbiParameters, keccak256 } from "viem";
import { truncateAddress, truncateHex } from "./actionFormatter";

// Known function selectors from the contracts
const KNOWN_SELECTORS: Record<string, string> = {
  "0xd09de08a": "increment()",
  "0x06661abd": "counter()",
  "0x5a6a9e05": "targetCounter()",
  "0x1c71ef55": "incrementProxy()",
};

/**
 * Fields that make up the action hash in the new model.
 * actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))
 */
export type ActionInputFields = {
  rollupId: bigint;
  destination: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  sourceAddress: `0x${string}`;
  sourceRollup: bigint;
};

export type DecodedActionHash = {
  computedHash: `0x${string}`;
  verified: boolean; // computed === stored
  fields: ActionInputFields;
  display: Record<string, string>;
};

const ACTION_INPUT_TYPE = [
  { type: "uint256", name: "rollupId" },
  { type: "address", name: "destination" },
  { type: "uint256", name: "value" },
  { type: "bytes", name: "data" },
  { type: "address", name: "sourceAddress" },
  { type: "uint256", name: "sourceRollup" },
] as const;

/**
 * Compute actionHash = keccak256(abi.encode(rollupId, destination, value, data, sourceAddress, sourceRollup))
 */
export function computeActionHash(fields: ActionInputFields): `0x${string}` {
  const encoded = encodeAbiParameters(ACTION_INPUT_TYPE, [
    fields.rollupId,
    fields.destination,
    fields.value,
    fields.data,
    fields.sourceAddress,
    fields.sourceRollup,
  ]);
  return keccak256(encoded);
}

/**
 * Decode and verify an action hash given the input fields and the stored hash.
 */
export function decodeActionHash(
  storedHash: string,
  fields: ActionInputFields,
): DecodedActionHash {
  const computedHash = computeActionHash(fields);
  const verified = computedHash.toLowerCase() === storedHash.toLowerCase();

  return {
    computedHash,
    verified,
    fields,
    display: formatActionInputFields(fields),
  };
}

/**
 * Format action input fields for display, with human-readable labels.
 */
export function formatActionInputFields(fields: ActionInputFields): Record<string, string> {
  const dataSelector = fields.data.length >= 10 ? fields.data.slice(0, 10) : fields.data;
  const selectorName = KNOWN_SELECTORS[dataSelector.toLowerCase()];
  const dataDisplay = selectorName
    ? `${dataSelector} (${selectorName})`
    : fields.data.length > 20
      ? truncateHex(fields.data)
      : fields.data;

  const zeroAddr = "0x0000000000000000000000000000000000000000";

  return {
    rollupId: fields.rollupId.toString(),
    destination: fields.destination === zeroAddr ? "address(0)" : truncateAddress(fields.destination),
    value: fields.value.toString(),
    data: dataDisplay,
    sourceAddress: fields.sourceAddress === zeroAddr ? "address(0)" : truncateAddress(fields.sourceAddress),
    sourceRollup: fields.sourceRollup.toString(),
  };
}

/**
 * Build a compact one-line summary of an action input:
 * "CALL{L2, B, inc(), src=A}"
 */
export function actionSummary(fields: ActionInputFields): string {
  const rollup = fields.rollupId === 0n ? "MAIN" : `L2(${fields.rollupId})`;
  const zeroAddr = "0x0000000000000000000000000000000000000000";

  const dest = fields.destination === zeroAddr ? "0x0" : truncateAddress(fields.destination);
  const selector = fields.data.length >= 10 ? fields.data.slice(0, 10) : fields.data;
  const fnName = KNOWN_SELECTORS[selector.toLowerCase()] ?? selector;
  const src = fields.sourceAddress === zeroAddr ? "0x0" : truncateAddress(fields.sourceAddress);
  return `CALL{${rollup}, ${dest}, ${fnName}, src=${src}}`;
}

/**
 * Register additional known selectors at runtime.
 */
export function registerSelector(selector: string, name: string) {
  KNOWN_SELECTORS[selector.toLowerCase()] = name;
}
