import { SegmentedControl } from "@arkdeck/ds";

/** v0.6: execution modes are not a Flash-page control. Segments remain for real view choices. */
export const TracePresetSource = () => (
  <SegmentedControl
    label="Trace 配置来源"
    options={[
      { value: "preset", label: "Preset" },
      { value: "custom", label: "Custom" },
    ]}
    value="preset"
  />
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
