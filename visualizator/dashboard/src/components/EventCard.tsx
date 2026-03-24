import React, { useState, useMemo } from "react";
import { COLORS } from "../theme";
import type { EventRecord } from "../types/events";
import { truncateHex, truncateAddress } from "../lib/actionFormatter";
import { TxDetails } from "./TxDetails";
import { actionFromEventArgs, decodeActionHash, actionSummary } from "../lib/actionHashDecoder";

type Props = {
  event: EventRecord;
  selected: boolean;
  onClick: () => void;
  correlatedChain?: "l1" | "l2";
  stepNumber: number;
  isPlayed: boolean;
};

const EVENT_COLORS: Record<string, string> = {
  BatchPosted: COLORS.l1,
  ExecutionTableLoaded: COLORS.l2,
  ExecutionConsumed: COLORS.rm,
  CrossChainCallExecuted: COLORS.add,
  CrossChainProxyCreated: COLORS.ok,
  RollupCreated: COLORS.acc,
  StateUpdated: COLORS.warn,
  L2ExecutionPerformed: COLORS.l2,
  IncomingCrossChainCallExecuted: COLORS.l2,
  L2TXExecuted: COLORS.warn,
};

function eventColor(eventName: string): string {
  return EVENT_COLORS[eventName] ?? COLORS.dim;
}

function eventDetail(event: EventRecord): string {
  switch (event.eventName) {
    case "BatchPosted": {
      const entries = event.args.entries as unknown[] | undefined;
      return entries ? `Posts ${entries.length} execution ${entries.length === 1 ? "entry" : "entries"} to L1 table` : "";
    }
    case "ExecutionTableLoaded": {
      const entries = event.args.entries as unknown[] | undefined;
      return entries ? `Loads ${entries.length} ${entries.length === 1 ? "entry" : "entries"} into L2 table` : "";
    }
    case "ExecutionConsumed":
      return `Entry consumed: ${truncateHex(event.args.actionHash as string)}`;
    case "CrossChainCallExecuted":
      return `Proxy ${truncateAddress(event.args.proxy as string)} called by ${truncateAddress(event.args.sourceAddress as string)}`;
    case "CrossChainProxyCreated":
      return `Proxy ${truncateAddress(event.args.proxy as string)} for ${truncateAddress(event.args.originalAddress as string)}`;
    case "IncomingCrossChainCallExecuted":
      return `Incoming call to ${truncateAddress(event.args.destination as string)} from ${truncateAddress(event.args.sourceAddress as string)}`;
    case "RollupCreated":
      return `Rollup ${String(event.args.rollupId)} created`;
    case "L2ExecutionPerformed":
      return `State updated for rollup ${String(event.args.rollupId)}`;
    default:
      return "";
  }
}

function tableChangeSummary(event: EventRecord): { adds: string[]; consumes: string[] } {
  const adds: string[] = [];
  const consumes: string[] = [];
  if (event.eventName === "BatchPosted") {
    const entries = event.args.entries as Array<{ actionHash: string }> | undefined;
    if (entries) {
      for (const e of entries) {
        if (e.actionHash !== "0x0000000000000000000000000000000000000000000000000000000000000000") {
          adds.push(`+${event.chain.toUpperCase()}`);
        }
      }
    }
  }
  if (event.eventName === "ExecutionTableLoaded") {
    const entries = event.args.entries as unknown[] | undefined;
    if (entries) {
      for (let i = 0; i < entries.length; i++) {
        adds.push(`+${event.chain.toUpperCase()}`);
      }
    }
  }
  if (event.eventName === "ExecutionConsumed") {
    consumes.push(`-${event.chain.toUpperCase()}`);
  }
  return { adds, consumes };
}

export const EventCard: React.FC<Props> = ({
  event,
  selected,
  onClick,
  correlatedChain,
  stepNumber,
  isPlayed,
}) => {
  const [expanded, setExpanded] = useState(false);
  const chainColor = event.chain === "l1" ? COLORS.l1 : COLORS.l2;
  const chainBg = event.chain === "l1" ? COLORS.l1bg : COLORS.l2bg;
  const chainBorder = event.chain === "l1" ? COLORS.l1b : COLORS.l2b;
  const detail = eventDetail(event);
  const { adds, consumes } = tableChangeSummary(event);

  // Decode action hash for ExecutionConsumed events
  const decoded = useMemo(() => {
    if (event.eventName !== "ExecutionConsumed") return null;
    try {
      const actionArg = event.args.action as Record<string, unknown>;
      if (!actionArg) return null;
      const fields = actionFromEventArgs(actionArg);
      const storedHash = event.args.actionHash as string;
      return decodeActionHash(storedHash, fields);
    } catch {
      return null;
    }
  }, [event]);

  // Style matching index.html .si
  const opacity = selected ? 1 : isPlayed ? 0.65 : 0.25;

  return (
    <div
      onClick={onClick}
      style={{
        display: "flex",
        gap: 8,
        padding: "6px 8px",
        borderRadius: 6,
        border: `1px solid ${selected ? COLORS.acc : "transparent"}`,
        background: selected ? COLORS.s2 : COLORS.s1,
        marginBottom: 4,
        cursor: "pointer",
        transition: "all 0.15s",
        opacity,
        fontSize: "0.63rem",
        lineHeight: 1.45,
      }}
    >
      {/* Step number */}
      <div
        style={{
          width: 17,
          height: 17,
          borderRadius: "50%",
          background: selected ? COLORS.acc : COLORS.s3,
          color: selected ? "#fff" : COLORS.dim,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: "0.5rem",
          fontWeight: 700,
          flexShrink: 0,
          marginTop: 2,
        }}
      >
        {stepNumber}
      </div>

      {/* Chain badge */}
      <div
        style={{
          flexShrink: 0,
          padding: "1px 5px",
          borderRadius: 3,
          fontSize: "0.5rem",
          fontWeight: 700,
          marginTop: 2,
          background: chainBg,
          color: chainColor,
          border: `1px solid ${chainBorder}`,
        }}
      >
        {event.chain.toUpperCase()}
      </div>

      {/* Body */}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 700, color: eventColor(event.eventName) }}>
          {event.eventName}
        </div>
        {detail && (
          <div style={{ color: COLORS.dim, fontSize: "0.55rem" }}>
            {detail}
          </div>
        )}

        {/* Decoded action for ExecutionConsumed */}
        {decoded && (
          <div
            style={{
              marginTop: 3,
              padding: "3px 6px",
              borderRadius: 4,
              background: "rgba(0,0,0,0.25)",
              border: `1px solid ${decoded.verified ? "rgba(52,211,153,0.2)" : "rgba(239,68,68,0.3)"}`,
              fontSize: "0.5rem",
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: 4, marginBottom: 2 }}>
              <span style={{ color: decoded.verified ? COLORS.ok : COLORS.rm, fontWeight: 700 }}>
                {decoded.verified ? "hash verified" : "HASH MISMATCH"}
              </span>
              <span style={{ color: COLORS.dim }}>|</span>
              <span style={{ color: COLORS.add }}>
                {actionSummary(decoded.fields)}
              </span>
            </div>
            <div style={{ display: "grid", gridTemplateColumns: "80px 1fr", gap: "0px 6px", fontSize: "0.48rem" }}>
              {Object.entries(decoded.display).map(([k, v]) => (
                <React.Fragment key={k}>
                  <span style={{ color: COLORS.dim }}>{k}</span>
                  <span style={{ color: COLORS.tx, wordBreak: "break-all" }}>{v}</span>
                </React.Fragment>
              ))}
            </div>
          </div>
        )}

        {/* Table change summary */}
        {(adds.length > 0 || consumes.length > 0) && (
          <div style={{ marginTop: 2, fontSize: "0.52rem" }}>
            {adds.map((a, i) => (
              <span key={`a${i}`} style={{ color: COLORS.add, marginRight: 4 }}>
                {a}
              </span>
            ))}
            {consumes.map((c, i) => (
              <span key={`c${i}`} style={{ color: COLORS.rm, marginRight: 4 }}>
                {c} consumed
              </span>
            ))}
          </div>
        )}

        {/* Cross-chain correlation */}
        {correlatedChain && event.eventName === "ExecutionConsumed" && (
          <div style={{ fontSize: "0.52rem", color: COLORS.warn, marginTop: 2 }}>
            {"<->"} Matched on {correlatedChain.toUpperCase()} (same actionHash)
          </div>
        )}

        {/* Expand tx details */}
        {event.eventName === "ExecutionConsumed" && (
          <div style={{ marginTop: 3 }}>
            <button
              onClick={(e) => {
                e.stopPropagation();
                setExpanded(!expanded);
              }}
              style={{
                fontSize: "0.5rem",
                color: COLORS.acc,
                background: "none",
                border: "none",
                cursor: "pointer",
                padding: 0,
                fontFamily: "monospace",
              }}
            >
              {expanded ? "\u25BC Hide tx details" : "\u25B6 Show tx details"}
            </button>
            {expanded && (
              <TxDetails
                txHash={event.transactionHash}
                chain={event.chain}
              />
            )}
          </div>
        )}
      </div>
    </div>
  );
};
