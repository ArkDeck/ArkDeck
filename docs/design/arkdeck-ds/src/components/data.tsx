import type { ReactNode } from "react";

export interface DataTableColumn {
  key: string;
  header: ReactNode;
  /** Render the cell monospace — for ids, paths, hashes, sizes. */
  mono?: boolean;
}

export interface DataTableRow {
  id: string;
  cells: Record<string, ReactNode>;
}

export interface DataTableProps {
  columns: DataTableColumn[];
  rows: DataTableRow[];
  /** Row id to mark selected — the accent tint, not a checkbox. */
  selectedId?: string;
  onSelect?: (id: string) => void;
  /** Shown in place of the body when `rows` is empty. */
  emptyText?: ReactNode;
  className?: string;
}

/**
 * Data table for plans, inventories, and artifact lists.
 *
 * Scrolls horizontally inside its own wrapper so a wide plan never makes the
 * page scroll sideways. Selection is a row tint rather than a control, because
 * selecting a row is always a navigation act, never a mutation.
 */
export function DataTable({
  columns,
  rows,
  selectedId,
  onSelect,
  emptyText = "No matching rows",
  className,
}: DataTableProps) {
  return (
    <div className="ad-table__wrap">
      <table className={["ad-table", className].filter(Boolean).join(" ")}>
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key}>{c.header}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.length === 0 ? (
            <tr>
              <td colSpan={columns.length} style={{ fontStyle: "italic", opacity: 0.7 }}>
                {emptyText}
              </td>
            </tr>
          ) : (
            rows.map((r) => (
              <tr
                key={r.id}
                aria-selected={r.id === selectedId}
                onClick={onSelect ? () => onSelect(r.id) : undefined}
                style={onSelect ? { cursor: "pointer" } : undefined}
              >
                {columns.map((c) => (
                  <td key={c.key} className={c.mono ? "ad-mono" : undefined}>
                    {r.cells[c.key]}
                  </td>
                ))}
              </tr>
            ))
          )}
        </tbody>
      </table>
    </div>
  );
}

export interface LogTailProps {
  /** Newest last — the component does not reorder. */
  lines: string[];
  /** CSS max-height; the tail scrolls inside it. */
  maxHeight?: number | string;
  /** Full-contrast ink for a live stream; muted for a quiet job tail. */
  emphasis?: boolean;
  className?: string;
}

/**
 * Monospace log tail.
 *
 * Shows the tail of a stream verbatim — exact commands, exit codes, device
 * output. Never summarizes or re-orders: a reader comparing this against their
 * own terminal must see the same bytes.
 */
export function LogTail({ lines, maxHeight = 110, emphasis, className }: LogTailProps) {
  return (
    <pre
      className={["ad-logtail", emphasis && "ad-logtail--emphasis", className]
        .filter(Boolean)
        .join(" ")}
      style={{ maxHeight }}
    >
      {lines.join("\n")}
    </pre>
  );
}

export interface PhaseTrackProps {
  /** Ordered phase names, exactly as the job declares them. */
  phases: string[];
  /** Index of the phase currently executing. */
  currentIndex: number;
  /** Only a `running` job highlights its current phase. */
  running?: boolean;
  className?: string;
}

/**
 * Phase sequence for a running job.
 *
 * Replaces a percentage bar: the reader sees which named phase is executing and
 * how many remain. Completed phases turn green, the current one accents — a
 * finished or cancelled job shows no highlight at all.
 */
export function PhaseTrack({ phases, currentIndex, running, className }: PhaseTrackProps) {
  return (
    <div className={["ad-phases", className].filter(Boolean).join(" ")}>
      {phases.map((p, i) => (
        <span
          key={p}
          className={[
            "ad-phase",
            i < currentIndex && "ad-phase--done",
            i === currentIndex && running && "ad-phase--running",
          ]
            .filter(Boolean)
            .join(" ")}
        >
          {p}
        </span>
      ))}
    </div>
  );
}

export type DeviceState = "ready" | "unauthorized" | "offline";

export interface DeviceRowProps {
  name: string;
  /** Build string when ready; the reason and next step otherwise. */
  detail: string;
  /** Transport tag — USB, TCP, UART. */
  transport: string;
  state: DeviceState;
  selected?: boolean;
  onClick?: () => void;
  className?: string;
}

/**
 * Sidebar device row.
 *
 * The dot encodes reachability, never trust: an `unauthorized` device is
 * present and visible, and its detail line says what the operator must do on
 * the device itself. Targets are added explicitly — the workbench never scans
 * the network.
 */
export function DeviceRow({
  name,
  detail,
  transport,
  state,
  selected,
  onClick,
  className,
}: DeviceRowProps) {
  return (
    <button
      type="button"
      className={["ad-device", className].filter(Boolean).join(" ")}
      aria-current={selected ? "true" : undefined}
      onClick={onClick}
    >
      <span className={`ad-device__dot ad-device__dot--${state}`} aria-hidden="true" />
      <span className="ad-device__name">
        <b>{name}</b>
        <span>{detail}</span>
      </span>
      <span className="ad-device__transport">{transport}</span>
    </button>
  );
}
