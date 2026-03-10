import { useState, useEffect, useRef } from "react";
import { createPublicClient, http, decodeEventLog } from "viem";
import { foundry } from "viem/chains";
import { rollupsAbi } from "../abi/rollups";
import { crossChainManagerL2Abi } from "../abi/crossChainManagerL2";
import type { Chain } from "../types/visualization";
import type { TxMetadata, DecodedLog } from "../types/events";

const combinedAbi = [...rollupsAbi, ...crossChainManagerL2Abi];

const cache = new Map<string, TxMetadata>();

export function useTxIntrospection(
  txHash: `0x${string}` | null,
  rpcUrl: string,
  chain: Chain,
): { data: TxMetadata | null; loading: boolean } {
  const [data, setData] = useState<TxMetadata | null>(null);
  const [loading, setLoading] = useState(false);
  const fetchedRef = useRef<string | null>(null);

  useEffect(() => {
    if (!txHash || !rpcUrl) return;
    const key = `${chain}-${txHash}`;
    if (fetchedRef.current === key) return;
    fetchedRef.current = key;

    if (cache.has(key)) {
      setData(cache.get(key)!);
      return;
    }

    setLoading(true);
    const client = createPublicClient({
      chain: { ...foundry, id: chain === "l1" ? 31337 : 31338 },
      transport: http(rpcUrl),
    });

    client
      .getTransactionReceipt({ hash: txHash })
      .then((receipt) => {
        const decodedLogs: DecodedLog[] = [];
        for (const log of receipt.logs) {
          try {
            const decoded = decodeEventLog({
              abi: combinedAbi as any,
              data: log.data,
              topics: log.topics,
            }) as { eventName: string; args: Record<string, unknown> };
            decodedLogs.push({
              eventName: decoded.eventName,
              args: decoded.args,
              address: log.address,
              logIndex: log.logIndex,
            });
          } catch {
            decodedLogs.push({
              eventName: "Unknown",
              args: { data: log.data },
              address: log.address,
              logIndex: log.logIndex,
            });
          }
        }

        const metadata: TxMetadata = {
          hash: txHash,
          blockNumber: receipt.blockNumber,
          from: receipt.from,
          to: receipt.to,
          gasUsed: receipt.gasUsed,
          logs: decodedLogs,
        };
        cache.set(key, metadata);
        setData(metadata);
      })
      .catch((err) => {
        console.error("Failed to fetch tx receipt:", err);
      })
      .finally(() => {
        setLoading(false);
      });
  }, [txHash, rpcUrl, chain]);

  return { data, loading };
}
