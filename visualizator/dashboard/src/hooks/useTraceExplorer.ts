import { useCallback, useMemo } from "react";
import { createPublicClient, http, type Hex, decodeEventLog } from "viem";
import { foundry } from "viem/chains";
import { useStore } from "../store";
import { rollupsAbi } from "../abi/rollups";
import { crossChainManagerL2Abi } from "../abi/crossChainManagerL2";
import type { EventRecord, EventName } from "../types/events";
import type { BlockInfoResponse } from "../types/trace";
import { traceTransaction } from "../lib/traceDecoder";

const BATCH_POSTED_TOPIC = "0x2f482312f12dceb86aac9ef0e0e1d9421ac62910326b3d50695d63117321b520" as Hex;
const ALL_ABIS = [...rollupsAbi, ...crossChainManagerL2Abi];

export function useTraceExplorer() {
  const l1RpcUrl = useStore((s) => s.l1RpcUrl);
  const l2RpcUrl = useStore((s) => s.l2RpcUrl);
  const rollupsAddress = useStore((s) => s.rollupsAddress);
  const managerL2Address = useStore((s) => s.managerL2Address);
  const setCurrentBlock = useStore((s) => s.setCurrentBlock);
  const setBlockEvents = useStore((s) => s.setBlockEvents);
  const setBlockTraces = useStore((s) => s.setBlockTraces);
  const setTraceLoading = useStore((s) => s.setTraceLoading);
  const setTraceError = useStore((s) => s.setTraceError);

  const clients = useMemo(() => ({
    l1: createPublicClient({
      chain: { ...foundry, id: 31337 },
      transport: http(l1RpcUrl),
    }),
    l2: createPublicClient({
      chain: { ...foundry, id: 31338 },
      transport: http(l2RpcUrl),
    }),
  }), [l1RpcUrl, l2RpcUrl]);

  // Decode raw logs from a contract into EventRecord[]
  const decodeLogs = useCallback((
    rawLogs: any[],
    chain: "l1" | "l2",
    abi: readonly unknown[],
  ): EventRecord[] => {
    const records: EventRecord[] = [];
    for (const log of rawLogs) {
      try {
        const decoded = decodeEventLog({
          abi: abi as any,
          data: log.data,
          topics: log.topics,
        });
        records.push({
          id: `${chain}-${log.blockNumber}-${log.logIndex}`,
          chain,
          eventName: decoded.eventName as EventName,
          blockNumber: log.blockNumber,
          logIndex: log.logIndex ?? 0,
          transactionHash: log.transactionHash,
          args: (decoded.args ?? {}) as Record<string, unknown>,
        });
      } catch { /* skip unknown events */ }
    }
    return records;
  }, []);

  // Extract L2 block numbers from a postBatch tx's callData
  const extractL2Blocks = useCallback(async (batchTxHash: Hex): Promise<number[]> => {
    try {
      const { decodeFunctionData, decodeAbiParameters } = await import("viem");
      const tx = await clients.l1.getTransaction({ hash: batchTxHash });
      // postBatch(entries, blobCount, callData, proof)
      const postBatchAbi = [{
        name: "postBatch",
        type: "function" as const,
        inputs: [
          { name: "entries", type: "tuple[]", components: [{ name: "stateDeltas", type: "tuple[]", components: [{ name: "rollupId", type: "uint256" }, { name: "currentState", type: "bytes32" }, { name: "newState", type: "bytes32" }, { name: "etherDelta", type: "int256" }] }, { name: "actionHash", type: "bytes32" }, { name: "nextAction", type: "tuple", components: [{ name: "actionType", type: "uint8" }, { name: "rollupId", type: "uint256" }, { name: "destination", type: "address" }, { name: "value", type: "uint256" }, { name: "data", type: "bytes" }, { name: "failed", type: "bool" }, { name: "sourceAddress", type: "address" }, { name: "sourceRollup", type: "uint256" }, { name: "scope", type: "uint256[]" }] }] },
          { name: "blobCount", type: "uint256" },
          { name: "callData", type: "bytes" },
          { name: "proof", type: "bytes" },
        ],
        outputs: [],
        stateMutability: "nonpayable" as const,
      }];
      const decoded = decodeFunctionData({ abi: postBatchAbi, data: tx.input });
      const callDataBytes = (decoded.args as any)[2] as Hex;
      if (!callDataBytes || callDataBytes === "0x") return [];
      const inner = decodeAbiParameters(
        [{ name: "blockNumbers", type: "uint256[]" }, { name: "blockData", type: "bytes[]" }],
        callDataBytes,
      );
      return (inner[0] as bigint[]).map(Number);
    } catch {
      return [];
    }
  }, [clients.l1]);

  // Load a block: get L1 events, find L2 blocks, get L2 events
  const loadBlock = useCallback(async (blockNumber: number) => {
    setTraceLoading(true);
    setTraceError(null);
    setCurrentBlock(null);
    setBlockEvents([]);
    setBlockTraces([]);

    try {
      // 1. Get L1 block info
      const l1Block = await clients.l1.getBlock({
        blockNumber: BigInt(blockNumber),
        includeTransactions: true,
      });
      if (!l1Block) throw new Error("Block not found");

      // 2. Get all L1 contract events in this block
      const l1Logs = await clients.l1.getLogs({
        address: rollupsAddress as Hex,
        fromBlock: BigInt(blockNumber),
        toBlock: BigInt(blockNumber),
      });
      const l1Events = decodeLogs(l1Logs, "l1", rollupsAbi);

      // 3. Check for batch → find L2 blocks
      const batchLogs = l1Logs.filter(
        (l) => l.topics[0]?.toLowerCase() === BATCH_POSTED_TOPIC.toLowerCase()
      );
      let l2Blocks: number[] = [];
      let batchTxHash: string | null = null;
      if (batchLogs.length > 0) {
        batchTxHash = batchLogs[0].transactionHash;
        l2Blocks = await extractL2Blocks(batchTxHash as Hex);
      }

      // 4. Get L2 events from correlated blocks
      const l2Events: EventRecord[] = [];
      for (const l2Block of l2Blocks) {
        const l2Logs = await clients.l2.getLogs({
          address: managerL2Address as Hex,
          fromBlock: BigInt(l2Block),
          toBlock: BigInt(l2Block),
        });
        l2Events.push(...decodeLogs(l2Logs, "l2", crossChainManagerL2Abi));
      }

      // 5. Build block info
      const txs = l1Block.transactions.map((tx) => {
        if (typeof tx === "string") return { hash: tx, from: "", to: null, funcName: null };
        return { hash: tx.hash, from: tx.from, to: tx.to, funcName: null };
      });

      const blockInfo: BlockInfoResponse = {
        blockNumber,
        timestamp: Number(l1Block.timestamp),
        txs,
        batchInfo: {
          hasBatch: batchLogs.length > 0,
          batchTxHash,
          l2Blocks,
        },
      };

      setCurrentBlock(blockInfo);

      // 6. Combine and sort all events
      const allEvents = [...l1Events, ...l2Events].sort((a, b) => {
        if (a.chain !== b.chain) return a.chain === "l1" ? -1 : 1;
        const blockDiff = Number(a.blockNumber) - Number(b.blockNumber);
        if (blockDiff !== 0) return blockDiff;
        return a.logIndex - b.logIndex;
      });

      setBlockEvents(allEvents);

      // 7. Trace L1 cross-chain txs only (L2 side is inlined via debug trace)
      const crossChainTxHashes = new Set<string>();
      for (const ev of l1Events) {
        if (ev.eventName === "CrossChainCallExecuted") {
          crossChainTxHashes.add(ev.transactionHash);
        }
      }

      const traces = [];
      for (const txHash of crossChainTxHashes) {
        try {
          const trace = await traceTransaction(
            txHash as Hex,
            clients.l1,
            clients.l2,
            rollupsAddress,
            managerL2Address,
          );
          traces.push(trace);
        } catch (e) {
          console.warn(`Failed to trace ${txHash.slice(0, 10)}:`, e);
        }
      }
      setBlockTraces(traces);
    } catch (e: any) {
      setTraceError(e.message || "Failed to load block");
    } finally {
      setTraceLoading(false);
    }
  }, [clients, rollupsAddress, managerL2Address, decodeLogs, extractL2Blocks]);

  const loadLatestBlock = useCallback(async () => {
    try {
      const blockNum = Number(await clients.l1.getBlockNumber());
      await loadBlock(blockNum);
    } catch (e: any) {
      setTraceError(e.message || "Failed to get latest block");
    }
  }, [clients, loadBlock]);

  // Single tx trace — fetch its block
  const traceByTxHash = useCallback(async (txHash: string) => {
    setTraceLoading(true);
    setTraceError(null);
    try {
      // Find which block the tx is in
      let receipt;
      try {
        receipt = await clients.l1.getTransactionReceipt({ hash: txHash as Hex });
      } catch {
        receipt = await clients.l2.getTransactionReceipt({ hash: txHash as Hex });
      }
      await loadBlock(Number(receipt.blockNumber));
    } catch (e: any) {
      setTraceError(e.message || "Transaction not found");
      setTraceLoading(false);
    }
  }, [clients, loadBlock]);

  return { traceByTxHash, loadBlock, loadLatestBlock };
}
