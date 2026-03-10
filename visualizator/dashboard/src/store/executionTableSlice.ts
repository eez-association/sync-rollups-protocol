import type { StateCreator } from "zustand";
import type { TableEntry } from "../types/visualization";

export type ExecutionTableSlice = {
  l1Table: TableEntry[];
  l2Table: TableEntry[];
  addL1Entries: (entries: TableEntry[]) => void;
  addL2Entries: (entries: TableEntry[]) => void;
  consumeL1Entry: (actionHash: string) => void;
  consumeL2Entry: (actionHash: string) => void;
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
  consumeL1Entry: (actionHash) =>
    set((state) => ({
      l1Table: state.l1Table.map((e) =>
        e.actionHash === actionHash ? { ...e, status: "jc" as const } : e,
      ),
    })),
  consumeL2Entry: (actionHash) =>
    set((state) => ({
      l2Table: state.l2Table.map((e) =>
        e.actionHash === actionHash ? { ...e, status: "jc" as const } : e,
      ),
    })),
  clearTables: () => set({ l1Table: [], l2Table: [] }),
});
