import React, { useMemo } from "react";
import { COLORS } from "../theme";
import type { TraceResponse, CallNode } from "../types/trace";

// ── Types ──

type FlowNode = {
  id: string;
  label: string;
  sub: string;
  chain: "l1" | "l2";
  type: "user" | "contract" | "proxy" | "system";
  col: number;
  error: boolean;
  returnVal: string | null;
  /** For proxies: the raw target contract address (to resolve name later) */
  targetAddr?: string;
};

type FlowEdge = {
  from: string;
  to: string;
  label: string;
  step: number;
  crossChain: boolean;
  isReturn: boolean;
  id: string;
};

// ── Layout constants ──

const NW = 130;
const NH = 54;
const PX = 28;
const PT = 34;
const PB = 30;
const GY = 52;
const CW = NW + 38;

function truncAddr(a: string): string {
  if (!a || a.length < 10) return a || "?";
  return a.slice(0, 6) + "…" + a.slice(-4);
}

// ── Flow extraction from trace tree ──

const SYSTEM_NAMES = new Set(["Rollups", "ManagerL2", "CrossChainManagerL2"]);

function classifyNode(node: CallNode): FlowNode["type"] {
  if (node.label === "CrossChainProxy") return "proxy";
  if (SYSTEM_NAMES.has(node.label)) return "system";
  return "contract";
}

/** Proxy label: show what it proxies for as the main label */
function nodeLabel(node: CallNode): string {
  if (node.label === "CrossChainProxy") {
    if (node.proxyTargetLabel && !node.proxyTargetLabel.startsWith("0x"))
      return node.proxyTargetLabel;
    return "Proxy";
  }
  return node.label || truncAddr(node.to);
}

function nodeSub(node: CallNode): string {
  if (node.label === "CrossChainProxy") {
    const target = node.proxyTargetLabel
      ? (node.proxyTargetLabel.startsWith("0x") ? truncAddr(node.proxyTargetLabel) : "")
      : "";
    const rid = node.proxyRollupId != null ? `rollup ${node.proxyRollupId}` : "";
    const parts = ["proxy", target, rid].filter(Boolean);
    return parts.join(" · ");
  }
  return truncAddr(node.to);
}

function buildTraceFlow(traces: TraceResponse[]): {
  l1Nodes: FlowNode[];
  l2Nodes: FlowNode[];
  edges: FlowEdge[];
} {
  const nodesMap = new Map<string, FlowNode>();
  const edges: FlowEdge[] = [];
  let step = 0;
  let l1Col = 0;
  let l2Col = 0;

  function nk(addr: string, chain: "l1" | "l2"): string {
    return `${chain}:${addr.toLowerCase()}`;
  }

  function addNode(
    addr: string,
    label: string,
    sub: string,
    chain: "l1" | "l2",
    type: FlowNode["type"],
    error = false,
    returnVal: string | null = null,
  ): string {
    const key = nk(addr, chain);
    if (!nodesMap.has(key)) {
      const col = chain === "l1" ? l1Col++ : l2Col++;
      nodesMap.set(key, { id: key, label, sub, chain, type, col, error, returnVal });
    } else if (returnVal) {
      const existing = nodesMap.get(key)!;
      if (!existing.returnVal) existing.returnVal = returnVal;
    }
    return key;
  }

  function addEdge(from: string, to: string, label: string, cc = false, ret = false) {
    step++;
    edges.push({ from, to, label, step, crossChain: cc, isReturn: ret, id: `e${step}` });
  }

  function walk(
    node: CallNode,
    chain: "l1" | "l2",
    rollups: string | null,
    managerL2: string | null,
  ) {
    const myKey = nk(node.to, chain);

    for (const child of node.calls) {
      const childKey = addNode(
        child.to,
        nodeLabel(child),
        nodeSub(child),
        chain,
        classifyNode(child),
        !!child.error,
        child.returnDecoded,
      );
      // Store raw target address on proxy nodes for later name resolution
      if (child.label === "CrossChainProxy") {
        const cn = nodesMap.get(childKey);
        if (cn) cn.targetAddr = child.proxyTargetAddr || undefined;
      }
      addEdge(myKey, childKey, child.funcName || "?");
      walk(child, chain, rollups, managerL2);
    }

    if (node.inlinedL2) {
      const fromNode = nodesMap.get(myKey);
      l2Col = Math.max(l2Col, fromNode ? fromNode.col : 0);

      // Determine L2 manager address (same address as rollups on devnet)
      const mgrAddr = managerL2 || rollups || node.to;

      if (node.inlinedL2.userCall) {
        const uc = node.inlinedL2.userCall;
        const proxyAddr = uc.from;
        const isViaProxy = proxyAddr && proxyAddr.toLowerCase() !== mgrAddr.toLowerCase();

        // Resolve L2 user contract name first (used for proxy labels)
        const l2UserLabel = nodeLabel(uc);

        // 1. ManagerL2 on L2 (cross-chain target)
        const l2MgrKey = addNode(mgrAddr, "ManagerL2", truncAddr(mgrAddr), "l2", "system");
        addEdge(myKey, l2MgrKey, "cross-chain", true);

        if (isViaProxy) {
          // 2. L2 Proxy — represents the L1 caller on L2
          // Find the L1 source (User or first non-system caller)
          let l1SourceName = "User";
          for (const [, n] of nodesMap) {
            if (n.chain === "l1" && (n.type === "user" || n.type === "contract")) {
              l1SourceName = n.label;
              break;
            }
          }
          const l2ProxyLabel = `Proxy-L1-${l1SourceName.replace(/^Proxy-L2-/, "")}`;
          const l2ProxyKey = addNode(
            proxyAddr,
            l2ProxyLabel,
            `proxy · ${truncAddr(proxyAddr)}`,
            "l2",
            "proxy",
          );
          addEdge(l2MgrKey, l2ProxyKey, uc.funcName || "?");

          // 3. User contract on L2
          const l2UserKey = addNode(
            uc.to,
            l2UserLabel,
            nodeSub(uc),
            "l2",
            classifyNode(uc),
            !!uc.error,
            uc.returnDecoded,
          );
          addEdge(l2ProxyKey, l2UserKey, uc.funcName || "?");
        } else {
          // Direct call from ManagerL2 to user contract
          const l2UserKey = addNode(
            uc.to,
            l2UserLabel,
            nodeSub(uc),
            "l2",
            classifyNode(uc),
            !!uc.error,
            uc.returnDecoded,
          );
          addEdge(l2MgrKey, l2UserKey, uc.funcName || "?");
        }

        // Rename L1 proxy: find the proxy that called Rollups (myKey) via edges
        const l2Name = nodesMap.get(nk(uc.to, "l2"))?.label;
        if (l2Name && !l2Name.startsWith("0x")) {
          for (const fe of edges) {
            if (fe.to === myKey && !fe.isReturn) {
              const src = nodesMap.get(fe.from);
              if (src?.type === "proxy" && src.chain === "l1") {
                src.label = `Proxy-L2-${l2Name}`;
                const rid = src.sub.match(/rollup \d+/)?.[0] || "";
                src.sub = `proxy${rid ? ` · ${rid}` : ""}`;
              }
            }
          }
        }

        walk(uc, "l2", rollups, managerL2);
      } else {
        // L2 execution exists but user call wasn't isolated
        const l2Key = addNode(
          node.inlinedL2.txHash || "l2-exec",
          "L2 Execution",
          `tx: ${truncAddr(node.inlinedL2.txHash || "?")}`,
          "l2",
          "system",
        );
        addEdge(myKey, l2Key, "cross-chain", true);
      }
    }
  }

  for (const trace of traces) {
    const tree = trace.callTree;
    const rollups = trace.systemContracts.rollups;
    const managerL2 = trace.systemContracts.managerL2;

    // Fix L1 label: if same address used for both, L1 = Rollups
    const rollupsLo = rollups?.toLowerCase();

    // User node
    addNode(trace.from, "User", truncAddr(trace.from), trace.chain, "user");

    // Root contract — fix label for known system contracts
    let rootLabel = nodeLabel(tree);
    const rootSub = nodeSub(tree);
    if (rollupsLo && tree.to.toLowerCase() === rollupsLo && trace.chain === "l1") {
      rootLabel = "Rollups";
    }
    addNode(
      tree.to,
      rootLabel,
      rootSub,
      trace.chain,
      classifyNode(tree),
      !!tree.error,
      tree.returnDecoded,
    );
    addEdge(nk(trace.from, trace.chain), nk(tree.to, trace.chain), tree.funcName || "?");
    walk(tree, trace.chain, rollups, managerL2);

    // Fix: ensure L1 Rollups is labeled "Rollups" not "ManagerL2"
    if (rollupsLo) {
      const l1Key = nk(rollupsLo, "l1");
      const l1Node = nodesMap.get(l1Key);
      if (l1Node && SYSTEM_NAMES.has(l1Node.label)) l1Node.label = "Rollups";
    }
  }

  const allNodes = [...nodesMap.values()];

  // Resolve proxy labels: match proxy targetAddr to any known named node
  const addrToLabel = new Map<string, string>();
  for (const n of allNodes) {
    if (n.type !== "proxy" && n.type !== "user" && n.label && !n.label.startsWith("0x")) {
      addrToLabel.set(n.id.split(":")[1], n.label);
    }
  }
  for (const n of allNodes) {
    if (n.type !== "proxy") continue;
    const tgt = n.targetAddr?.toLowerCase();
    if (!tgt) continue;
    const resolved = addrToLabel.get(tgt);
    if (resolved) {
      n.label = resolved;
      const rid = n.sub.match(/rollup \d+/)?.[0] || "";
      n.sub = `proxy${rid ? ` · ${rid}` : ""}`;
    }
  }

  // Add return edges for every forward call (every call returns)
  const forwardEdges = [...edges];
  for (let i = forwardEdges.length - 1; i >= 0; i--) {
    const fe = forwardEdges[i];
    const targetNode = nodesMap.get(fe.to);
    const retVal = targetNode?.returnVal;
    addEdge(fe.to, fe.from, retVal ? `← ${retVal}` : "←", fe.crossChain, true);
    if (targetNode) targetNode.returnVal = null;
  }

  // De-duplicate labels: if same label on both chains, append (L1)/(L2)
  const labelsByName = new Map<string, FlowNode[]>();
  for (const n of allNodes) {
    const list = labelsByName.get(n.label) || [];
    list.push(n);
    labelsByName.set(n.label, list);
  }
  for (const [, nodes] of labelsByName) {
    if (nodes.length <= 1) continue;
    const chains = new Set(nodes.map((n) => n.chain));
    if (chains.size > 1) {
      for (const n of nodes) n.label = `${n.label} (${n.chain.toUpperCase()})`;
    } else {
      for (let i = 1; i < nodes.length; i++) nodes[i].label = `${nodes[i].label} (${i + 1})`;
    }
  }

  return {
    l1Nodes: allNodes.filter((n) => n.chain === "l1"),
    l2Nodes: allNodes.filter((n) => n.chain === "l2"),
    edges,
  };
}

// ── Layout ──

type Pos = { x: number; y: number; cx: number; cy: number };

function computeFlowLayout(l1: FlowNode[], l2: FlowNode[]) {
  const maxCol =
    Math.max(...l1.map((n) => n.col), ...l2.map((n) => n.col), 0) + 1;
  const svgW = maxCol * CW + 2 * PX;
  const laneH = NH + PT + PB;
  const has2 = l2.length > 0;
  const svgH = has2 ? 2 * laneH + GY : laneH;
  const boundaryY = laneH + GY / 2;

  const pos: Record<string, Pos> = {};
  function place(nodes: FlowNode[], lane: number) {
    const y = lane === 0 ? PT : laneH + GY + PT;
    for (const n of nodes) {
      const x = PX + n.col * CW + (CW - NW) / 2;
      pos[n.id] = { x, y, cx: x + NW / 2, cy: y + NH / 2 };
    }
  }
  place(l1, 0);
  if (has2) place(l2, 1);

  return { pos, svgW, svgH, laneH, boundaryY, has2 };
}

function ncolor(type: string, chain: string): string {
  if (type === "user") return "#888";
  if (type === "proxy")
    return chain === "l1" ? "rgba(59,130,246,0.55)" : "rgba(168,85,247,0.55)";
  return chain === "l1" ? COLORS.l1 : COLORS.l2;
}

// ── Component ──

type Props = { traces: TraceResponse[] };

export const TraceDiagram: React.FC<Props> = ({ traces }) => {
  const { l1Nodes, l2Nodes, edges } = useMemo(
    () => buildTraceFlow(traces),
    [traces],
  );

  if (l1Nodes.length === 0 && l2Nodes.length === 0) return null;

  const { pos, svgW, svgH, laneH, boundaryY, has2 } = computeFlowLayout(
    l1Nodes,
    l2Nodes,
  );

  // ── Edges ──
  const edgeSvg: React.ReactNode[] = [];
  const lblSvg: React.ReactNode[] = [];

  for (const e of edges) {
    const p1 = pos[e.from];
    const p2 = pos[e.to];
    if (!p1 || !p2) continue;

    const cc = e.crossChain;
    const ret = e.isReturn;
    const stroke = ret ? COLORS.ok : cc ? COLORS.warn : COLORS.add;
    const sw = ret ? 1.2 : cc ? 2 : 1.5;
    const mkr = ret ? "ah-ret" : cc ? "ah-cc" : "ah-call";

    if (Math.abs(p1.cy - p2.cy) < 5) {
      // Same lane — quadratic bezier arc
      const right = p1.cx < p2.cx;
      const x1 = right ? p1.x + NW : p1.x;
      const x2 = right ? p2.x : p2.x + NW;
      const back = !right;
      const dir = back ? 1 : -1;
      const arcH = NH / 2 + 16;
      const mx = (x1 + x2) / 2;
      const y1 = back ? p1.y + NH : p1.y;
      const y2 = back ? p2.y + NH : p2.y;
      const my = p1.cy + dir * arcH;

      edgeSvg.push(
        <path
          key={e.id}
          d={`M${x1},${y1} Q${mx},${my} ${x2},${y2}`}
          stroke={stroke}
          strokeWidth={sw}
          fill="none"
          opacity={0.85}
          markerEnd={`url(#${mkr})`}
        />,
      );

      const ly = my + dir * 8;
      lblSvg.push(
        <g key={`l-${e.id}`}>
          <circle cx={mx - 24} cy={ly - 1} r={7} fill={stroke} opacity={0.9} />
          <text
            x={mx - 24}
            y={ly + 3}
            textAnchor="middle"
            fill="#000"
            fontSize={8}
            fontWeight={800}
            fontFamily="monospace"
          >
            {e.step}
          </text>
          <text
            x={mx - 10}
            y={ly + 3}
            fill={stroke}
            fontSize={8}
            fontWeight={700}
            fontFamily="monospace"
            opacity={0.95}
          >
            {ret ? e.label : `${e.label}()`}
          </text>
        </g>,
      );
    } else {
      // Cross-lane (vertical / diagonal) — offset returns so they don't overlap
      const xOff = ret ? 20 : 0;
      const x1 = p1.cx + xOff;
      const x2 = p2.cx + xOff;
      const y1 = p1.cy < p2.cy ? p1.y + NH : p1.y;
      const y2 = p2.cy < p1.cy ? p2.y + NH : p2.y;

      edgeSvg.push(
        <line
          key={e.id}
          x1={x1}
          y1={y1}
          x2={x2}
          y2={y2}
          stroke={stroke}
          strokeWidth={sw}
          opacity={0.85}
          markerEnd={`url(#${mkr})`}
          strokeDasharray={cc || ret ? "6 3" : undefined}
        />,
      );

      const lx = (x1 + x2) / 2 + 12;
      const ly = (y1 + y2) / 2;
      lblSvg.push(
        <g key={`l-${e.id}`}>
          <circle cx={lx - 12} cy={ly} r={7} fill={stroke} opacity={0.9} />
          <text
            x={lx - 12}
            y={ly + 3}
            textAnchor="middle"
            fill="#000"
            fontSize={8}
            fontWeight={800}
            fontFamily="monospace"
          >
            {e.step}
          </text>
          <text
            x={lx + 2}
            y={ly + 3}
            fill={stroke}
            fontSize={8}
            fontWeight={700}
            fontFamily="monospace"
            opacity={0.95}
          >
            {ret ? e.label : `${e.label}()`}
          </text>
        </g>,
      );
    }
  }

  // ── Nodes ──
  const allNodes = [...l1Nodes, ...l2Nodes];
  const nodeSvg = allNodes.map((n) => {
    const p = pos[n.id];
    if (!p) return null;
    const col = ncolor(n.type, n.chain);
    const dashed = n.type === "proxy";

    return (
      <g
        key={n.id}
        style={{ filter: `drop-shadow(0 0 8px ${col})` }}
      >
        <rect
          x={p.x}
          y={p.y}
          width={NW}
          height={NH}
          rx={6}
          fill={n.error ? "rgba(40,10,10,0.85)" : "rgba(15,15,25,0.85)"}
          stroke={n.error ? COLORS.rm : col}
          strokeWidth={2}
          strokeDasharray={dashed ? "5 3" : undefined}
        />
        <text
          x={p.cx}
          y={p.y + 20}
          textAnchor="middle"
          fill={COLORS.tx}
          fontSize={11}
          fontWeight={700}
          fontFamily="monospace"
        >
          {n.label}
        </text>
        <text
          x={p.cx}
          y={p.y + 34}
          textAnchor="middle"
          fill={COLORS.dim}
          fontSize={7}
          fontFamily="monospace"
        >
          {n.sub}
        </text>
        {/* Return value badge */}
        {n.returnVal && (
          <text
            x={p.cx}
            y={p.y + NH + 10}
            textAnchor="middle"
            fill={COLORS.ok}
            fontSize={7}
            fontWeight={700}
            fontFamily="monospace"
          >
            ← {n.returnVal}
          </text>
        )}
      </g>
    );
  });

  return (
    <div
      style={{
        background: COLORS.s1,
        border: `1px solid ${COLORS.brd}`,
        borderRadius: 8,
        padding: 12,
        overflowX: "auto",
        marginBottom: 12,
      }}
    >
      <div
        style={{
          fontWeight: 700,
          fontSize: "0.65rem",
          color: COLORS.dim,
          textTransform: "uppercase",
          letterSpacing: "0.05em",
          marginBottom: 8,
        }}
      >
        Cross-Chain Call Flow
      </div>
      <svg
        viewBox={`0 0 ${svgW} ${svgH}`}
        style={{ width: "100%", display: "block" }}
      >
        <defs>
          <marker
            id="ah-call"
            viewBox="0 0 10 7"
            refX={9}
            refY={3.5}
            markerWidth={8}
            markerHeight={6}
            orient="auto-start-reverse"
          >
            <path d="M0,0 L10,3.5 L0,7z" fill={COLORS.add} />
          </marker>
          <marker
            id="ah-cc"
            viewBox="0 0 10 7"
            refX={9}
            refY={3.5}
            markerWidth={8}
            markerHeight={6}
            orient="auto-start-reverse"
          >
            <path d="M0,0 L10,3.5 L0,7z" fill={COLORS.warn} />
          </marker>
          <marker
            id="ah-ret"
            viewBox="0 0 10 7"
            refX={9}
            refY={3.5}
            markerWidth={7}
            markerHeight={5}
            orient="auto-start-reverse"
          >
            <path d="M0,0 L10,3.5 L0,7z" fill={COLORS.ok} />
          </marker>
        </defs>

        {/* L1 lane */}
        <rect
          x={0}
          y={0}
          width={svgW}
          height={laneH}
          rx={6}
          fill="rgba(59,130,246,0.04)"
          stroke="rgba(59,130,246,0.15)"
          strokeWidth={1}
        />
        <text
          x={8}
          y={13}
          fill={COLORS.l1}
          fontSize={9}
          fontFamily="monospace"
          fontWeight={700}
          opacity={0.7}
        >
          L1
        </text>

        {/* L2 lane */}
        {has2 && (
          <>
            <rect
              x={0}
              y={laneH + GY}
              width={svgW}
              height={laneH}
              rx={6}
              fill="rgba(168,85,247,0.04)"
              stroke="rgba(168,85,247,0.15)"
              strokeWidth={1}
            />
            <text
              x={8}
              y={laneH + GY + 13}
              fill={COLORS.l2}
              fontSize={9}
              fontFamily="monospace"
              fontWeight={700}
              opacity={0.7}
            >
              L2
            </text>
            {/* Boundary */}
            <line
              x1={10}
              y1={boundaryY}
              x2={svgW - 10}
              y2={boundaryY}
              stroke="#2a2a3a"
              strokeWidth={0.5}
              strokeDasharray="4 4"
              opacity={0.5}
            />
          </>
        )}

        {edgeSvg}
        {nodeSvg}
        {lblSvg}
      </svg>
    </div>
  );
};
