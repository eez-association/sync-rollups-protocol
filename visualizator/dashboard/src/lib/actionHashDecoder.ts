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
 * Fields that make up the cross-chain call hash in the new model.
 * crossChainCallHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
 */
export type ActionInputFields = {
  targetRollupId: bigint;
  targetAddress: `0x${string}`;
  value: bigint;
  data: `0x${string}`;
  sourceAddress: `0x${string}`;
  sourceRollupId: bigint;
};

export type DecodedActionHash = {
  computedHash: `0x${string}`;
  verified: boolean; // computed === stored
  fields: ActionInputFields;
  display: Record<string, string>;
};

const ACTION_INPUT_TYPE = [
  { type: "uint256", name: "targetRollupId" },
  { type: "address", name: "targetAddress" },
  { type: "uint256", name: "value" },
  { type: "bytes", name: "data" },
  { type: "address", name: "sourceAddress" },
  { type: "uint256", name: "sourceRollupId" },
] as const;

/**
 * Compute crossChainCallHash = keccak256(abi.encode(targetRollupId, targetAddress, value, data, sourceAddress, sourceRollupId))
 */
export function computeActionHash(fields: ActionInputFields): `0x${string}` {
  const encoded = encodeAbiParameters(ACTION_INPUT_TYPE, [
    fields.targetRollupId,
    fields.targetAddress,
    fields.value,
    fields.data,
    fields.sourceAddress,
    fields.sourceRollupId,
  ]);
  return keccak256(encoded);
}

/**
 * Decode and verify a cross-chain call hash given the input fields and the stored hash.
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
    targetRollupId: fields.targetRollupId.toString(),
    targetAddress: fields.targetAddress === zeroAddr ? "address(0)" : truncateAddress(fields.targetAddress),
    value: fields.value.toString(),
    data: dataDisplay,
    sourceAddress: fields.sourceAddress === zeroAddr ? "address(0)" : truncateAddress(fields.sourceAddress),
    sourceRollupId: fields.sourceRollupId.toString(),
  };
}

/**
 * Build a compact one-line summary of an action input:
 * "CALL{L2, B, inc(), src=A}"
 */
export function actionSummary(fields: ActionInputFields): string {
  const rollup = fields.targetRollupId === 0n ? "MAIN" : `L2(${fields.targetRollupId})`;
  const zeroAddr = "0x0000000000000000000000000000000000000000";

  const dest = fields.targetAddress === zeroAddr ? "0x0" : truncateAddress(fields.targetAddress);
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
