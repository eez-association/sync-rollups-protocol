import React, { useState, useCallback } from "react";
import { COLORS } from "./theme";
import { useStore } from "./store";
import { useEventStream } from "./hooks/useEventStream";
import { useDerivedState } from "./hooks/useDerivedState";
import { ConnectionBar } from "./components/ConnectionBar";
import { ArchitectureDiagram } from "./components/ArchitectureDiagram";
import { ExecutionTables } from "./components/ExecutionTables";
import { ContractState } from "./components/ContractState";
import { EventTimeline } from "./components/EventTimeline";
import { EventInfoBanner } from "./components/EventInfoBanner";
import { BundleDetail } from "./components/BundleDetail";
import type { TransactionBundle } from "./types/visualization";

export const App: React.FC = () => {
  useEventStream();
  const connected = useStore((s) => s.connected);
  const changedKeys = useStore((s) => s.changedKeys);
  const { l1Table, l2Table, contractState, activeNodes, activeEdges } =
    useDerivedState();
  const [selectedBundle, setSelectedBundle] = useState<TransactionBundle | null>(null);

  const handleSelectBundle = useCallback((bundle: TransactionBundle) => {
    setSelectedBundle(bundle);
  }, []);

  const handleCloseBundle = useCallback(() => {
    setSelectedBundle(null);
  }, []);

  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        height: "100vh",
        background: COLORS.bg,
        color: COLORS.tx,
        fontFamily: "'SF Mono', 'JetBrains Mono', 'Fira Code', monospace",
      }}
    >
      {/* Header */}
      <header
        style={{
          textAlign: "center",
          padding: "12px 16px 6px",
          borderBottom: `1px solid ${COLORS.brd}`,
        }}
      >
        <h1 style={{ fontSize: "1.2rem", fontWeight: 700 }}>
          Cross-Chain Execution Visualizer
        </h1>
        <p style={{ color: COLORS.dim, fontSize: "0.65rem", marginTop: 2 }}>
          Execution table evolution across L1 & L2 — live event stream
        </p>
      </header>

      <ConnectionBar />

      <div style={{ display: "flex", flex: 1, overflow: "hidden" }}>
        {/* Main content */}
        <div
          style={{
            flex: 1,
            overflow: "auto",
            padding: "0 12px 24px",
          }}
        >
          {!connected ? (
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                flex: 1,
                height: "100%",
                color: COLORS.dim,
                fontSize: "0.75rem",
              }}
            >
              Enter RPC URLs and contract addresses, then click Connect
            </div>
          ) : (
            <>
              <EventInfoBanner />
              <div style={{ marginBottom: 10 }}>
                <ArchitectureDiagram
                  activeNodes={activeNodes}
                  activeEdges={activeEdges}
                />
              </div>
              <div style={{ marginBottom: 10 }}>
                <ExecutionTables l1Entries={l1Table} l2Entries={l2Table} />
              </div>
              <ContractState
                contractState={contractState}
                changedKeys={changedKeys}
              />
            </>
          )}
        </div>

        {/* Event timeline sidebar */}
        {connected && (
          <div style={{ width: 360, flexShrink: 0 }}>
            <EventTimeline onSelectBundle={handleSelectBundle} />
          </div>
        )}
      </div>

      {/* Bundle detail modal */}
      {selectedBundle && (
        <BundleDetail bundle={selectedBundle} onClose={handleCloseBundle} />
      )}
    </div>
  );
};
