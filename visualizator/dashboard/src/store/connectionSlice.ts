import type { StateCreator } from "zustand";

export type ConnectionSlice = {
  l1RpcUrl: string;
  l2RpcUrl: string;
  l1ContractAddress: string;
  l2ContractAddress: string;
  connected: boolean;
  l1Connected: boolean;
  l2Connected: boolean;
  setL1RpcUrl: (url: string) => void;
  setL2RpcUrl: (url: string) => void;
  setL1ContractAddress: (addr: string) => void;
  setL2ContractAddress: (addr: string) => void;
  setConnected: (l1: boolean, l2: boolean) => void;
};

export const createConnectionSlice: StateCreator<ConnectionSlice> = (set) => ({
  l1RpcUrl: "http://localhost:8545",
  l2RpcUrl: "http://localhost:8546",
  l1ContractAddress: "",
  l2ContractAddress: "",
  connected: false,
  l1Connected: false,
  l2Connected: false,
  setL1RpcUrl: (url) => set({ l1RpcUrl: url }),
  setL2RpcUrl: (url) => set({ l2RpcUrl: url }),
  setL1ContractAddress: (addr) => set({ l1ContractAddress: addr }),
  setL2ContractAddress: (addr) => set({ l2ContractAddress: addr }),
  setConnected: (l1, l2) =>
    set({ l1Connected: l1, l2Connected: l2, connected: l1 || l2 }),
});
