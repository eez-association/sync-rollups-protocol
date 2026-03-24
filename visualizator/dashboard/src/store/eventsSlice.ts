import type { StateCreator } from "zustand";
import type { EventRecord } from "../types/events";

export type EventsSlice = {
  events: EventRecord[];
  addEvent: (event: EventRecord) => void;
  clearEvents: () => void;
};

export const createEventsSlice: StateCreator<EventsSlice> = (set) => ({
  events: [],
  addEvent: (event) =>
    set((state) => {
      // Insert in order by blockNumber, then logIndex
      const events = [...state.events];
      let i = events.length;
      while (
        i > 0 &&
        (events[i - 1].blockNumber > event.blockNumber ||
          (events[i - 1].blockNumber === event.blockNumber &&
            events[i - 1].logIndex > event.logIndex))
      ) {
        i--;
      }
      // Deduplicate by id
      if (events.some((e) => e.id === event.id)) return state;
      events.splice(i, 0, event);
      return { events };
    }),
  clearEvents: () => set({ events: [] }),
});
