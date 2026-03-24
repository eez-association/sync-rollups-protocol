import React from "react";
import type { TableEntry } from "../types/visualization";
import { TablePanel } from "./TablePanel";

type Props = {
  l1Entries: TableEntry[];
  l2Entries: TableEntry[];
};

export const ExecutionTables: React.FC<Props> = ({ l1Entries, l2Entries }) => {
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "1fr 1fr",
        gap: 10,
      }}
    >
      <TablePanel
        title="L1 Execution Table (Rollups)"
        chain="l1"
        entries={l1Entries}
      />
      <TablePanel
        title="L2 Execution Table (ManagerL2)"
        chain="l2"
        entries={l2Entries}
      />
    </div>
  );
};
