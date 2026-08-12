import { Card, Chip, StageTrack, StatusStrip, WindowFrame } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };

const CELLS = [
  { label: "Runtime task", value: <span style={mono}>HTASK-DEMO-001 · debugCrash</span> },
  { label: "Lifecycle", value: <Chip tone="warn">● running</Chip> },
  { label: "Current stage", value: "patching" },
  { label: "Target binding", value: <span style={mono}>DAYU200 · rev 3</span> },
];

const STAGES = [
  "initializing",
  "reproducing",
  "collecting",
  "analyzing",
  "patching",
  "building",
  "deploying",
  "verifying",
];

const pageTitle = {
  margin: 0,
  fontSize: 19,
  fontWeight: 600,
  display: "flex",
  alignItems: "center",
  gap: 10,
  flexWrap: "wrap" as const,
};

/** Automation 页顶部四格 —— 读别的东西之前先看的四件事。 */
export const AutomationSummary = () => (
  <div style={{ width: "100%", maxWidth: 820 }}>
    <StatusStrip cells={CELLS} />
  </div>
);

/** 页头实景:标题 + 摘要条,发丝线分隔,不做成一排卡片。 */
export const AutomationPageHeader = () => (
  <div style={{ width: "100%", maxWidth: 820 }}>
    <WindowFrame title="ArkDeck — OpenHarmony 设备工作台">
      <h1 style={pageTitle}>Automation</h1>
      <StatusStrip cells={CELLS} />
    </WindowFrame>
  </div>
);

/** Lifecycle 与 Current stage 各占一格 —— 两条正交事实,不合并成一个指示器。 */
export const LifecycleStageOrthogonal = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <StatusStrip cells={CELLS} />
    <Card title="为什么是四格,而不是一个总状态">
      <p style={hint}>
        阶段、lifecycle 与 conditions 是三条正交信息:running 的任务可以停在 patching,
        也可以回退到 analyzing;把它们压成一个指示器就再也读不出「回退」。
      </p>
      <p style={hint}>
        标识性事实放第一格:如本图,窗口够宽时它拿 1.6fr,比其余三格都宽;窄于 980px 时整条折成两列两行,
        顺序不变 —— 先认出「是哪个任务、绑定哪台设备」,再读状态。
      </p>
    </Card>
  </div>
);

/** 页面阅读顺序:摘要条在最上,随后才是目标与阶段。 */
export const PageTopReadingOrder = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <StatusStrip cells={CELLS} />
    <Card title="修复目标">
      <p style={{ ...hint, color: "var(--ad-ink)" }}>
        复现并修复设置页启动后闪退;完成 build、typed HAP deployment 与同一设备复验后才允许成功。
      </p>
      <StageTrack stages={STAGES} currentIndex={4} />
    </Card>
  </div>
);
