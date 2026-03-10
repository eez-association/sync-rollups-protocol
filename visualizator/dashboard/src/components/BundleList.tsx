import React, { useMemo, useState } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { buildTransactionBundles } from "../lib/crossChainCorrelation";
import { truncateHex } from "../lib/actionFormatter";
import type { TransactionBundle, BundleDirection } from "../types/visualization";

const DIRECTION_COLORS: Record<BundleDirection, string> = {
  "L1->L2": COLORS.l1,
  "L2->L1": COLORS.l2,
  "L1->L2->L1": COLORS.warn,
  "L2->L1->L2": COLORS.warn,
  "L1": COLORS.l1,
  "L2": COLORS.l2,
  "mixed": COLORS.dim,
};

type Props = {
  onSelectBundle: (bundle: TransactionBundle) => void;
  selectedBundleId: string | null;
};

export const BundleList: React.FC<Props> = ({ onSelectBundle, selectedBundleId }) => {
  const events = useStore((s) => s.events);

  const bundles = useMemo(() => buildTransactionBundles(events), [events]);

  // Only show multi-event bundles or important standalone ones
  const significantBundles = useMemo(
    () => bundles.filter((b) => b.events.length > 1 || b.actionHashes.length > 0),
    [bundles],
  );

  if (significantBundles.length === 0) {
    return (
      <div
        style={{
          textAlign: "center",
          color: COLORS.dim,
          fontSize: "0.55rem",
          padding: 16,
          opacity: 0.4,
        }}
      >
        No cross-chain bundles yet...
      </div>
    );
  }

  return (
    <div style={{ padding: 6 }}>
      {significantBundles.map((bundle) => (
        <BundleCard
          key={bundle.id}
          bundle={bundle}
          selected={bundle.id === selectedBundleId}
          onClick={() => onSelectBundle(bundle)}
        />
      ))}
    </div>
  );
};

const BundleCard: React.FC<{
  bundle: TransactionBundle;
  selected: boolean;
  onClick: () => void;
}> = ({ bundle, selected, onClick }) => {
  const [hovered, setHovered] = useState(false);
  const dirColor = DIRECTION_COLORS[bundle.direction];
  const isComplete = bundle.status === "complete";

  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      style={{
        display: "flex",
        gap: 8,
        padding: "7px 10px",
        borderRadius: 6,
        border: `1px solid ${selected ? COLORS.acc : hovered ? COLORS.brd : "transparent"}`,
        background: selected ? COLORS.s2 : COLORS.s1,
        marginBottom: 5,
        cursor: "pointer",
        transition: "all 0.15s",
        fontSize: "0.6rem",
        lineHeight: 1.4,
      }}
    >
      {/* Direction badge */}
      <div
        style={{
          flexShrink: 0,
          padding: "2px 6px",
          borderRadius: 4,
          fontSize: "0.48rem",
          fontWeight: 700,
          background: `${dirColor}15`,
          color: dirColor,
          border: `1px solid ${dirColor}30`,
          whiteSpace: "nowrap",
          marginTop: 1,
        }}
      >
        {bundle.direction}
      </div>

      {/* Body */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 700, fontSize: "0.58rem" }}>{bundle.title}</div>

        {/* Meta row */}
        <div style={{ display: "flex", gap: 8, marginTop: 2, fontSize: "0.48rem", color: COLORS.dim }}>
          <span>{bundle.events.length} events</span>
          <span>{bundle.actionHashes.length} action{bundle.actionHashes.length !== 1 ? "s" : ""}</span>
          <span>
            block {bundle.blockRange.from.toString()}
            {bundle.blockRange.to !== bundle.blockRange.from && `-${bundle.blockRange.to.toString()}`}
          </span>
        </div>

        {/* Action hashes */}
        {bundle.actionHashes.length > 0 && (
          <div style={{ marginTop: 3, display: "flex", flexWrap: "wrap", gap: 3 }}>
            {bundle.actionHashes.slice(0, 3).map((h) => (
              <span
                key={h}
                style={{
                  fontSize: "0.45rem",
                  padding: "1px 4px",
                  borderRadius: 3,
                  background: COLORS.s3,
                  color: COLORS.add,
                  fontFamily: "monospace",
                }}
              >
                {truncateHex(h, 8)}
              </span>
            ))}
            {bundle.actionHashes.length > 3 && (
              <span style={{ fontSize: "0.45rem", color: COLORS.dim }}>
                +{bundle.actionHashes.length - 3} more
              </span>
            )}
          </div>
        )}

        {/* Tx hashes */}
        <div style={{ marginTop: 3, fontSize: "0.45rem", color: COLORS.dim }}>
          {[...bundle.txHashes].slice(0, 2).map((h) => (
            <span key={h} style={{ marginRight: 6 }}>
              tx: {truncateHex(h, 8)}
            </span>
          ))}
          {bundle.txHashes.size > 2 && (
            <span>+{bundle.txHashes.size - 2} more</span>
          )}
        </div>
      </div>

      {/* Status */}
      <div
        style={{
          flexShrink: 0,
          alignSelf: "center",
          width: 8,
          height: 8,
          borderRadius: "50%",
          background: isComplete ? COLORS.ok : COLORS.warn,
          boxShadow: `0 0 6px ${isComplete ? "rgba(52,211,153,0.4)" : "rgba(245,158,11,0.4)"}`,
        }}
        title={isComplete ? "Complete" : "In progress"}
      />
    </div>
  );
};
