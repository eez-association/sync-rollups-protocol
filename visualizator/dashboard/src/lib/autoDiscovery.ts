import type { EventRecord, EventName } from "../types/events";
import type { ArchNode, ArchEdge, Chain, NodeType } from "../types/visualization";
import { truncateAddress } from "./actionFormatter";

export type AddressInfo = {
  address: string;
  label: string;
  type: NodeType;
  chain: Chain;
  rollupId?: bigint;
};

export type DiscoveryResult = {
  newNodes: { chain: Chain; node: ArchNode }[];
  newEdges: ArchEdge[];
  addressInfos: AddressInfo[];
};

let nextCol: Record<Chain, number> = { l1: 0, l2: 0 };

export function resetDiscovery() {
  nextCol = { l1: 0, l2: 0 };
}

export function initManagerNodes(
  l1Address: string,
  l2Address: string,
): DiscoveryResult {
  resetDiscovery();
  const nodes: { chain: Chain; node: ArchNode }[] = [];
  const addressInfos: AddressInfo[] = [];

  if (l1Address) {
    nodes.push({
      chain: "l1",
      node: {
        id: l1Address.toLowerCase(),
        label: "Rollups",
        sub: "Manager",
        type: "system",
        col: nextCol.l1++,
      },
    });
    addressInfos.push({
      address: l1Address.toLowerCase(),
      label: "Rollups",
      type: "system",
      chain: "l1",
    });
  }
  if (l2Address) {
    nodes.push({
      chain: "l2",
      node: {
        id: l2Address.toLowerCase(),
        label: "ManagerL2",
        sub: "Manager",
        type: "system",
        col: nextCol.l2++,
      },
    });
    addressInfos.push({
      address: l2Address.toLowerCase(),
      label: "ManagerL2",
      type: "system",
      chain: "l2",
    });
  }

  return { newNodes: nodes, newEdges: [], addressInfos };
}

export function discoverFromEvent(
  event: EventRecord,
  knownAddresses: Map<string, AddressInfo>,
  existingNodeIds: Set<string>,
  l1ManagerAddress: string,
  l2ManagerAddress: string,
): DiscoveryResult {
  const newNodes: { chain: Chain; node: ArchNode }[] = [];
  const newEdges: ArchEdge[] = [];
  const addressInfos: AddressInfo[] = [];

  function ensureNode(
    address: string,
    label: string,
    type: NodeType,
    chain: Chain,
  ) {
    const id = address.toLowerCase();
    if (existingNodeIds.has(id)) return;
    existingNodeIds.add(id);
    const node: ArchNode = {
      id,
      label,
      sub: truncateAddress(address),
      type,
      col: nextCol[chain]++,
    };
    newNodes.push({ chain, node });
    addressInfos.push({ address: id, label, type, chain });
  }

  const args = event.args;

  switch (event.eventName as EventName) {
    case "CrossChainProxyCreated": {
      const proxy = (args.proxy as string).toLowerCase();
      const orig = (args.originalAddress as string).toLowerCase();
      const rollupId = args.originalRollupId as bigint;
      // The original lives on the OPPOSITE chain from the proxy.
      // Only use the known label if it's on the correct (opposite) chain,
      // otherwise we get cross-chain collisions (e.g. same address = Rollups on L1 but Counter on L2).
      const origChain = event.chain === "l1" ? "l2" : "l1";
      const origKnown = knownAddresses.get(orig);
      const proxyLabel = (origKnown && origKnown.chain === origChain)
        ? `${origKnown.label}'`
        : truncateAddress(proxy);
      ensureNode(proxy, proxyLabel, "proxy", event.chain);
      const managerId =
        event.chain === "l1"
          ? l1ManagerAddress.toLowerCase()
          : l2ManagerAddress.toLowerCase();
      if (managerId && existingNodeIds.has(managerId)) {
        newEdges.push({
          from: proxy,
          to: managerId,
          label: `proxy(r${rollupId})`,
          id: `${proxy}->${managerId}`,
        });
      }
      break;
    }

    case "BatchPosted": {
      const proverId = "__prover__";
      if (!existingNodeIds.has(proverId)) {
        existingNodeIds.add(proverId);
        newNodes.push({
          chain: "l1",
          node: {
            id: proverId,
            label: "Prover",
            sub: "ZK batch poster",
            type: "ghost",
            col: nextCol.l1++,
          },
        });
      }
      const l1Manager = l1ManagerAddress.toLowerCase();
      if (l1Manager) {
        newEdges.push({
          from: proverId,
          to: l1Manager,
          label: "postBatch",
          id: `${proverId}->${l1Manager}`,
        });
      }
      break;
    }

    case "ExecutionTableLoaded": {
      const systemId = "__system__";
      if (!existingNodeIds.has(systemId)) {
        existingNodeIds.add(systemId);
        newNodes.push({
          chain: "l2",
          node: {
            id: systemId,
            label: "SYSTEM",
            sub: "sysAddr",
            type: "ghost",
            col: nextCol.l2++,
          },
        });
      }
      const l2Manager = l2ManagerAddress.toLowerCase();
      if (l2Manager) {
        newEdges.push({
          from: systemId,
          to: l2Manager,
          label: "loadTable",
          id: `${systemId}->${l2Manager}`,
        });
      }
      break;
    }

    case "CrossChainCallExecuted": {
      const src = (args.sourceAddress as string).toLowerCase();
      const proxy = (args.proxy as string).toLowerCase();
      if (!knownAddresses.has(src)) {
        ensureNode(src, truncateAddress(src), "user", event.chain);
      }
      if (existingNodeIds.has(src) && existingNodeIds.has(proxy)) {
        newEdges.push({
          from: src,
          to: proxy,
          label: "call",
          id: `${src}->${proxy}`,
        });
      }
      break;
    }

    case "IncomingCrossChainCallExecuted": {
      const dest = (args.destination as string).toLowerCase();
      const srcAddr = (args.sourceAddress as string).toLowerCase();
      if (!knownAddresses.has(dest)) {
        ensureNode(dest, truncateAddress(dest), "contract", event.chain);
      }
      // The source is from the other chain - add it as a known address
      if (srcAddr && srcAddr !== "0x0000000000000000000000000000000000000000") {
        const srcChain: Chain = event.chain === "l1" ? "l2" : "l1";
        if (!knownAddresses.has(srcAddr)) {
          addressInfos.push({
            address: srcAddr,
            label: truncateAddress(srcAddr),
            type: "contract",
            chain: srcChain,
          });
        }
      }
      // Add edge from manager to destination
      const managerId =
        event.chain === "l1"
          ? l1ManagerAddress.toLowerCase()
          : l2ManagerAddress.toLowerCase();
      if (managerId && existingNodeIds.has(managerId) && existingNodeIds.has(dest)) {
        newEdges.push({
          from: managerId,
          to: dest,
          label: "execIncoming",
          id: `${managerId}->${dest}`,
        });
      }
      break;
    }

    case "RollupCreated":
    case "StateUpdated":
    case "VerificationKeyUpdated":
    case "OwnershipTransferred":
    case "L2ExecutionPerformed":
    case "ExecutionConsumed":
    case "L2TXExecuted":
      break;
  }

  return { newNodes, newEdges, addressInfos };
}
