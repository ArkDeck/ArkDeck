import { Callout, Card, DeviceRow, NavItem, Symbol, ToolbarButton } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

const sidebar = {
  width: "100%",
  maxWidth: 216,
  background: "var(--ad-panel-2)",
  border: "1px solid var(--ad-line)",
  borderRadius: 10,
  padding: "12px 10px",
  display: "flex",
  flexDirection: "column" as const,
  gap: 14,
  fontFamily: "var(--ad-font-ui)",
};

const group = { display: "flex", flexDirection: "column" as const, gap: 2 };

const sectionLabel = {
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: "0.06em",
  color: "var(--ad-ink-2)",
  textTransform: "uppercase" as const,
  padding: "0 8px 6px",
};

const addLink = {
  display: "flex",
  alignItems: "center",
  gap: 7,
  minHeight: 28,
  padding: "3px 8px",
  fontSize: 12,
  color: "var(--ad-accent)",
};

const previewTag = {
  marginInlineStart: 6,
  fontSize: 10,
  fontWeight: 600,
  letterSpacing: "0.04em",
  color: "var(--ad-ink-2)",
};

const chromeBar = {
  display: "flex",
  alignItems: "center",
  gap: 8,
  background: "var(--ad-chrome)",
  border: "1px solid var(--ad-line)",
  borderRadius: 10,
  padding: "9px 14px",
};

const tile = {
  display: "flex",
  flexDirection: "column" as const,
  alignItems: "center",
  gap: 8,
  padding: "12px 6px",
  background: "var(--ad-panel-2)",
  border: "1px solid var(--ad-line)",
  borderRadius: 8,
  color: "var(--ad-ink)",
};

const tileName = { fontFamily: "var(--ad-font-mono)", fontSize: 10.5, color: "var(--ad-ink-2)" };

const NAMES = [
  "sidebar",
  "overview",
  "flash",
  "debug",
  "dump",
  "trace",
  "history",
  "automation",
  "settings",
  "jobs",
  "plus",
  "warning",
] as const;

/** 侧栏实景 —— 7 条功能导航各带一枚 glyph,选中行的 glyph 随行取 accent。 */
export const SidebarNavGlyphs = () => (
  <div style={sidebar}>
    <div style={group}>
      <span style={sectionLabel}>设备</span>
      <DeviceRow
        name="DAYU200"
        detail="OpenHarmony 5.0.0.71"
        transport="USB"
        state="ready"
        selected
      />
      <DeviceRow
        name="unknown-tablet"
        detail="未授权 — 点击处理"
        transport="USB"
        state="unauthorized"
      />

    </div>
    <div style={group}>
      <span style={sectionLabel}>功能</span>
      <NavItem icon={<Symbol name="overview" />} label="Overview" />
      <NavItem icon={<Symbol name="flash" />} label="Flash" />
      <NavItem icon={<Symbol name="debug" />} label="Debug" />
      <NavItem icon={<Symbol name="dump" />} label="Viewer" />
      <NavItem icon={<Symbol name="trace" />} label="Trace" />
      <NavItem icon={<Symbol name="history" />} label="History" />
      <NavItem icon={<Symbol name="device" />} label="Device" />
      <NavItem icon={<Symbol name="diagnostics" />} label="Diagnostics" active />
    </div>
  </div>
);

/** 12 枚 glyph 全表 —— 原型 SVG sprite 的完整集合,名字即 `name` 取值。 */
export const GlyphSet = () => (
  <Card title="Symbol — 单色 stroke glyph 全集(name)">
    <div
      style={{
        display: "grid",
        gridTemplateColumns: "repeat(auto-fit, minmax(118px, 1fr))",
        gap: 10,
      }}
    >
      {NAMES.map((n) => (
        <div style={tile} key={n}>
          <Symbol name={n} label={n} />
          <span style={tileName}>{n}</span>
        </div>
      ))}
    </div>
    <p style={hint}>
      与原型 <span style={{ fontFamily: "var(--ad-font-mono)" }}>&lt;defs&gt;</span> sprite
      逐枚对应,库内联而非引用 sprite:组件被放进任意页面时,那份 sprite 不一定存在。
    </p>
  </Card>
);

/** 同一枚 glyph 三处上下文:颜色与尺寸都来自周围文字,无逐处改色。 */
export const ColorFromContext = () => (
  <Card title="stroke: currentColor —— 颜色随上下文">
    <div style={chromeBar}>
      <ToolbarButton iconOnly aria-label="显示或隐藏边栏">
        <Symbol name="sidebar" />
      </ToolbarButton>
      <ToolbarButton iconOnly aria-label="打开设置">
        <Symbol name="settings" />
      </ToolbarButton>
      <ToolbarButton aria-label="显示或隐藏任务检查器">
        <Symbol name="jobs" small />
        <span>任务</span>
      </ToolbarButton>
    </div>
    <div
      style={{
        width: "100%",
        maxWidth: 216,
        background: "var(--ad-panel-2)",
        border: "1px solid var(--ad-line)",
        borderRadius: 10,
        padding: "6px 10px",
      }}
    >
      <NavItem icon={<Symbol name="diagnostics" />} label="Diagnostics" active />
      <NavItem icon={<Symbol name="trace" />} label="Trace" />
    </div>
    <Callout tone="warn" icon={<Symbol name="warning" small />}>
      工具栏取 ink-2、选中导航取 accent、warn callout 取 warn —— 三处都是同一份 SVG。
    </Callout>
    <p style={hint}>
      默认 16px,<span style={{ fontFamily: "var(--ad-font-mono)" }}>small</span>{" "}
      为 14px,用于按钮内与密集行(任务按钮、callout 前导标)。
    </p>
  </Card>
);

/** warnbox 里的 warning glyph —— 严重度不只靠颜色,图形一并承载。 */
export const WarningGlyphInCallout = () => (
  <Card title="Debug · Commands — typed template only · no raw surface">
    <Callout tone="warn" icon={<Symbol name="warning" small />}>
      App 只提交 approved typed template 与 schema-defined inputs。下面的 executable / argv 是
      Provider lowering 的只读预览,不是输入框。
    </Callout>
    <p style={hint}>
      传入 icon 后组件不再画 CSS 默认字符标,glyph 改由 Symbol 提供:它是 SVG,不进入可访问名,也不会被复制走。
    </p>
  </Card>
);
