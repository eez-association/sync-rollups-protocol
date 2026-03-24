import { ActionType } from "../types/chain";

const ACTION_NAMES: Record<number, string> = {
  [ActionType.CALL]: "CALL",
  [ActionType.RESULT]: "RESULT",
  [ActionType.L2TX]: "L2TX",
  [ActionType.REVERT]: "REVERT",
  [ActionType.REVERT_CONTINUE]: "REVERT_CONTINUE",
};

export function actionTypeName(t: number): string {
  return ACTION_NAMES[t] ?? `UNKNOWN(${t})`;
}

export function truncateAddress(addr: string): string {
  if (addr.length <= 10) return addr;
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

export function truncateHex(hex: string, chars = 8): string {
  if (hex.length <= chars + 4) return hex;
  return `${hex.slice(0, chars + 2)}...`;
}

export function formatEther(wei: bigint): string {
  const eth = Number(wei) / 1e18;
  if (eth === 0) return "0";
  if (Math.abs(eth) < 0.0001) return eth.toExponential(2);
  return eth.toFixed(4).replace(/\.?0+$/, "");
}

export function formatScope(scope: bigint[]): string {
  if (scope.length === 0) return "[]";
  return `[${scope.map((s) => s.toString()).join(",")}]`;
}
