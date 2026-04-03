import React, { useEffect, useRef, useMemo } from "react";
import { COLORS } from "../theme";
import { useStore } from "../store";
import { useTraceExplorer } from "../hooks/useTraceExplorer";
import { TraceBlockNav } from "./TraceBlockNav";
import { TraceDiagram } from "./TraceDiagram";
import { ExecutionTables } from "./ExecutionTables";
import { TraceCallTree } from "./TraceCallTree";
import { processEventForTables } from "../lib/eventProcessor";
import type { TableEntry } from "../types/visualization";
import type { BlockInfoResponse, TraceResponse } from "../types/trace";

export const TraceExplorer: React.FC = () => {
  const currentBlock = useStore((s) => s.currentBlock);
  const blockEvents = useStore((s) => s.blockEvents);
  const blockTraces = useStore((s) => s.blockTraces);
  const traceLoading = useStore((s) => s.traceLoading);
  const traceError = useStore((s) => s.traceError);
  const expandedNodes = useStore((s) => s.expandedNodes);
  const toggleNodeExpanded = useStore((s) => s.toggleNodeExpanded);

  const l1RpcUrl = useStore((s) => s.l1RpcUrl);
  const { traceByTxHash, loadBlock, loadLatestBlock } = useTraceExplorer();

  // Auto-load latest block once config is ready (RPC URL != default)
  const loaded = useRef(false);
  useEffect(() => {
    if (!loaded.current && l1RpcUrl && !l1RpcUrl.includes("localhost")) {
      loaded.current = true;
      loadLatestBlock();
    }
  }, [l1RpcUrl, loadLatestBlock]);

  // Process events into table entries
  const { l1Table, l2Table } = useMemo(() => {
    const l1: TableEntry[] = [];
    const l2: TableEntry[] = [];

    for (const event of blockEvents) {
      const result = processEventForTables(event);
      l1.push(...result.l1Adds);
      l2.push(...result.l2Adds);
      for (const consume of result.l1Consumes) {
        const entry = l1.find((e) => e.fullActionHash?.toLowerCase() === consume.actionHash.toLowerCase());
        if (entry) entry.actionDetail = consume.actionDetail;
      }
      for (const consume of result.l2Consumes) {
        const entry = l2.find((e) => e.fullActionHash?.toLowerCase() === consume.actionHash.toLowerCase());
        if (entry) entry.actionDetail = consume.actionDetail;
      }
    }

    return { l1Table: l1, l2Table: l2 };
  }, [blockEvents]);

  const blockNum = currentBlock?.blockNumber ?? null;

  return (
    <div style={{ display: "flex", flexDirection: "column", height: "100%" }}>
      <TraceBlockNav
        currentBlockNumber={blockNum}
        loading={traceLoading}
        onPrevBlock={() => blockNum && loadBlock(blockNum - 1)}
        onNextBlock={() => blockNum && loadBlock(blockNum + 1)}
        onLatestBlock={loadLatestBlock}
        onGoToBlock={loadBlock}
        onTraceTx={traceByTxHash}
      />

      <div style={{ flex: 1, overflow: "auto", padding: "12px 16px" }}>
        {/* Error */}
        {traceError && (
          <div
            style={{
              padding: "8px 12px",
              background: "rgba(239,68,68,0.1)",
              border: `1px solid ${COLORS.rm}`,
              borderRadius: 6,
              color: COLORS.rm,
              fontSize: "0.7rem",
              marginBottom: 12,
            }}
          >
            {traceError}
          </div>
        )}

        {/* Loading */}
        {traceLoading && (
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              padding: 40,
              color: COLORS.dim,
              fontSize: "0.75rem",
            }}
          >
            Loading block...
          </div>
        )}

        {/* Block content */}
        {currentBlock && !traceLoading && (
          <>
            {/* Block header */}
            <BlockHeader block={currentBlock} />

            {/* Cross-chain flow diagram — prominent first element */}
            {blockTraces.length > 0 && (
              <TraceDiagram traces={blockTraces} />
            )}

            {/* Execution Tables — L1 postBatch + L2 loadExecutionTable */}
            {(l1Table.length > 0 || l2Table.length > 0) && (
              <div style={{ marginBottom: 16 }}>
                <ExecutionTables l1Entries={l1Table} l2Entries={l2Table} />
              </div>
            )}

            {/* Cross-chain call trees (detailed) */}
            {blockTraces.length > 0 && (
              <div style={{ marginBottom: 16 }}>
                {blockTraces.map((trace, idx) => (
                  <TxTraceSection
                    key={trace.txHash}
                    trace={trace}
                    index={idx}
                    expandedNodes={expandedNodes}
                    onToggleExpand={toggleNodeExpanded}
                  />
                ))}
              </div>
            )}

            {/* Event list */}
            {blockEvents.length > 0 && (
              <EventList events={blockEvents} />
            )}

            {/* Empty block */}
            {blockEvents.length === 0 && blockTraces.length === 0 && (
              <div style={{ color: COLORS.dim, fontSize: "0.7rem", textAlign: "center", padding: 20 }}>
                No contract events in this block
              </div>
            )}
          </>
        )}

        {/* Initial state */}
        {!currentBlock && !traceLoading && !traceError && (
          <div
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              height: "50%",
              color: COLORS.dim,
              fontSize: "0.75rem",
            }}
          >
            Navigate to a block or paste a tx hash
          </div>
        )}
      </div>
    </div>
  );
};

// ── Block header ──

const BlockHeader: React.FC<{ block: BlockInfoResponse }> = ({ block }) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      gap: 8,
      marginBottom: 12,
      padding: "6px 10px",
      background: COLORS.s1,
      border: `1px solid ${COLORS.brd}`,
      borderRadius: 6,
      fontSize: "0.65rem",
    }}
  >
    <span style={{ fontWeight: 700 }}>
      <span style={{ color: COLORS.l1 }}>L1</span> Block #{block.blockNumber}
    </span>
    <span style={{ color: COLORS.dim }}>
      {block.txs.length} tx{block.txs.length !== 1 ? "s" : ""}
    </span>
    {block.batchInfo?.hasBatch && (
      <span
        style={{
          padding: "1px 6px",
          background: COLORS.l1bg,
          border: `1px solid ${COLORS.l1b}`,
          borderRadius: 3,
          color: COLORS.l1,
          fontWeight: 700,
          fontSize: "0.5rem",
        }}
      >
        BATCH
      </span>
    )}
    {block.batchInfo?.l2Blocks && block.batchInfo.l2Blocks.length > 0 && (
      <span style={{ color: COLORS.l2, fontSize: "0.55rem" }}>
        L2 blocks: [{block.batchInfo.l2Blocks.join(", ")}]
      </span>
    )}
  </div>
);

// ── Tx trace section (call tree with contract names) ──

const TxTraceSection: React.FC<{
  trace: TraceResponse;
  index: number;
  expandedNodes: Set<string>;
  onToggleExpand: (path: string) => void;
}> = ({ trace, index, expandedNodes, onToggleExpand }) => (
  <div
    style={{
      border: `1px solid ${COLORS.brd}`,
      borderRadius: 6,
      overflow: "hidden",
      marginBottom: 10,
    }}
  >
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 8,
        padding: "5px 10px",
        background: COLORS.s2,
        borderBottom: `1px solid ${COLORS.brd}`,
        fontSize: "0.6rem",
      }}
    >
      <span
        style={{
          padding: "1px 5px",
          borderRadius: 3,
          background: trace.status === "success" ? "rgba(52,211,153,0.15)" : "rgba(239,68,68,0.15)",
          color: trace.status === "success" ? COLORS.ok : COLORS.rm,
          fontWeight: 700,
          fontSize: "0.5rem",
        }}
      >
        {trace.status === "success" ? "OK" : "REVERT"}
      </span>
      <span style={{ fontWeight: 700 }}>
        Cross-Chain Call #{index + 1}
      </span>
      <span style={{ color: COLORS.dim }}>
        {trace.txHash.slice(0, 14)}...{trace.txHash.slice(-6)}
      </span>
      {trace.callTree.funcName && (
        <span style={{ color: COLORS.add, fontWeight: 600 }}>
          {trace.callTree.label}::{trace.callTree.funcName}()
        </span>
      )}
      {trace.blockContext && trace.blockContext.l2Blocks.length > 0 && (
        <span style={{ color: COLORS.l2, fontSize: "0.5rem" }}>
          L2: [{trace.blockContext.l2Blocks.join(", ")}]
        </span>
      )}
    </div>
    <TraceCallTree
      tree={trace.callTree}
      chain={trace.chain}
      expandedNodes={expandedNodes}
      onToggleExpand={onToggleExpand}
    />
  </div>
);

// ── Simple event list ──

import type { EventRecord } from "../types/events";

const EventList: React.FC<{ events: EventRecord[] }> = ({ events }) => (
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
    {events.map((ev) => (
      <div
        key={ev.id}
        style={{
          display: "flex",
          gap: 8,
          padding: "2px 0",
          borderBottom: `1px solid ${COLORS.s3}`,
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
        <span style={{ fontWeight: 700 }}>{ev.eventName}</span>
        <span style={{ color: COLORS.dim, fontSize: "0.55rem" }}>
          {ev.transactionHash.slice(0, 10)}...
        </span>
      </div>
    ))}
  </div>
);
