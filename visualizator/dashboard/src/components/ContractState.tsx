import React from "react";
import { COLORS } from "../theme";
import type { Chain } from "../types/visualization";

type Props = {
  contractState: Record<string, string>;
  changedKeys: string[];
};

export const ContractState: React.FC<Props> = ({
  contractState,
  changedKeys,
}) => {
  const entries = Object.entries(contractState);
  if (entries.length === 0) return null;

  const l1Entries = entries.filter(([k]) => k.startsWith("Rollup"));
  const l2Entries = entries.filter(([k]) => !k.startsWith("Rollup"));

  return (
    <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 10 }}>
      <StatePanel
        title="L1 Contracts"
        chain="l1"
        entries={l1Entries}
        changedKeys={changedKeys}
      />
      {l2Entries.length > 0 && (
        <StatePanel
          title="L2 Contracts"
          chain="l2"
          entries={l2Entries}
          changedKeys={changedKeys}
        />
      )}
    </div>
  );
};

const StatePanel: React.FC<{
  title: string;
  chain: Chain;
  entries: [string, string][];
  changedKeys: string[];
}> = ({ title, chain, entries, changedKeys }) => {
  const color = chain === "l1" ? COLORS.l1 : COLORS.l2;
  const borderColor = chain === "l1" ? COLORS.l1b : COLORS.l2b;

  return (
    <div
      style={{
        borderRadius: 8,
        border: `1px solid ${borderColor}`,
        background: COLORS.s1,
        padding: "6px 10px",
      }}
    >
      <h4
        style={{
          fontSize: "0.55rem",
          fontWeight: 700,
          textTransform: "uppercase",
          letterSpacing: "0.06em",
          color,
          opacity: 0.5,
          marginBottom: 5,
        }}
      >
        {title}
      </h4>
      {entries.map(([key, value]) => {
        const isChanged = changedKeys.includes(key);
        return (
          <div
            key={key}
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: "0.58rem",
              padding: "2px 0",
              borderBottom: "1px solid rgba(255,255,255,0.03)",
            }}
          >
            <span style={{ color: COLORS.dim }}>{key}</span>
            <span
              style={{
                fontWeight: 700,
                color: isChanged ? COLORS.ok : COLORS.tx,
                transition: "color 1s ease",
              }}
            >
              {value}
            </span>
          </div>
        );
      })}
    </div>
  );
};
