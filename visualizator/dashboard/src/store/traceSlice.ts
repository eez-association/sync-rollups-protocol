import type { StateCreator } from "zustand";
import type { BlockInfoResponse, TraceResponse } from "../types/trace";
import type { EventRecord } from "../types/events";

export type TraceSlice = {
  dashboardMode: "live" | "trace" | "settings";
  setDashboardMode: (mode: "live" | "trace" | "settings") => void;

  currentBlock: BlockInfoResponse | null;
  setCurrentBlock: (block: BlockInfoResponse | null) => void;

  blockEvents: EventRecord[];
  setBlockEvents: (events: EventRecord[]) => void;

  blockTraces: TraceResponse[];
  setBlockTraces: (traces: TraceResponse[]) => void;

  traceLoading: boolean;
  setTraceLoading: (loading: boolean) => void;

  traceError: string | null;
  setTraceError: (error: string | null) => void;

  expandedNodes: Set<string>;
  toggleNodeExpanded: (path: string) => void;
};

export const createTraceSlice: StateCreator<TraceSlice> = (set) => ({
  dashboardMode: "trace",
  setDashboardMode: (mode) => set({ dashboardMode: mode }),

  currentBlock: null,
  setCurrentBlock: (block) => set({ currentBlock: block }),

  blockEvents: [],
  setBlockEvents: (events) => set({ blockEvents: events }),

  blockTraces: [],
  setBlockTraces: (traces) => set({ blockTraces: traces }),

  traceLoading: false,
  setTraceLoading: (loading) => set({ traceLoading: loading }),

  traceError: null,
  setTraceError: (error) => set({ traceError: error }),

  expandedNodes: new Set(),
  toggleNodeExpanded: (path) =>
    set((state) => {
      const next = new Set(state.expandedNodes);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return { expandedNodes: next };
    }),
});
