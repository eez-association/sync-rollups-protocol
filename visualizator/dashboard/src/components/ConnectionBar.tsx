import React, { useState, useEffect } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { initManagerNodes, resetDiscovery } from "../lib/autoDiscovery";
import { setExplorerUrls } from "../lib/traceDecoder";

export const ConnectionBar: React.FC = () => {
  const l1RpcUrl = useStore((s) => s.l1RpcUrl);
  const l2RpcUrl = useStore((s) => s.l2RpcUrl);
  const rollupsAddress = useStore((s) => s.rollupsAddress);
  const managerL2Address = useStore((s) => s.managerL2Address);
  const l1ExplorerUrl = useStore((s) => s.l1ExplorerUrl);
  const l2ExplorerUrl = useStore((s) => s.l2ExplorerUrl);
  const connected = useStore((s) => s.connected);
  const l1Connected = useStore((s) => s.l1Connected);
  const l2Connected = useStore((s) => s.l2Connected);
  const setConnected = useStore((s) => s.setConnected);
  const addNodes = useStore((s) => s.addNodes);
  const addKnownAddresses = useStore((s) => s.addKnownAddresses);
  const clearAll = useStore((s) => s.clearAll);

  const [localL1Rpc, setLocalL1Rpc] = useState(l1RpcUrl);
  const [localL2Rpc, setLocalL2Rpc] = useState(l2RpcUrl);
  const [localL1Addr, setLocalL1Addr] = useState(rollupsAddress);
  const [localL2Addr, setLocalL2Addr] = useState(managerL2Address);

  // Sync local fields when store changes (e.g. after config.json loads in App)
  useEffect(() => { setLocalL1Rpc(l1RpcUrl); }, [l1RpcUrl]);
  useEffect(() => { setLocalL2Rpc(l2RpcUrl); }, [l2RpcUrl]);
  useEffect(() => { setLocalL1Addr(rollupsAddress); }, [rollupsAddress]);
  useEffect(() => { setLocalL2Addr(managerL2Address); }, [managerL2Address]);

  const handleConnect = () => {
    if (connected) {
      clearAll();
      resetDiscovery();
      setConnected(false, false);
      return;
    }
    const s = useStore.getState();
    s.setL1RpcUrl(localL1Rpc);
    s.setL2RpcUrl(localL2Rpc);
    s.setRollupsAddress(localL1Addr);
    s.setManagerL2Address(localL2Addr);
    setExplorerUrls(s.l1ExplorerUrl, s.l2ExplorerUrl);

    const result = initManagerNodes(localL1Addr, localL2Addr);
    if (result.newNodes.length > 0) addNodes(result.newNodes);
    if (result.addressInfos.length > 0) addKnownAddresses(result.addressInfos);

    setConnected(!!localL1Rpc, !!localL2Rpc);
  };

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        gap: 8,
        padding: "6px 16px",
        borderBottom: `1px solid ${COLORS.brd}`,
        flexWrap: "wrap",
        fontSize: "0.65rem",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
        <StatusDot color={l1Connected ? COLORS.ok : COLORS.dim} />
        <Input
          label="L1 RPC"
          value={localL1Rpc}
          onChange={setLocalL1Rpc}
          disabled={connected}
          width={140}
        />
      </div>

      <Input
        label="Rollups (L1)"
        value={localL1Addr}
        onChange={setLocalL1Addr}
        disabled={connected}
        width={280}
        placeholder="0x..."
      />

      <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
        <StatusDot color={l2Connected ? COLORS.ok : COLORS.dim} />
        <Input
          label="L2 RPC"
          value={localL2Rpc}
          onChange={setLocalL2Rpc}
          disabled={connected}
          width={140}
        />
      </div>

      <Input
        label="CrossChainManagerL2"
        value={localL2Addr}
        onChange={setLocalL2Addr}
        disabled={connected}
        width={280}
        placeholder="0x..."
      />

      <button
        onClick={handleConnect}
        style={{
          padding: "4px 12px",
          borderRadius: 5,
          border: `1px solid ${connected ? COLORS.rm : COLORS.acc}`,
          background: connected
            ? "rgba(239,68,68,0.1)"
            : COLORS.acc,
          color: connected ? COLORS.rm : "#fff",
          fontSize: "0.65rem",
          fontWeight: 700,
          cursor: "pointer",
          fontFamily: "inherit",
          transition: "all 0.15s",
        }}
      >
        {connected ? "Disconnect" : "Connect"}
      </button>

      {connected && (l1ExplorerUrl || l2ExplorerUrl) && (
        <div style={{ display: "flex", gap: 4 }}>
          {l1ExplorerUrl && (
            <ExplorerLink url={l1ExplorerUrl} label="L1 Explorer" color={COLORS.l1} />
          )}
          {l2ExplorerUrl && (
            <ExplorerLink url={l2ExplorerUrl} label="L2 Explorer" color={COLORS.l2} />
          )}
        </div>
      )}
    </div>
  );
};

const StatusDot: React.FC<{ color: string }> = ({ color }) => (
  <div
    style={{
      width: 6,
      height: 6,
      borderRadius: "50%",
      background: color,
      boxShadow: `0 0 4px ${color}`,
      flexShrink: 0,
    }}
  />
);

const Input: React.FC<{
  label: string;
  value: string;
  onChange: (v: string) => void;
  disabled: boolean;
  width: number;
  placeholder?: string;
}> = ({ label, value, onChange, disabled, width, placeholder }) => (
  <div style={{ display: "flex", flexDirection: "column", gap: 1 }}>
    <span
      style={{
        fontSize: "0.45rem",
        color: COLORS.dim,
        textTransform: "uppercase",
        letterSpacing: "0.05em",
      }}
    >
      {label}
    </span>
    <input
      value={value}
      onChange={(e) => onChange(e.target.value)}
      disabled={disabled}
      placeholder={placeholder}
      style={{
        width,
        padding: "3px 6px",
        borderRadius: 4,
        border: `1px solid ${COLORS.brd}`,
        background: disabled ? COLORS.s3 : COLORS.s2,
        color: COLORS.tx,
        fontSize: "0.6rem",
        fontFamily: "inherit",
        outline: "none",
      }}
    />
  </div>
);

const ExplorerLink: React.FC<{ url: string; label: string; color: string }> = ({
  url,
  label,
  color,
}) => (
  <a
    href={url}
    target="_blank"
    rel="noopener noreferrer"
    style={{
      padding: "3px 8px",
      borderRadius: 4,
      border: `1px solid ${color}`,
      background: `${color}11`,
      color,
      fontSize: "0.55rem",
      fontWeight: 700,
      fontFamily: "inherit",
      textDecoration: "none",
      transition: "all 0.15s",
    }}
  >
    {label}
  </a>
);
