import { SegmentedControl } from "@arkdeck/ds";

const EXECUTION_MODES = [
  { value: "execute", label: "Execute" },
  { value: "planOnly", label: "Plan only" },
  { value: "simulated", label: "Simulated" },
];

/** Flash page default: dispatch is live, no execution-mode badge follows the job. */
export const ExecutionModeExecute = () => (
  <SegmentedControl label="执行模式" options={EXECUTION_MODES} value="execute" />
);

/** Plan only — the plan is produced in full, deviceMutation/destructive steps are never dispatched. */
export const ExecutionModePlanOnly = () => (
  <SegmentedControl label="执行模式" options={EXECUTION_MODES} value="planOnly" />
);

/** Simulated — runs against fixture-a3, touches no real device. */
export const ExecutionModeSimulated = () => (
  <SegmentedControl label="执行模式" options={EXECUTION_MODES} value="simulated" />
);

/** Inline `sm` form: the Debug logs level floor, sitting in a card heading row. */
export const LogLevelFloorInline = () => (
  <span style={{ display: "inline-flex", gap: 8, alignItems: "center" }}>
    <span style={{ fontSize: 12, color: "var(--ad-ink-2)" }}>level ≥</span>
    <SegmentedControl
      label="日志等级下限"
      size="sm"
      options={[
        { value: "I", label: "I" },
        { value: "W", label: "W" },
        { value: "E", label: "E" },
      ]}
      value="W"
    />
  </span>
);

/** Inline `sm` form: Trace duration, next to buffer and tool chips. */
export const TraceDurationInline = () => (
  <span style={{ display: "inline-flex", gap: 8, alignItems: "center" }}>
    <span style={{ fontSize: 13, color: "var(--ad-ink)" }}>duration</span>
    <SegmentedControl
      label="抓取时长"
      size="sm"
      options={[
        { value: "10", label: "10s" },
        { value: "15", label: "15s" },
        { value: "30", label: "30s" },
      ]}
      value="15"
    />
  </span>
);

/** Inline `sm` form: Trace tag-source switch in the 抓取配置 card heading. */
export const TraceTagSourceInline = () => (
  <SegmentedControl
    label="tag 来源"
    size="sm"
    options={[
      { value: "preset", label: "Preset" },
      { value: "custom", label: "自定义 tag" },
    ]}
    value="custom"
  />
);
