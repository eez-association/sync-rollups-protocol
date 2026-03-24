import React, { useRef, useEffect, useCallback, useMemo, useState } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { EventCard } from "./EventCard";
import { BundleList } from "./BundleList";
import { findCorrelatedPairs } from "../lib/crossChainCorrelation";
import type { TransactionBundle } from "../types/visualization";

type ViewMode = "events" | "bundles";

type Props = {
  onSelectBundle?: (bundle: TransactionBundle) => void;
};

export const EventTimeline: React.FC<Props> = ({ onSelectBundle }) => {
  const events = useStore((s) => s.events);
  const selectedEventId = useStore((s) => s.selectedEventId);
  const setSelectedEventId = useStore((s) => s.setSelectedEventId);
  const scrollRef = useRef<HTMLDivElement>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("events");
  const [selectedBundleId, setSelectedBundleId] = useState<string | null>(null);

  const correlationMap = useMemo(() => {
    const map = new Map<string, "l1" | "l2">();
    const pairs = findCorrelatedPairs(events);
    for (const pair of pairs) {
      map.set(pair.l1Event.id, "l2");
      map.set(pair.l2Event.id, "l1");
    }
    return map;
  }, [events]);

  const isLive = selectedEventId === null;
  const selectedIdx = isLive
    ? events.length - 1
    : events.findIndex((e) => e.id === selectedEventId);

  // Auto-scroll to bottom when live
  useEffect(() => {
    if (isLive && scrollRef.current && viewMode === "events") {
      scrollRef.current.scrollTop = scrollRef.current.scrollHeight;
    }
  }, [events.length, isLive, viewMode]);

  // Keyboard navigation
  const handleKeyDown = useCallback(
    (e: KeyboardEvent) => {
      if (viewMode !== "events") return;
      if (events.length === 0) return;
      if (e.key === "ArrowDown" || e.key === "ArrowRight") {
        e.preventDefault();
        if (selectedEventId === null) return;
        const idx = events.findIndex((ev) => ev.id === selectedEventId);
        if (idx < events.length - 1) {
          setSelectedEventId(events[idx + 1].id);
        } else {
          setSelectedEventId(null);
        }
      } else if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
        e.preventDefault();
        if (selectedEventId === null) {
          setSelectedEventId(events[events.length - 1].id);
        } else {
          const idx = events.findIndex((ev) => ev.id === selectedEventId);
          if (idx > 0) {
            setSelectedEventId(events[idx - 1].id);
          }
        }
      } else if (e.key === "Escape") {
        e.preventDefault();
        setSelectedEventId(null);
      }
    },
    [events, selectedEventId, setSelectedEventId, viewMode],
  );

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [handleKeyDown]);

  const handleSelectBundle = useCallback(
    (bundle: TransactionBundle) => {
      setSelectedBundleId(bundle.id);
      onSelectBundle?.(bundle);
    },
    [onSelectBundle],
  );

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100%",
        background: COLORS.s1,
        borderLeft: `1px solid ${COLORS.brd}`,
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "8px 12px",
          borderBottom: `1px solid ${COLORS.brd}`,
        }}
      >
        {/* View toggle */}
        <div style={{ display: "flex", gap: 0, borderRadius: 4, overflow: "hidden", border: `1px solid ${COLORS.brd}` }}>
          <ToggleButton
            active={viewMode === "events"}
            onClick={() => setViewMode("events")}
            label={`Events (${events.length})`}
          />
          <ToggleButton
            active={viewMode === "bundles"}
            onClick={() => setViewMode("bundles")}
            label="Bundles"
          />
        </div>

        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          {viewMode === "events" && !isLive && (
            <button
              onClick={() => setSelectedEventId(null)}
              style={{
                fontSize: "0.55rem",
                padding: "2px 8px",
                borderRadius: 4,
                border: `1px solid ${COLORS.ok}`,
                background: "rgba(52,211,153,0.1)",
                color: COLORS.ok,
                cursor: "pointer",
                fontFamily: "monospace",
                fontWeight: 700,
              }}
            >
              Latest
            </button>
          )}
          {viewMode === "events" && isLive && (
            <span
              style={{
                fontSize: "0.55rem",
                padding: "2px 8px",
                borderRadius: 4,
                background: "rgba(52,211,153,0.1)",
                color: COLORS.ok,
                fontWeight: 700,
              }}
            >
              LIVE
            </span>
          )}
        </div>
      </div>

      {/* Content */}
      <div
        ref={scrollRef}
        style={{
          flex: 1,
          overflow: "auto",
          padding: viewMode === "events" ? 6 : 0,
        }}
      >
        {viewMode === "events" ? (
          events.length === 0 ? (
            <div
              style={{
                textAlign: "center",
                color: COLORS.dim,
                fontSize: "0.55rem",
                padding: 16,
                opacity: 0.4,
              }}
            >
              Waiting for events...
            </div>
          ) : (
            events.map((event, i) => (
              <EventCard
                key={event.id}
                event={event}
                stepNumber={i + 1}
                selected={
                  isLive
                    ? event === events[events.length - 1]
                    : event.id === selectedEventId
                }
                isPlayed={i < selectedIdx}
                onClick={() => setSelectedEventId(event.id)}
                correlatedChain={correlationMap.get(event.id)}
              />
            ))
          )
        ) : (
          <BundleList
            onSelectBundle={handleSelectBundle}
            selectedBundleId={selectedBundleId}
          />
        )}
      </div>
    </div>
  );
};

const ToggleButton: React.FC<{
  active: boolean;
  onClick: () => void;
  label: string;
}> = ({ active, onClick, label }) => (
  <button
    onClick={onClick}
    style={{
      fontSize: "0.5rem",
      fontWeight: 700,
      padding: "3px 8px",
      border: "none",
      background: active ? COLORS.acc : "transparent",
      color: active ? "#fff" : COLORS.dim,
      cursor: "pointer",
      fontFamily: "monospace",
      textTransform: "uppercase",
      letterSpacing: "0.04em",
      transition: "all 0.15s",
    }}
  >
    {label}
  </button>
);
