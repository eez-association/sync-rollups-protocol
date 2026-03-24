import { useEffect, useRef } from "react";
import { createPublicClient, http, type WatchContractEventReturnType } from "viem";
import { foundry } from "viem/chains";
import type { EventRecord, EventName } from "../types/events";
import type { Chain } from "../types/visualization";

type WatchConfig = {
  rpcUrl: string;
  contractAddress: `0x${string}`;
  abi: readonly unknown[];
  chain: Chain;
  onEvent: (event: EventRecord) => void;
  enabled: boolean;
};

export function useChainWatcher({
  rpcUrl,
  contractAddress,
  abi,
  chain,
  onEvent,
  enabled,
}: WatchConfig) {
  const unwatchRef = useRef<WatchContractEventReturnType[]>([]);
  const onEventRef = useRef(onEvent);
  onEventRef.current = onEvent;

  useEffect(() => {
    if (!enabled || !rpcUrl || !contractAddress) return;

    const client = createPublicClient({
      chain: { ...foundry, id: chain === "l1" ? 31337 : 31338 },
      transport: http(rpcUrl),
    });

    // First, fetch existing logs
    client
      .getContractEvents({
        address: contractAddress,
        abi: abi as any,
        fromBlock: 0n,
        toBlock: "latest",
      })
      .then((logs) => {
        for (const log of logs) {
          const record: EventRecord = {
            id: `${chain}-${log.blockNumber}-${log.logIndex}`,
            chain,
            eventName: (log as any).eventName as EventName,
            blockNumber: log.blockNumber,
            logIndex: log.logIndex ?? 0,
            transactionHash: log.transactionHash,
            args: (log as any).args ?? {},
          };
          onEventRef.current(record);
        }
      })
      .catch((err) => {
        console.error(`[${chain}] Failed to fetch historical logs:`, err);
      });

    // Then watch for new events
    const eventNames = (abi as any[])
      .filter((item: any) => item.type === "event")
      .map((item: any) => item.name);

    const unwatchers: WatchContractEventReturnType[] = [];
    for (const eventName of eventNames) {
      try {
        const unwatch = client.watchContractEvent({
          address: contractAddress,
          abi: abi as any,
          eventName,
          onLogs: (logs) => {
            for (const log of logs) {
              const record: EventRecord = {
                id: `${chain}-${log.blockNumber ?? 0n}-${log.logIndex ?? 0}`,
                chain,
                eventName: (log as any).eventName as EventName,
                blockNumber: log.blockNumber ?? 0n,
                logIndex: log.logIndex ?? 0,
                transactionHash: log.transactionHash ?? ("0x" as `0x${string}`),
                args: (log as any).args ?? {},
              };
              onEventRef.current(record);
            }
          },
        });
        unwatchers.push(unwatch);
      } catch (err) {
        console.error(`[${chain}] Failed to watch ${eventName}:`, err);
      }
    }

    unwatchRef.current = unwatchers;

    return () => {
      for (const unwatch of unwatchRef.current) {
        unwatch();
      }
      unwatchRef.current = [];
    };
  }, [rpcUrl, contractAddress, abi, chain, enabled]);
}
