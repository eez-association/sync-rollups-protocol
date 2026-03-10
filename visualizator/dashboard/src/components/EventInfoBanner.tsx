import React from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";

export const EventInfoBanner: React.FC = () => {
  const events = useStore((s) => s.events);
  const selectedEventId = useStore((s) => s.selectedEventId);

  const isLive = selectedEventId === null;
  const selectedIdx = isLive
    ? events.length - 1
    : events.findIndex((e) => e.id === selectedEventId);

  if (events.length === 0) return null;

  const event = events[selectedIdx];
  if (!event) return null;

  const chainColor = event.chain === "l1" ? COLORS.l1 : COLORS.l2;

  return (
    <div
      style={{
        textAlign: "center",
        padding: "8px 12px",
        marginBottom: 8,
      }}
    >
      <h2 style={{ fontSize: "0.95rem", marginBottom: 2, color: COLORS.tx }}>
        Step {selectedIdx + 1} of {events.length}
        {isLive && (
          <span
            style={{
              fontSize: "0.6rem",
              marginLeft: 8,
              padding: "1px 6px",
              borderRadius: 3,
              background: "rgba(52,211,153,0.1)",
              color: COLORS.ok,
              fontWeight: 700,
            }}
          >
            LIVE
          </span>
        )}
      </h2>
      <div style={{ color: COLORS.add, fontSize: "0.8rem" }}>
        <span
          style={{
            display: "inline-block",
            padding: "0 4px",
            color: chainColor,
            fontWeight: 700,
          }}
        >
          [{event.chain.toUpperCase()}]
        </span>{" "}
        {event.eventName}
      </div>
      <div style={{ color: COLORS.dim, fontSize: "0.6rem", marginTop: 2 }}>
        Block {event.blockNumber.toString()} · Tx {event.transactionHash.slice(0, 10)}...
        {" · "}Use arrow keys to navigate
      </div>
    </div>
  );
};
