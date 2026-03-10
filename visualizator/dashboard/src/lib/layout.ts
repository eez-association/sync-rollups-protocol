import type { ArchNode, Architecture } from "../types/visualization";

export const NODE_W = 88;
export const NODE_H = 42;
export const PAD_X = 20;
export const PAD_TOP = 28;
export const PAD_BOT = 24;
export const GAP_Y = 28;

export type NodePos = { x: number; y: number; cx: number; cy: number };

export function computeLayout(arch: Architecture) {
  const cellW = NODE_W + 28;
  const svgW = arch.cols * cellW + 2 * PAD_X;
  const laneH = NODE_H + PAD_TOP + PAD_BOT;
  const svgH = 2 * laneH + GAP_Y;
  const boundaryY = laneH + GAP_Y / 2;

  const pos: Record<string, NodePos> = {};

  function place(nodes: ArchNode[], laneIdx: number) {
    const y = laneIdx === 0 ? PAD_TOP : laneH + GAP_Y + PAD_TOP;
    for (const n of nodes) {
      const x = PAD_X + n.col * cellW + (cellW - NODE_W) / 2;
      pos[n.id] = { x, y, cx: x + NODE_W / 2, cy: y + NODE_H / 2 };
    }
  }

  place(arch.l1, 0);
  place(arch.l2, 1);

  return { pos, svgW, svgH, laneH, boundaryY, cellW };
}

export function nodeColor(type: string, chain?: string): string {
  if (type === "ghost") return "#4a4a60";
  if (type === "user") return "#666";
  const colors: Record<string, string> = {
    "contract-l1": "#3b82f6",
    "proxy-l1": "rgba(59,130,246,0.5)",
    "contract-l2": "#a855f7",
    "proxy-l2": "rgba(168,85,247,0.5)",
    "system-l1": "#3b82f6",
    "system-l2": "#a855f7",
  };
  return colors[`${type}-${chain}`] || "#555";
}
