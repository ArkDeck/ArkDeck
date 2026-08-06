import { Chip, IndeterminateBar } from "@arkdeck/ds";

const hintStyle = {
  margin: 0,
  fontFamily: "var(--ad-font-ui)",
  fontSize: 12,
  lineHeight: 1.5,
  color: "var(--ad-ink-2)",
} as const;

export const TraceCapturing = () => (
  <div
    style={{
      width: "100%",
      maxWidth: 380,
      background: "var(--ad-panel)",
      border: "1px solid var(--ad-line)",
      borderRadius: 10,
      padding: "14px 16px",
      display: "flex",
      flexDirection: "column",
      gap: 10,
    }}
  >
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <Chip tone="warn">抓取中</Chip>
      <span
        style={{
          fontFamily: "var(--ad-font-ui)",
          fontSize: 12,
          color: "var(--ad-ink-2)",
          whiteSpace: "nowrap",
        }}
      >
        Capturing(6/10)
      </span>
      <span style={{ flex: 1, minWidth: 60, maxWidth: 200 }}>
        <IndeterminateBar label="Trace 抓取中 — Capturing" />
      </span>
    </div>
    <p style={hintStyle}>设备端无可靠字节总量,不显示百分比 —— 只显示阶段与不定进度。</p>
  </div>
);

export const JobDrawerCollapsed = () => (
  <div
    style={{
      width: "100%",
      maxWidth: 620,
      background: "var(--ad-panel-2)",
      borderTop: "1px solid var(--ad-line)",
      borderBottom: "1px solid var(--ad-line)",
      padding: "8px 16px",
      display: "flex",
      alignItems: "center",
      gap: 12,
      fontFamily: "var(--ad-font-ui)",
      fontSize: 12.5,
      color: "var(--ad-ink)",
    }}
  >
    <span aria-hidden="true">▸</span>
    <b>任务</b>
    <span
      style={{
        flex: 1,
        minWidth: 0,
        color: "var(--ad-ink-2)",
        whiteSpace: "nowrap",
        overflow: "hidden",
        textOverflow: "ellipsis",
      }}
    >
      1 个运行中 — Flash · rk3568-5.0-full:flash system(5/9)
    </span>
    <span style={{ width: 200, flex: "none" }}>
      <IndeterminateBar label="Flash · rk3568-5.0-full 运行中" />
    </span>
  </div>
);

export const FlashCriticalSection = () => (
  <div
    style={{
      width: "100%",
      maxWidth: 460,
      background: "var(--ad-panel)",
      border: "1px solid var(--ad-line)",
      borderRadius: 10,
      padding: "14px 16px",
      display: "flex",
      flexDirection: "column",
      gap: 10,
    }}
  >
    <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <Chip tone="warn">运行中</Chip>
      <span
        style={{
          fontFamily: "var(--ad-font-ui)",
          fontSize: 12,
          fontWeight: 600,
          color: "var(--ad-accent)",
          whiteSpace: "nowrap",
        }}
      >
        flash system
      </span>
      <span style={{ flex: 1, minWidth: 60, maxWidth: 240 }}>
        <IndeterminateBar label="正在写入 system 分区" />
      </span>
    </div>
    <p style={hintStyle}>
      正在写入分区 —— 临界区不可中断:取消只会停止后续步骤。请勿合盖、手动睡眠、断电或拔线。
    </p>
  </div>
);
