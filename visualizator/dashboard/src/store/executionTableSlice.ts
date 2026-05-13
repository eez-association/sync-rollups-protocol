import type { StateCreator } from "zustand";
import type { TableEntry } from "../types/visualization";

export type ExecutionTableSlice = {
  l1Table: TableEntry[];
  l2Table: TableEntry[];
  addL1Entries: (entries: TableEntry[]) => void;
  addL2Entries: (entries: TableEntry[]) => void;
  consumeL1Entry: (crossChainCallHash: string, actionDetail?: Record<string, string>) => void;
  consumeL2Entry: (crossChainCallHash: string, actionDetail?: Record<string, string>) => void;
  clearTables: () => void;
};

export const createExecutionTableSlice: StateCreator<ExecutionTableSlice> = (
  set,
) => ({
  l1Table: [],
  l2Table: [],
  addL1Entries: (entries) =>
    set((state) => ({
      l1Table: [
        ...state.l1Table.map((e) =>
          e.status === "ja" ? { ...e, status: "ok" as const } : e,
        ),
        ...entries,
      ],
    })),
  addL2Entries: (entries) =>
    set((state) => ({
      l2Table: [
        ...state.l2Table.map((e) =>
          e.status === "ja" ? { ...e, status: "ok" as const } : e,
        ),
        ...entries,
      ],
    })),
  consumeL1Entry: (crossChainCallHash, actionDetail) =>
    set((state) => ({
      l1Table: state.l1Table.map((e) =>
        e.crossChainCallHash === crossChainCallHash
          ? { ...e, status: "jc" as const, ...(actionDetail && Object.keys(actionDetail).length > 0 ? { actionDetail } : {}) }
          : e,
      ),
    })),
  consumeL2Entry: (crossChainCallHash, actionDetail) =>
    set((state) => ({
      l2Table: state.l2Table.map((e) =>
        e.crossChainCallHash === crossChainCallHash
          ? { ...e, status: "jc" as const, ...(actionDetail && Object.keys(actionDetail).length > 0 ? { actionDetail } : {}) }
          : e,
      ),
    })),
  clearTables: () => set({ l1Table: [], l2Table: [] }),
});
