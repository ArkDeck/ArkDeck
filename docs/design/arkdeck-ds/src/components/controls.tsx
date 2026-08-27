import type { ReactNode } from "react";

export interface SegmentedOption {
  value: string;
  label: ReactNode;
}

export interface SegmentedControlProps {
  options: SegmentedOption[];
  value: string;
  onChange?: (value: string) => void;
  /** `sm` is for inline use inside a card heading row. */
  size?: "md" | "sm";
  /** Accessible name for the group, e.g. "Execution mode". */
  label?: string;
  className?: string;
}

/**
 * Segmented control for mutually exclusive modes.
 *
 * The workbench's canonical use is the execution-mode switch
 * (Execute / Plan only / Simulated) — switching modes changes what the page is
 * allowed to dispatch, so the current mode must be visible without scrolling.
 */
export function SegmentedControl({
  options,
  value,
  onChange,
  size = "md",
  label,
  className,
}: SegmentedControlProps) {
  return (
    <span
      className={["ad-seg", size === "sm" && "ad-seg--sm", className].filter(Boolean).join(" ")}
      role="group"
      aria-label={label}
    >
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          aria-pressed={o.value === value}
          onClick={() => onChange?.(o.value)}
        >
          {o.label}
        </button>
      ))}
    </span>
  );
}

export interface FilterPillsProps {
  /** Leading label naming the dimension being filtered ("Status", "Mode", "Device"). */
  label?: string;
  options: SegmentedOption[];
  value: string;
  onChange?: (value: string) => void;
  className?: string;
}

/**
 * Filter pill row — one row per filter dimension.
 *
 * History filters on several dimensions at once (status, execution mode,
 * device); each gets its own labeled row so the active combination is readable
 * as a sentence rather than decoded from scattered highlights.
 */
export function FilterPills({ label, options, value, onChange, className }: FilterPillsProps) {
  return (
    <div className={["ad-filters", className].filter(Boolean).join(" ")}>
      {label ? <span className="ad-filters__label">{label}</span> : null}
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          aria-pressed={o.value === value}
          onClick={() => onChange?.(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

export interface TabsProps {
  tabs: SegmentedOption[];
  value: string;
  onChange?: (value: string) => void;
  label?: string;
  className?: string;
}

/**
 * Tab bar for sibling panels within one workspace.
 *
 * Used by the Debug workbench (Logs / Apps / Network / Commands). Tabs switch
 * the view only — never the target device, and never the execution mode.
 */
export function Tabs({ tabs, value, onChange, label, className }: TabsProps) {
  return (
    <div
      className={["ad-tabs", className].filter(Boolean).join(" ")}
      role="tablist"
      aria-label={label}
    >
      {tabs.map((t) => (
        <button
          key={t.value}
          type="button"
          role="tab"
          aria-selected={t.value === value}
          onClick={() => onChange?.(t.value)}
        >
          {t.label}
        </button>
      ))}
    </div>
  );
}

export interface NavItemProps {
  /** Single glyph shown in the fixed-width icon column. */
  icon?: ReactNode;
  label: ReactNode;
  active?: boolean;
  onClick?: () => void;
  className?: string;
}

/**
 * Sidebar navigation row.
 *
 * One row per workbench capability (Overview, Flash, Debug, Viewer, Trace,
 * Device, Diagnostics, History). Settings is a separate scene. The active row is the only accent-colored element in the
 * sidebar.
 */
export function NavItem({ icon, label, active, onClick, className }: NavItemProps) {
  return (
    <button
      type="button"
      className={["ad-nav", className].filter(Boolean).join(" ")}
      aria-current={active ? "page" : undefined}
      onClick={onClick}
    >
      <span className="ad-nav__icon" aria-hidden="true">
        {icon}
      </span>
      {label}
    </button>
  );
}
