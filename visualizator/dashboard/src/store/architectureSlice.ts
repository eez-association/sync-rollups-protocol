import type { StateCreator } from "zustand";
import type { ArchNode, ArchEdge, Chain } from "../types/visualization";
import type { AddressInfo } from "../lib/autoDiscovery";

export type ArchitectureSlice = {
  l1Nodes: ArchNode[];
  l2Nodes: ArchNode[];
  edges: ArchEdge[];
  knownAddresses: Map<string, AddressInfo>;
  activeNodes: Set<string>;
  activeEdges: Set<string>;
  addNodes: (nodes: { chain: Chain; node: ArchNode }[]) => void;
  addEdges: (edges: ArchEdge[]) => void;
  addKnownAddresses: (infos: AddressInfo[]) => void;
  setActiveNodes: (ids: string[]) => void;
  setActiveEdges: (ids: string[]) => void;
  clearArchitecture: () => void;
};

export const createArchitectureSlice: StateCreator<ArchitectureSlice> = (
  set,
) => ({
  l1Nodes: [],
  l2Nodes: [],
  edges: [],
  knownAddresses: new Map(),
  activeNodes: new Set(),
  activeEdges: new Set(),
  addNodes: (nodes) =>
    set((state) => {
      const l1 = [...state.l1Nodes];
      const l2 = [...state.l2Nodes];
      for (const { chain, node } of nodes) {
        const list = chain === "l1" ? l1 : l2;
        if (!list.some((n) => n.id === node.id)) {
          list.push(node);
        }
      }
      return { l1Nodes: l1, l2Nodes: l2 };
    }),
  addEdges: (edges) =>
    set((state) => {
      const existing = new Set(state.edges.map((e) => e.id || `${e.from}->${e.to}`));
      const newEdges = edges.filter(
        (e) => !existing.has(e.id || `${e.from}->${e.to}`),
      );
      return { edges: [...state.edges, ...newEdges] };
    }),
  addKnownAddresses: (infos) =>
    set((state) => {
      const map = new Map(state.knownAddresses);
      for (const info of infos) {
        map.set(info.address.toLowerCase(), info);
      }
      return { knownAddresses: map };
    }),
  setActiveNodes: (ids) => set({ activeNodes: new Set(ids) }),
  setActiveEdges: (ids) => set({ activeEdges: new Set(ids) }),
  clearArchitecture: () =>
    set({
      l1Nodes: [],
      l2Nodes: [],
      edges: [],
      knownAddresses: new Map(),
      activeNodes: new Set(),
      activeEdges: new Set(),
    }),
});
