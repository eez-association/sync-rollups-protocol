import React, { useState } from "react";
import { COLORS } from "../theme";
import type { TableEntry } from "../types/visualization";
import { truncateHex } from "../lib/actionFormatter";

type Props = {
  entry: TableEntry;
  index: number;
};

export const TableEntryRow: React.FC<Props> = ({ entry, index }) => {
  const [expanded, setExpanded] = useState(true);
  const isAdded = entry.status === "ja";
  const isConsuming = entry.status === "jc";
  const isConsumed = entry.status === "consumed";

  const borderColor = isAdded
    ? COLORS.add
    : isConsuming
      ? COLORS.rm
      : COLORS.brd;

  const glowShadow = isAdded
    ? "0 0 8px rgba(34,211,238,0.15)"
    : isConsuming
      ? "0 0 8px rgba(239,68,68,0.12)"
      : "none";

  return (
    <div
      style={{
        borderRadius: 5,
        border: `1px solid ${borderColor}`,
        background: COLORS.s2,
        marginBottom: 4,
        opacity: isConsuming ? 0.35 : isConsumed ? 0.25 : 1,
        boxShadow: glowShadow,
        overflow: "hidden",
        transition: "all 0.3s",
        fontSize: "0.6rem",
        animation: isAdded
          ? "entryAdd 0.4s ease-out"
          : isConsuming
            ? "entryConsume 0.4s ease-out"
            : undefined,
      }}
    >
      {/* Summary row */}
      <div
        onClick={() => setExpanded(!expanded)}
        style={{
          display: "flex",
          alignItems: "flex-start",
          gap: 6,
          padding: "5px 8px",
          cursor: "pointer",
          textDecoration: isConsuming || isConsumed ? "line-through" : "none",
        }}
      >
        <div
          style={{
            width: 15,
            height: 15,
            borderRadius: "50%",
            background: COLORS.s3,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            fontSize: "0.45rem",
            fontWeight: 700,
            color: COLORS.dim,
            flexShrink: 0,
            marginTop: 1,
          }}
        >
          {index + 1}
        </div>
        <div style={{ flex: 1, lineHeight: 1.4, minWidth: 0 }}>
          <span style={{ color: COLORS.dim }}>{entry.actionHash}</span>
          <span style={{ color: COLORS.warn, margin: "0 3px" }}>{" -> "}</span>
          <span style={{ color: COLORS.ok }}>{entry.nextActionHash}</span>
          {entry.delta && (
            <span
              style={{
                display: "block",
                color: COLORS.dim,
                fontSize: "0.5rem",
                opacity: 0.7,
                marginTop: 1,
              }}
            >
              {entry.delta}
            </span>
          )}
        </div>
        <div
          style={{
            flexShrink: 0,
            fontSize: "0.5rem",
            color: COLORS.dim,
            marginTop: 1,
            cursor: "pointer",
          }}
        >
          {expanded ? "\u25B2" : "\u25BC"}
        </div>
      </div>

      {/* Expanded details */}
      {expanded && (
        <div
          style={{
            borderTop: `1px solid ${COLORS.brd}`,
            padding: "6px 8px",
            background: "rgba(0,0,0,0.2)",
            fontSize: "0.55rem",
          }}
        >
          {/* Action Hash section */}
          {entry.actionDetail && (
            <HashSection
              title="Action (hashed as actionHash)"
              detail={entry.actionDetail}
              fullHash={entry.fullActionHash}
            />
          )}

          {/* Next Action section */}
          {entry.nextActionDetail && (
            <HashSection
              title="Next Action (returned on match)"
              detail={entry.nextActionDetail}
              fullHash={entry.fullNextActionHash}
            />
          )}

          {/* State Deltas */}
          {entry.stateDeltas.length > 0 && (
            <div style={{ marginBottom: 6 }}>
              <SectionHeader>State Delta</SectionHeader>
              <KVGrid>
                {entry.stateDeltas.map((sd, i) => (
                  <React.Fragment key={i}>
                    <span style={{ color: COLORS.dim }}>delta {i}</span>
                    <span style={{ color: COLORS.tx, wordBreak: "break-all" }}>{sd}</span>
                  </React.Fragment>
                ))}
              </KVGrid>
            </div>
          )}
        </div>
      )}
    </div>
  );
};

const SectionHeader: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div
    style={{
      fontSize: "0.5rem",
      fontWeight: 700,
      color: COLORS.acc,
      textTransform: "uppercase",
      letterSpacing: "0.05em",
      marginBottom: 3,
    }}
  >
    {children}
  </div>
);

const KVGrid: React.FC<{ children: React.ReactNode }> = ({ children }) => (
  <div style={{ display: "grid", gridTemplateColumns: "90px 1fr", gap: "1px 8px", fontSize: "0.53rem" }}>
    {children}
  </div>
);

const HashSection: React.FC<{
  title: string;
  detail: Record<string, string>;
  fullHash?: string;
}> = ({ title, detail, fullHash }) => {
  const [showFull, setShowFull] = useState(false);

  // Separate computedHash from the rest
  const { computedHash, actionHash, ...fields } = detail;
  const displayHash = computedHash || actionHash;
  const hasDecodedFields = Object.keys(fields).length > 0;

  return (
    <div style={{ marginBottom: 6 }}>
      <SectionHeader>{title}</SectionHeader>
      <KVGrid>
        {/* Show the hash */}
        {displayHash && (
          <>
            <span style={{ color: COLORS.dim }}>
              {computedHash ? "computedHash" : "actionHash"}
            </span>
            <span style={{ wordBreak: "break-all" }}>
              <span
                style={{ color: COLORS.add, cursor: "pointer" }}
                onClick={(e) => {
                  e.stopPropagation();
                  setShowFull(!showFull);
                }}
                title={fullHash || displayHash}
              >
                {showFull ? (fullHash || displayHash) : truncateHex(displayHash, 12)}
              </span>
              {fullHash && (
                <CopyButton text={fullHash} />
              )}
            </span>
          </>
        )}

        {/* Show decoded fields */}
        {hasDecodedFields && Object.entries(fields).map(([k, v]) => (
          <React.Fragment key={k}>
            <span style={{ color: COLORS.dim }}>{k}</span>
            <span
              style={{
                color: isHighlightField(k, v) ? COLORS.add : COLORS.tx,
                wordBreak: "break-all",
              }}
            >
              {v}
            </span>
          </React.Fragment>
        ))}

        {/* If no decoded fields (action hash only), show hint */}
        {!hasDecodedFields && actionHash && (
          <>
            <span style={{ color: COLORS.dim }}>decoded</span>
            <span style={{ color: COLORS.dim, fontStyle: "italic", opacity: 0.5 }}>
              available when consumed (ExecutionConsumed event)
            </span>
          </>
        )}
      </KVGrid>
    </div>
  );
};

const CopyButton: React.FC<{ text: string }> = ({ text }) => {
  const [copied, setCopied] = useState(false);
  return (
    <button
      onClick={(e) => {
        e.stopPropagation();
        navigator.clipboard.writeText(text);
        setCopied(true);
        setTimeout(() => setCopied(false), 1500);
      }}
      style={{
        marginLeft: 4,
        fontSize: "0.45rem",
        color: copied ? COLORS.ok : COLORS.dim,
        background: "none",
        border: "none",
        cursor: "pointer",
        fontFamily: "monospace",
        padding: "0 2px",
      }}
      title="Copy full hash"
    >
      {copied ? "copied" : "copy"}
    </button>
  );
};

function isHighlightField(key: string, value: string): boolean {
  if (key === "actionType") return true;
  if (key === "data" && value !== "0x" && value !== "0x00") return true;
  return false;
}
