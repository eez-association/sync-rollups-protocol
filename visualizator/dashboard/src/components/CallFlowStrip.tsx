import React from "react";
import { COLORS } from "../theme";
import type { DiagramItem } from "../types/visualization";

type Props = {
  items: DiagramItem[];
};

export const CallFlowStrip: React.FC<Props> = ({ items }) => {
  if (items.length === 0) return null;

  return (
    <div>
      <div
        style={{
          fontSize: 10,
          color: COLORS.dim,
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          fontWeight: 700,
          marginBottom: 10,
          opacity: 0.6,
        }}
      >
        Call flow detail
      </div>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 0,
          flexWrap: "nowrap",
          overflowX: "auto",
        }}
      >
        {items.map((item, i) => {
          if (item.kind === "arrow") {
            return <ArrowItem key={i} label={item.label} />;
          }
          return (
            <FlowNode
              key={i}
              label={item.label}
              sub={item.sub}
              type={item.type}
              chain={item.chain}
            />
          );
        })}
      </div>
    </div>
  );
};

const FlowNode: React.FC<{
  label: string;
  sub: string;
  type: string;
  chain: string;
}> = ({ label, sub, type, chain }) => {
  const borderColor =
    type === "user"
      ? "#666"
      : type === "system"
        ? chain === "l1"
          ? COLORS.l1
          : COLORS.l2
        : type === "contract"
          ? chain === "l1"
            ? COLORS.l1
            : COLORS.l2
          : type === "proxy"
            ? chain === "l1"
              ? "rgba(59,130,246,0.5)"
              : "rgba(168,85,247,0.5)"
            : COLORS.brd;

  const bg =
    type === "system"
      ? chain === "l1"
        ? COLORS.l1bg
        : COLORS.l2bg
      : type === "user"
        ? COLORS.s3
        : COLORS.s2;

  return (
    <div
      className="flow-node-enter"
      style={{
        padding: "8px 16px",
        borderRadius: 6,
        border: `1.5px ${type === "proxy" ? "dashed" : "solid"} ${borderColor}`,
        background: bg,
        textAlign: "center",
        flexShrink: 0,
      }}
    >
      <div style={{ fontSize: 13, fontWeight: 700, color: COLORS.tx }}>
        {label}
      </div>
      {sub && (
        <div style={{ fontSize: 9, color: COLORS.dim, marginTop: 1 }}>
          {sub}
        </div>
      )}
    </div>
  );
};

const ArrowItem: React.FC<{ label: string }> = ({ label }) => {
  const arrowW = 60;
  const lineLen = 48;

  return (
    <div
      className="flow-node-enter"
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        flexShrink: 0,
        padding: "0 2px",
      }}
    >
      <div
        style={{
          fontSize: 9,
          color: COLORS.dim,
          whiteSpace: "nowrap",
          marginBottom: 3,
          maxWidth: 120,
          overflow: "hidden",
          textOverflow: "ellipsis",
        }}
      >
        {label}
      </div>
      <svg
        width={arrowW}
        height={10}
        viewBox={`0 0 ${arrowW} 10`}
        style={{ display: "block" }}
      >
        <line
          x1={4}
          y1={5}
          x2={lineLen}
          y2={5}
          stroke={COLORS.dim}
          strokeWidth={1.5}
        />
        <polygon
          points={`${lineLen - 1},1 ${lineLen + 6},5 ${lineLen - 1},9`}
          fill={COLORS.dim}
        />
      </svg>
    </div>
  );
};
