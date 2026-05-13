import { useEffect, useRef } from "react";
import { useStore } from "../store";
import { initManagerNodes } from "../lib/autoDiscovery";

/**
 * Seeds manager nodes when contract addresses are set.
 */
export function useAutoDiscovery() {
  const l1ContractAddress = useStore((s) => s.l1ContractAddress);
  const l2ContractAddress = useStore((s) => s.l2ContractAddress);
  const addNodes = useStore((s) => s.addNodes);
  const addKnownAddresses = useStore((s) => s.addKnownAddresses);
  const seededRef = useRef(false);

  useEffect(() => {
    if (seededRef.current) return;
    if (!l1ContractAddress && !l2ContractAddress) return;
    seededRef.current = true;

    const result = initManagerNodes(l1ContractAddress, l2ContractAddress);
    if (result.newNodes.length > 0) addNodes(result.newNodes);
    if (result.addressInfos.length > 0) addKnownAddresses(result.addressInfos);
  }, [l1ContractAddress, l2ContractAddress, addNodes, addKnownAddresses]);
}
