import React, { useState } from "react";
import { COLORS } from "../theme";

type Props = {
  currentBlockNumber: number | null;
  loading: boolean;
  onPrevBlock: () => void;
  onNextBlock: () => void;
  onLatestBlock: () => void;
  onGoToBlock: (n: number) => void;
  onTraceTx: (hash: string) => void;
};

export const TraceBlockNav: React.FC<Props> = ({
  currentBlockNumber,
  loading,
  onPrevBlock,
  onNextBlock,
  onLatestBlock,
  onGoToBlock,
  onTraceTx,
}) => {
  const [txInput, setTxInput] = useState("");
  const [blockInput, setBlockInput] = useState("");

  const handleTxSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (txInput.trim()) onTraceTx(txInput.trim());
  };

  const handleBlockSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    const n = parseInt(blockInput);
    if (!isNaN(n)) onGoToBlock(n);
  };

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "8px 16px",
        borderBottom: `1px solid ${COLORS.brd}`,
        fontSize: "0.7rem",
        flexWrap: "wrap",
      }}
    >
      {/* Block navigation */}
      <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
        <NavButton onClick={onPrevBlock} disabled={loading || !currentBlockNumber}>
          &larr;
        </NavButton>
        <div
          style={{
            padding: "4px 12px",
            background: COLORS.s2,
            border: `1px solid ${COLORS.brd}`,
            borderRadius: 4,
            minWidth: 100,
            textAlign: "center",
            fontWeight: 700,
          }}
        >
          {loading ? (
            <span style={{ color: COLORS.dim }}>loading...</span>
          ) : currentBlockNumber !== null ? (
            <>
              <span style={{ color: COLORS.l1 }}>L1</span>{" "}
              <span>Block #{currentBlockNumber}</span>
            </>
          ) : (
            <span style={{ color: COLORS.dim }}>—</span>
          )}
        </div>
        <NavButton onClick={onNextBlock} disabled={loading || !currentBlockNumber}>
          &rarr;
        </NavButton>
        <NavButton onClick={onLatestBlock} disabled={loading}>
          Latest
        </NavButton>
      </div>

      {/* Block number input */}
      <form onSubmit={handleBlockSubmit} style={{ display: "flex", gap: 4 }}>
        <input
          value={blockInput}
          onChange={(e) => setBlockInput(e.target.value)}
          placeholder="Block #"
          style={{
            width: 80,
            padding: "4px 6px",
            borderRadius: 4,
            border: `1px solid ${COLORS.brd}`,
            background: COLORS.s2,
            color: COLORS.tx,
            fontSize: "0.65rem",
            fontFamily: "inherit",
            outline: "none",
          }}
        />
        <NavButton type="submit" disabled={loading || !blockInput.trim()}>
          Go
        </NavButton>
      </form>

      <div style={{ color: COLORS.dim }}>|</div>

      {/* Tx hash input */}
      <form onSubmit={handleTxSubmit} style={{ display: "flex", gap: 4, flex: 1, minWidth: 200 }}>
        <input
          value={txInput}
          onChange={(e) => setTxInput(e.target.value)}
          placeholder="Paste tx hash 0x..."
          style={{
            flex: 1,
            padding: "4px 6px",
            borderRadius: 4,
            border: `1px solid ${COLORS.brd}`,
            background: COLORS.s2,
            color: COLORS.tx,
            fontSize: "0.65rem",
            fontFamily: "inherit",
            outline: "none",
          }}
        />
        <NavButton type="submit" disabled={loading || !txInput.trim()}>
          Trace
        </NavButton>
      </form>
    </div>
  );
};

const NavButton: React.FC<
  React.ButtonHTMLAttributes<HTMLButtonElement> & { children: React.ReactNode }
> = ({ children, disabled, ...rest }) => (
  <button
    disabled={disabled}
    style={{
      padding: "4px 10px",
      borderRadius: 4,
      border: `1px solid ${COLORS.brd}`,
      background: disabled ? COLORS.s3 : COLORS.s2,
      color: disabled ? COLORS.dim : COLORS.tx,
      fontSize: "0.65rem",
      fontWeight: 600,
      cursor: disabled ? "default" : "pointer",
      fontFamily: "inherit",
      opacity: disabled ? 0.5 : 1,
      transition: "all 0.15s",
    }}
    {...rest}
  >
    {children}
  </button>
);
