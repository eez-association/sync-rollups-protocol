import React from "react";
import { COLORS } from "../theme";
import type { TableEntry, Chain } from "../types/visualization";
import { TableEntryRow } from "./TableEntryRow";

type Props = {
  title: string;
  chain: Chain;
  entries: TableEntry[];
};

export const TablePanel: React.FC<Props> = ({ title, chain, entries }) => {
  const activeCount = entries.filter(
    (e) => e.status === "ok" || e.status === "ja",
  ).length;

  const color = chain === "l1" ? COLORS.l1 : COLORS.l2;
  const borderColor = chain === "l1" ? COLORS.l1b : COLORS.l2b;
  const bgColor = chain === "l1" ? COLORS.l1bg : COLORS.l2bg;

  return (
    <div
      style={{
        borderRadius: 8,
        border: `1px solid ${borderColor}`,
        background: COLORS.s1,
        overflow: "hidden",
        display: "flex",
        flexDirection: "column",
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "6px 10px",
          borderBottom: `1px solid ${COLORS.brd}`,
          background: bgColor,
          fontSize: "0.62rem",
          fontWeight: 700,
        }}
      >
        <span style={{ color }}>{title}</span>
        <span
          style={{
            fontSize: "0.55rem",
            padding: "1px 6px",
            borderRadius: 3,
            background: COLORS.s2,
            color: COLORS.dim,
          }}
        >
          {activeCount} entries
        </span>
      </div>
      <div style={{ padding: 5, flex: 1, overflow: "auto", minHeight: 40 }}>
        {entries.length === 0 ? (
          <div
            style={{
              textAlign: "center",
              color: COLORS.dim,
              fontSize: "0.55rem",
              padding: 8,
              opacity: 0.4,
            }}
          >
            (empty)
          </div>
        ) : (
          entries.map((e, i) => (
            <TableEntryRow key={e.id} entry={e} index={i} />
          ))
        )}
      </div>
    </div>
  );
};
