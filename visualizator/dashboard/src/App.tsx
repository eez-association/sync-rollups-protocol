import React, { useState, useCallback, useEffect } from "react";
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
import { TraceExplorer } from "./components/TraceExplorer";
import { setExplorerUrls } from "./lib/traceDecoder";
import type { TransactionBundle } from "./types/visualization";

async function loadDefaults() {
  try {
    const res = await fetch("/config.json");
    if (res.ok) return res.json();
  } catch { /* ignore */ }
  return null;
}

export const App: React.FC = () => {
  useEventStream();
  const connected = useStore((s) => s.connected);
  const changedKeys = useStore((s) => s.changedKeys);
  const dashboardMode = useStore((s) => s.dashboardMode);
  const setDashboardMode = useStore((s) => s.setDashboardMode);

  // Load config defaults on mount — single source of truth for all modes
  useEffect(() => {
    loadDefaults().then((defaults) => {
      if (!defaults) return;
      const s = useStore.getState();
      if (defaults.l1RpcUrl) s.setL1RpcUrl(defaults.l1RpcUrl);
      if (defaults.l2RpcUrl) s.setL2RpcUrl(defaults.l2RpcUrl);
      if (defaults.rollupsAddress) s.setRollupsAddress(defaults.rollupsAddress);
      if (defaults.managerL2Address) s.setManagerL2Address(defaults.managerL2Address);
      if (defaults.l1ExplorerUrl) s.setL1ExplorerUrl(defaults.l1ExplorerUrl);
      if (defaults.l2ExplorerUrl) s.setL2ExplorerUrl(defaults.l2ExplorerUrl);
      setExplorerUrls(defaults.l1ExplorerUrl || "", defaults.l2ExplorerUrl || "");
    });
  }, []);
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
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: "8px 16px",
          borderBottom: `1px solid ${COLORS.brd}`,
        }}
      >
        <div>
          <h1 style={{ fontSize: "1.1rem", fontWeight: 700, margin: 0 }}>
            Cross-Chain Execution Visualizer
          </h1>
          <p style={{ color: COLORS.dim, fontSize: "0.6rem", margin: "2px 0 0" }}>
            {dashboardMode === "live" ? "Live event stream" : dashboardMode === "trace" ? "Trace explorer" : "Settings"}
          </p>
        </div>
        <div style={{ display: "flex", gap: 0, borderRadius: 5, overflow: "hidden", border: `1px solid ${COLORS.brd}` }}>
          <ModeButton active={dashboardMode === "trace"} onClick={() => setDashboardMode("trace")}>
            Block Explorer
          </ModeButton>
          <ModeButton active={dashboardMode === "live"} onClick={() => setDashboardMode("live")}>
            Live Events
          </ModeButton>
          <ModeButton active={dashboardMode === "settings"} onClick={() => setDashboardMode("settings")}>
            Settings
          </ModeButton>
        </div>
      </header>

      {dashboardMode === "trace" ? (
        <TraceExplorer />
      ) : dashboardMode === "settings" ? (
        <ConnectionBar />
      ) : (
        <>
          <ConnectionBar />
          <div style={{ display: "flex", flex: 1, overflow: "hidden" }}>
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
                  Click Connect to start watching events
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

            {connected && (
              <div style={{ width: 360, flexShrink: 0 }}>
                <EventTimeline onSelectBundle={handleSelectBundle} />
              </div>
            )}
          </div>

          {selectedBundle && (
            <BundleDetail bundle={selectedBundle} onClose={handleCloseBundle} />
          )}
        </>
      )}
    </div>
  );
};

const ModeButton: React.FC<{
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}> = ({ active, onClick, children }) => (
  <button
    onClick={onClick}
    style={{
      padding: "4px 14px",
      border: "none",
      background: active ? COLORS.acc : COLORS.s2,
      color: active ? "#fff" : COLORS.dim,
      fontSize: "0.6rem",
      fontWeight: 700,
      cursor: "pointer",
      fontFamily: "inherit",
      transition: "all 0.15s",
    }}
  >
    {children}
  </button>
);
