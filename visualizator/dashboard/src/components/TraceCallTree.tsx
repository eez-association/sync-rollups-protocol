import React from "react";
import { COLORS } from "../theme";
import type { CallNode } from "../types/trace";

type Props = {
  tree: CallNode;
  chain: "l1" | "l2";
  expandedNodes: Set<string>;
  onToggleExpand: (path: string) => void;
};

export const TraceCallTree: React.FC<Props> = ({
  tree,
  chain,
  expandedNodes,
  onToggleExpand,
}) => {
  return (
    <div
      style={{
        background: COLORS.s1,
        border: `1px solid ${COLORS.brd}`,
        borderRadius: 6,
        padding: "12px 0",
        overflow: "auto",
        fontSize: "0.7rem",
        lineHeight: 1.7,
      }}
    >
      <TreeNode
        node={tree}
        chain={chain}
        depth={0}
        isLast={true}
        continuations={[]}
        path="0"
        expandedNodes={expandedNodes}
        onToggleExpand={onToggleExpand}
      />
    </div>
  );
};

// ── Shared row rendering helper ──

const TreeRow: React.FC<{
  chain: "l1" | "l2";
  continuations: boolean[];
  depth: number;
  isLast: boolean;
  connector?: "branch" | "return";
  children: React.ReactNode;
  onClick?: () => void;
  bg?: string;
}> = ({ chain, continuations, depth, isLast, connector = "branch", children, onClick, bg }) => (
  <div
    onClick={onClick}
    style={{
      display: "flex",
      alignItems: "flex-start",
      minHeight: 24,
      paddingRight: 12,
      cursor: onClick ? "pointer" : "default",
      background: bg || "transparent",
    }}
  >
    {/* Chain badge */}
    <div
      style={{
        width: 28,
        flexShrink: 0,
        textAlign: "center",
        fontWeight: 700,
        fontSize: "0.55rem",
        color: chain === "l1" ? COLORS.l1 : COLORS.l2,
        paddingTop: 3,
        paddingLeft: 8,
      }}
    >
      {chain.toUpperCase()}
    </div>

    {/* Connector columns */}
    {continuations.map((continues, i) => (
      <div
        key={i}
        style={{
          width: 20,
          flexShrink: 0,
          borderLeft: continues ? `1px solid ${COLORS.brd}` : "none",
          marginLeft: i === 0 ? 4 : 0,
          minHeight: 24,
        }}
      />
    ))}

    {/* Branch connector */}
    {depth > 0 && connector === "branch" && (
      <div style={{ width: 20, flexShrink: 0, position: "relative", minHeight: 24 }}>
        <span style={{ color: COLORS.dim, fontSize: "0.65rem", position: "absolute", top: 0, left: 0 }}>
          {isLast ? "└─" : "├─"}
        </span>
      </div>
    )}

    {/* Return connector (no branch char, just indent) */}
    {depth > 0 && connector === "return" && (
      <div style={{ width: 20, flexShrink: 0 }} />
    )}

    {/* Content */}
    <div style={{ flex: 1, display: "flex", flexWrap: "wrap", gap: 4, paddingTop: 1 }}>
      {children}
    </div>
  </div>
);

// ── Single tree node (recursive) ──

type TreeNodeProps = {
  node: CallNode;
  chain: "l1" | "l2";
  depth: number;
  isLast: boolean;
  continuations: boolean[];
  path: string;
  expandedNodes: Set<string>;
  onToggleExpand: (path: string) => void;
};

const TreeNode: React.FC<TreeNodeProps> = ({
  node,
  chain,
  depth,
  isLast,
  continuations,
  path,
  expandedNodes,
  onToggleExpand,
}) => {
  const isExpanded = expandedNodes.has(path);
  const hasDetails = node.to || node.value !== "0x0";
  const hasChildren = node.calls.length > 0 || !!node.inlinedL2;

  // Format the call header
  const isProxy = node.label === "CrossChainProxy" || !!node.proxyTargetLabel;
  const callLabel = isProxy
    ? `proxy[${node.proxyTargetLabel || "?"}@rollup${node.proxyRollupId ?? "?"}]`
    : node.label;

  // Continuations for children: parent continues if not last
  const childContinuations = depth > 0
    ? [...continuations, !isLast]
    : continuations;

  return (
    <>
      {/* Main call row */}
      <TreeRow
        chain={chain}
        continuations={continuations}
        depth={depth}
        isLast={isLast}
        onClick={hasDetails ? () => onToggleExpand(path) : undefined}
        bg={node.error ? "rgba(239,68,68,0.05)" : undefined}
      >
        {/* Icon */}
        <span style={{ color: node.error ? COLORS.rm : COLORS.add, flexShrink: 0 }}>
          {node.error ? "✗" : "→"}
        </span>

        {/* Contract::function */}
        <span>
          {isProxy ? (
            <span style={{ color: COLORS.dim }}>{callLabel}</span>
          ) : (
            <span style={{ fontWeight: 700 }}>{callLabel}</span>
          )}
          <span style={{ color: COLORS.dim }}>::</span>
          <span style={{ fontWeight: 700 }}>{node.funcName}()</span>
        </span>

        {/* ETH value */}
        {node.value && node.value !== "0x0" && node.value !== "0" && (
          <span style={{ color: COLORS.warn, fontSize: "0.6rem" }}>
            {"{value: " + node.value + "}"}
          </span>
        )}

        {/* Inline return (only for leaf nodes with no children) */}
        {!hasChildren && node.returnDecoded && !node.error && (
          <span style={{ color: COLORS.ok }}>← {node.returnDecoded}</span>
        )}

        {/* Error */}
        {node.error && (
          <span style={{ color: COLORS.rm }}>
            REVERT: {node.error.length > 80 ? node.error.slice(0, 77) + "..." : node.error}
          </span>
        )}
      </TreeRow>

      {/* Expanded details */}
      {isExpanded && (
        <div
          style={{
            marginLeft: 28 + continuations.length * 20 + (depth > 0 ? 20 : 0),
            padding: "2px 12px 6px",
            fontSize: "0.6rem",
            color: COLORS.dim,
            borderLeft: `1px solid ${COLORS.brd}`,
          }}
        >
          {node.to && <div>to: {node.to}</div>}
          {node.from && <div>from: {node.from}</div>}
          {node.type && <div>type: {node.type}</div>}
          {node.value && node.value !== "0x0" && <div>value: {node.value}</div>}
        </div>
      )}

      {/* Cross-chain boundary: inlined L2 execution */}
      {node.inlinedL2 && (
        <CrossChainBoundary
          inlined={node.inlinedL2}
          depth={depth}
          continuations={childContinuations}
          path={path}
          expandedNodes={expandedNodes}
          onToggleExpand={onToggleExpand}
        />
      )}

      {/* Children */}
      {node.calls.map((child, i) => {
        const childIsLast = i === node.calls.length - 1;
        return (
          <TreeNode
            key={i}
            node={child}
            chain={chain}
            depth={depth + 1}
            isLast={childIsLast}
            continuations={childContinuations}
            path={`${path}.${i}`}
            expandedNodes={expandedNodes}
            onToggleExpand={onToggleExpand}
          />
        );
      })}

      {/* Return value arrow (separate line after children, like trace-decoder) */}
      {hasChildren && node.returnDecoded && !node.error && (
        <TreeRow
          chain={chain}
          continuations={continuations}
          depth={depth}
          isLast={isLast}
          connector="return"
        >
          <span style={{ color: COLORS.ok, fontWeight: 600 }}>
            ← {node.returnDecoded}
          </span>
        </TreeRow>
      )}
    </>
  );
};

// ── Cross-chain boundary (L2 inline) ──

type CrossChainBoundaryProps = {
  inlined: NonNullable<CallNode["inlinedL2"]>;
  depth: number;
  continuations: boolean[];
  path: string;
  expandedNodes: Set<string>;
  onToggleExpand: (path: string) => void;
};

const CrossChainBoundary: React.FC<CrossChainBoundaryProps> = ({
  inlined,
  depth,
  continuations,
  path,
  expandedNodes,
  onToggleExpand,
}) => {
  const indent = 28 + continuations.length * 20 + 20;

  return (
    <div
      style={{
        marginLeft: indent,
        marginTop: 2,
        marginBottom: 2,
        border: `2px solid ${COLORS.l2}`,
        borderRadius: 6,
        background: COLORS.l2bg,
        padding: "4px 0",
        position: "relative",
      }}
    >
      {/* L2 header bar */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "0 10px 4px",
          borderBottom: `1px solid ${COLORS.l2b}`,
          fontSize: "0.55rem",
          color: COLORS.l2,
          fontWeight: 700,
        }}
      >
        <span>═══ L2 ═══</span>
        {inlined.proxyInfo && (
          <span style={{ color: COLORS.dim, fontWeight: 400, fontSize: "0.6rem" }}>
            via {inlined.proxyInfo}
          </span>
        )}
        {inlined.txHash && (
          <span style={{ color: COLORS.dim, fontWeight: 400, fontSize: "0.55rem" }}>
            tx: {inlined.txHash.slice(0, 10)}...
          </span>
        )}
      </div>

      {/* L2 user call */}
      {inlined.userCall ? (
        <TreeNode
          node={inlined.userCall}
          chain="l2"
          depth={0}
          isLast={true}
          continuations={[]}
          path={`${path}.l2`}
          expandedNodes={expandedNodes}
          onToggleExpand={onToggleExpand}
        />
      ) : (
        <div
          style={{
            padding: "4px 10px",
            color: COLORS.dim,
            fontSize: "0.6rem",
            fontStyle: "italic",
          }}
        >
          (no user execution found)
        </div>
      )}
    </div>
  );
};
