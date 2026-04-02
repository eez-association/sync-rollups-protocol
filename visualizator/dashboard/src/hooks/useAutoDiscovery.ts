import { useEffect, useRef } from "react";
import { useStore } from "../store";
import { initManagerNodes } from "../lib/autoDiscovery";

/**
 * Seeds manager nodes when contract addresses are set.
 */
export function useAutoDiscovery() {
  const rollupsAddress = useStore((s) => s.rollupsAddress);
  const managerL2Address = useStore((s) => s.managerL2Address);
  const addNodes = useStore((s) => s.addNodes);
  const addKnownAddresses = useStore((s) => s.addKnownAddresses);
  const seededRef = useRef(false);

  useEffect(() => {
    if (seededRef.current) return;
    if (!rollupsAddress && !managerL2Address) return;
    seededRef.current = true;

    const result = initManagerNodes(rollupsAddress, managerL2Address);
    if (result.newNodes.length > 0) addNodes(result.newNodes);
    if (result.addressInfos.length > 0) addKnownAddresses(result.addressInfos);
  }, [rollupsAddress, managerL2Address, addNodes, addKnownAddresses]);
}
