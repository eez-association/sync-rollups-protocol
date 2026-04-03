import type { StateCreator } from "zustand";

export type ConnectionSlice = {
  l1RpcUrl: string;
  l2RpcUrl: string;
  rollupsAddress: string;
  managerL2Address: string;
  l1ExplorerUrl: string;
  l2ExplorerUrl: string;
  connected: boolean;
  l1Connected: boolean;
  l2Connected: boolean;
  setL1RpcUrl: (url: string) => void;
  setL2RpcUrl: (url: string) => void;
  setRollupsAddress: (addr: string) => void;
  setManagerL2Address: (addr: string) => void;
  setL1ExplorerUrl: (url: string) => void;
  setL2ExplorerUrl: (url: string) => void;
  setConnected: (l1: boolean, l2: boolean) => void;
};

export const createConnectionSlice: StateCreator<ConnectionSlice> = (set) => ({
  l1RpcUrl: "http://localhost:8545",
  l2RpcUrl: "http://localhost:8546",
  rollupsAddress: "",
  managerL2Address: "",
  l1ExplorerUrl: "",
  l2ExplorerUrl: "",
  connected: false,
  l1Connected: false,
  l2Connected: false,
  setL1RpcUrl: (url) => set({ l1RpcUrl: url }),
  setL2RpcUrl: (url) => set({ l2RpcUrl: url }),
  setRollupsAddress: (addr) => set({ rollupsAddress: addr }),
  setManagerL2Address: (addr) => set({ managerL2Address: addr }),
  setL1ExplorerUrl: (url) => set({ l1ExplorerUrl: url }),
  setL2ExplorerUrl: (url) => set({ l2ExplorerUrl: url }),
  setConnected: (l1, l2) =>
    set({ l1Connected: l1, l2Connected: l2, connected: l1 || l2 }),
});
