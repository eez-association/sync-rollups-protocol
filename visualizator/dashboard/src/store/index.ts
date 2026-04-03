import { create } from "zustand";
import type { ConnectionSlice } from "./connectionSlice";
import type { EventsSlice } from "./eventsSlice";
import type { ExecutionTableSlice } from "./executionTableSlice";
import type { ArchitectureSlice } from "./architectureSlice";
import type { PlaybackSlice } from "./playbackSlice";
import type { TraceSlice } from "./traceSlice";
import { createConnectionSlice } from "./connectionSlice";
import { createEventsSlice } from "./eventsSlice";
import { createExecutionTableSlice } from "./executionTableSlice";
import { createArchitectureSlice } from "./architectureSlice";
import { createPlaybackSlice } from "./playbackSlice";
import { createTraceSlice } from "./traceSlice";

export type StoreState = ConnectionSlice &
  EventsSlice &
  ExecutionTableSlice &
  ArchitectureSlice &
  PlaybackSlice &
  TraceSlice & {
    contractState: Record<string, string>;
    changedKeys: string[];
    updateContractState: (key: string, value: string) => void;
    setChangedKeys: (keys: string[]) => void;
    clearAll: () => void;
  };

export const useStore = create<StoreState>()((...a) => ({
  ...createConnectionSlice(...a),
  ...createEventsSlice(...a),
  ...createExecutionTableSlice(...a),
  ...createArchitectureSlice(...a),
  ...createPlaybackSlice(...a),
  ...createTraceSlice(...a),
  contractState: {},
  changedKeys: [],
  updateContractState: (key, value) =>
    a[0]((state) => ({
      contractState: { ...state.contractState, [key]: value },
      changedKeys: [...state.changedKeys.filter((k) => k !== key), key],
    })),
  setChangedKeys: (keys) => a[0]({ changedKeys: keys }),
  clearAll: () => {
    const [set] = a;
    set({
      events: [],
      l1Table: [],
      l2Table: [],
      l1Nodes: [],
      l2Nodes: [],
      edges: [],
      knownAddresses: new Map(),
      activeNodes: new Set(),
      activeEdges: new Set(),
      contractState: {},
      changedKeys: [],
      selectedEventId: null,
      connected: false,
      l1Connected: false,
      l2Connected: false,
    });
  },
}));
