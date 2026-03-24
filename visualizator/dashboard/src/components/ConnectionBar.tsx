import React, { useState, useEffect } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { initManagerNodes, resetDiscovery } from "../lib/autoDiscovery";

type Defaults = {
  l1RpcUrl: string;
  l2RpcUrl: string;
  l1ContractAddress: string;
  l2ContractAddress: string;
};

async function loadDefaults(): Promise<Defaults | null> {
  try {
    const res = await fetch("/config.json");
    if (res.ok) return res.json();
  } catch { /* ignore */ }
  return null;
}

export const ConnectionBar: React.FC = () => {
  const l1RpcUrl = useStore((s) => s.l1RpcUrl);
  const l2RpcUrl = useStore((s) => s.l2RpcUrl);
  const l1ContractAddress = useStore((s) => s.l1ContractAddress);
  const l2ContractAddress = useStore((s) => s.l2ContractAddress);
  const connected = useStore((s) => s.connected);
  const l1Connected = useStore((s) => s.l1Connected);
  const l2Connected = useStore((s) => s.l2Connected);
  const setL1RpcUrl = useStore((s) => s.setL1RpcUrl);
  const setL2RpcUrl = useStore((s) => s.setL2RpcUrl);
  const setL1ContractAddress = useStore((s) => s.setL1ContractAddress);
  const setL2ContractAddress = useStore((s) => s.setL2ContractAddress);
  const setConnected = useStore((s) => s.setConnected);
  const addNodes = useStore((s) => s.addNodes);
  const addKnownAddresses = useStore((s) => s.addKnownAddresses);
  const clearAll = useStore((s) => s.clearAll);

  const [localL1Rpc, setLocalL1Rpc] = useState(l1RpcUrl);
  const [localL2Rpc, setLocalL2Rpc] = useState(l2RpcUrl);
  const [localL1Addr, setLocalL1Addr] = useState(l1ContractAddress);
  const [localL2Addr, setLocalL2Addr] = useState(l2ContractAddress);

  useEffect(() => {
    loadDefaults().then((defaults) => {
      if (!defaults) return;
      if (defaults.l1RpcUrl) { setLocalL1Rpc(defaults.l1RpcUrl); setL1RpcUrl(defaults.l1RpcUrl); }
      if (defaults.l2RpcUrl) { setLocalL2Rpc(defaults.l2RpcUrl); setL2RpcUrl(defaults.l2RpcUrl); }
      if (defaults.l1ContractAddress) { setLocalL1Addr(defaults.l1ContractAddress); setL1ContractAddress(defaults.l1ContractAddress); }
      if (defaults.l2ContractAddress) { setLocalL2Addr(defaults.l2ContractAddress); setL2ContractAddress(defaults.l2ContractAddress); }
    });
  }, []);

  const handleConnect = () => {
    if (connected) {
      clearAll();
      resetDiscovery();
      setConnected(false, false);
      return;
    }
    setL1RpcUrl(localL1Rpc);
    setL2RpcUrl(localL2Rpc);
    setL1ContractAddress(localL1Addr);
    setL2ContractAddress(localL2Addr);

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
        label="L1 Contract"
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
        label="L2 Contract"
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
