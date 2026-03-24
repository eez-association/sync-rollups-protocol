import React from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { useTxIntrospection } from "../hooks/useTxIntrospection";
import { truncateAddress, truncateHex } from "../lib/actionFormatter";
import type { Chain } from "../types/visualization";

type Props = {
  txHash: `0x${string}`;
  chain: Chain;
};

export const TxDetails: React.FC<Props> = ({ txHash, chain }) => {
  const rpcUrl = useStore((s) =>
    chain === "l1" ? s.l1RpcUrl : s.l2RpcUrl,
  );
  const { data, loading } = useTxIntrospection(txHash, rpcUrl, chain);

  if (loading) {
    return (
      <div
        style={{
          fontSize: 10,
          color: COLORS.dim,
          padding: "8px 0",
        }}
      >
        Loading tx receipt...
      </div>
    );
  }

  if (!data) return null;

  return (
    <div
      style={{
        marginTop: 8,
        padding: 8,
        background: COLORS.s2,
        borderRadius: 6,
        border: `1px solid ${COLORS.brd}`,
      }}
    >
      <div style={{ fontSize: 9, color: COLORS.dim, marginBottom: 6 }}>
        <span>From: {truncateAddress(data.from)}</span>
        {data.to && <span> · To: {truncateAddress(data.to)}</span>}
        <span> · Gas: {data.gasUsed.toString()}</span>
      </div>

      <div
        style={{
          fontSize: 9,
          fontWeight: 700,
          color: COLORS.dim,
          textTransform: "uppercase",
          marginBottom: 4,
        }}
      >
        Decoded Logs ({data.logs.length})
      </div>

      {data.logs.map((log, i) => (
        <div
          key={i}
          style={{
            padding: "4px 8px",
            marginBottom: 3,
            background: COLORS.s3,
            borderRadius: 4,
            fontSize: 10,
          }}
        >
          <div style={{ display: "flex", gap: 8 }}>
            <span style={{ color: COLORS.acc, fontWeight: 700 }}>
              {log.eventName}
            </span>
            <span style={{ color: COLORS.dim }}>
              @{truncateAddress(log.address)}
            </span>
          </div>
          <div style={{ color: COLORS.dim, marginTop: 2 }}>
            {Object.entries(log.args).map(([key, val]) => (
              <div key={key} style={{ marginLeft: 8 }}>
                <span style={{ color: COLORS.dim }}>{key}:</span>{" "}
                <span style={{ color: COLORS.tx }}>
                  {formatArg(val)}
                </span>
              </div>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
};

function formatArg(val: unknown): string {
  if (typeof val === "bigint") return val.toString();
  if (typeof val === "string") {
    if (val.startsWith("0x") && val.length > 20) return truncateHex(val);
    return val;
  }
  if (typeof val === "boolean") return val ? "true" : "false";
  if (Array.isArray(val)) return `[${val.map(formatArg).join(", ")}]`;
  if (val && typeof val === "object") {
    return JSON.stringify(val, (_, v) =>
      typeof v === "bigint" ? v.toString() : v,
    );
  }
  return String(val);
}
