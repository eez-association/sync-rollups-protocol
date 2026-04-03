import React from "react";
import { COLORS } from "../theme";
import type { TraceEvent } from "../types/trace";

type Props = {
  events: TraceEvent[];
};

export const TraceEventPanel: React.FC<Props> = ({ events }) => {
  if (events.length === 0) return null;

  return (
    <div
      style={{
        background: COLORS.s1,
        border: `1px solid ${COLORS.brd}`,
        borderRadius: 6,
        padding: "8px 12px",
        fontSize: "0.65rem",
      }}
    >
      <div
        style={{
          fontWeight: 700,
          fontSize: "0.6rem",
          color: COLORS.dim,
          textTransform: "uppercase",
          letterSpacing: "0.05em",
          marginBottom: 6,
        }}
      >
        Events ({events.length})
      </div>
      {events.map((ev, i) => (
        <div
          key={i}
          style={{
            display: "flex",
            gap: 8,
            padding: "2px 0",
            borderBottom: i < events.length - 1 ? `1px solid ${COLORS.s3}` : "none",
          }}
        >
          <span
            style={{
              fontWeight: 700,
              fontSize: "0.55rem",
              color: ev.chain === "l1" ? COLORS.l1 : COLORS.l2,
              width: 20,
              flexShrink: 0,
            }}
          >
            {ev.chain.toUpperCase()}
          </span>
          <span style={{ fontWeight: 700 }}>{ev.name || "(unknown)"}</span>
          {ev.params.length > 0 && (
            <span style={{ color: COLORS.dim }}>
              (
              {ev.params.map((p, j) => (
                <span key={j}>
                  {j > 0 && ", "}
                  <span style={{ color: COLORS.dim }}>{p.name}: </span>
                  <span style={{ color: COLORS.tx }}>
                    {p.value.length > 40 ? p.value.slice(0, 37) + "..." : p.value}
                  </span>
                </span>
              ))}
              )
            </span>
          )}
        </div>
      ))}
    </div>
  );
};
