import type { StateCreator } from "zustand";

export type PlaybackSlice = {
  selectedEventId: string | null; // null = live (latest)
  setSelectedEventId: (id: string | null) => void;
  isLive: () => boolean;
};

export const createPlaybackSlice: StateCreator<PlaybackSlice> = (set, get) => ({
  selectedEventId: null,
  setSelectedEventId: (id) => set({ selectedEventId: id }),
  isLive: () => get().selectedEventId === null,
});
