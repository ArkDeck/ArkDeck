import {
  Button,
  Card,
  Chip,
  StatusStrip,
  Symbol,
  ToolbarButton,
  WindowFrame,
} from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };

const TITLE = "ArkDeck — OpenHarmony 设备工作台";

/** 标题栏尾部四枚控件,与原型逐一对应。 */
const Trailing = () => (
  <>
    <ToolbarButton iconOnly aria-label="打开设置" title="设置(原型中内嵌展示)">
      <Symbol name="settings" />
    </ToolbarButton>
    <ToolbarButton title="仅原型评审使用">系统外观</ToolbarButton>
    <ToolbarButton aria-label="显示或隐藏任务检查器">
      <Symbol name="jobs" small />
      <span>任务</span>
    </ToolbarButton>
    <ToolbarButton>AC 标注</ToolbarButton>
  </>
);

const chromeBar = {
  display: "flex",
  alignItems: "center",
  gap: 10,
  background: "var(--ad-chrome)",
  border: "1px solid var(--ad-line)",
  borderRadius: 10,
  padding: "9px 14px",
  fontFamily: "var(--ad-font-ui)",
};

const barTitle = {
  flex: 1,
  textAlign: "center" as const,
  fontSize: 13,
  fontWeight: 600,
  color: "var(--ad-ink-2)",
};

const caption = {
  fontSize: 11,
  color: "var(--ad-ink-2)",
  fontFamily: "var(--ad-font-mono)",
  textAlign: "center" as const,
};

/** 真实栖息地:统一工具栏。28px 半透明控件贴在 chrome 上,不落在内容区。 */
export const UnifiedTitlebar = () => (
  <div style={{ width: "100%", maxWidth: 800 }}>
    <WindowFrame title={TITLE} toolbar={<Trailing />}>
      <StatusStrip
        cells={[
          { label: "Runtime task", value: <span style={mono}>HTASK-DEMO-001 · debugCrash</span> },
          { label: "Lifecycle", value: <Chip tone="warn">● running</Chip> },
          { label: "Current stage", value: "patching" },
          { label: "Target binding", value: <span style={mono}>DAYU200 · rev 3</span> },
        ]}
      />
    </WindowFrame>
  </div>
);

/** 首尾两组:左侧边栏开关,右侧设置 / 外观 / 任务 / AC 标注。 */
export const LeadingAndTrailingGroups = () => (
  <div style={{ width: "100%", maxWidth: 800, display: "flex", flexDirection: "column", gap: 12 }}>
    <div style={chromeBar}>
      <ToolbarButton iconOnly aria-label="显示或隐藏边栏" title="显示或隐藏边栏">
        <Symbol name="sidebar" />
      </ToolbarButton>
      <div style={barTitle}>{TITLE}</div>
      <Trailing />
    </div>
    <Card title="工具栏控件的位置约定">
      <p style={hint}>
        边栏开关在 leading 组,与窗口红黄绿灯同侧;设置、外观、任务检查器与 AC
        标注在 trailing 组。工具栏只放窗口级动作,页面动作留在内容区。
      </p>
    </Card>
  </div>
);

/** 三种形态:iconOnly 为 28×28 正方,带文字的按左右 9px 内边距展开。 */
export const IconOnlyVsLabeled = () => (
  <div style={{ width: "100%", maxWidth: 620, display: "flex", flexDirection: "column", gap: 12 }}>
    <div style={{ ...chromeBar, gap: 22, justifyContent: "center", padding: "14px" }}>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
        <ToolbarButton iconOnly aria-label="显示或隐藏边栏">
          <Symbol name="sidebar" />
        </ToolbarButton>
        <span style={caption}>iconOnly</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
        <ToolbarButton>系统外观</ToolbarButton>
        <span style={caption}>label</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
        <ToolbarButton aria-label="显示或隐藏任务检查器">
          <Symbol name="jobs" small />
          <span>任务</span>
        </ToolbarButton>
        <span style={caption}>symbol + label</span>
      </div>
    </div>
    <Card title="iconOnly 必须自带 aria-label">
      <p style={hint}>
        只有图形的按钮没有可访问名,glyph 本身是 aria-hidden 的装饰;边栏开关的名字是「显示或隐藏边栏」,
        由 <span style={mono}>aria-label</span> 提供。
      </p>
    </Card>
  </div>
);

/** chrome 与 content 的分工:同一句话,一个在工具栏、一个在卡片里。 */
export const ChromeNotContent = () => (
  <div style={{ width: "100%", maxWidth: 640, display: "flex", flexDirection: "column", gap: 12 }}>
    <div style={chromeBar}>
      <ToolbarButton iconOnly aria-label="显示或隐藏边栏">
        <Symbol name="sidebar" />
      </ToolbarButton>
      <div style={barTitle}>{TITLE}</div>
      <ToolbarButton>AC 标注</ToolbarButton>
    </div>
    <Card title="诊断" action={<Button>导出诊断包…</Button>}>
      <p style={hint}>
        工具栏控件高 28px、半透明,读作窗口外壳;内容区的动作用 Button —— 它更高、有实心边框,
        并能取 primary / danger 变体。两者不可互换。
      </p>
    </Card>
  </div>
);
