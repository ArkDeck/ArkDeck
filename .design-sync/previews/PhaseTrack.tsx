import type { ReactNode } from "react";
import { Chip, PhaseTrack } from "@arkdeck/ds";

const jobHead = (title: string, badge: ReactNode) => (
  <div
    style={{
      display: "flex",
      alignItems: "center",
      gap: 8,
      flexWrap: "wrap",
      fontFamily: "var(--ad-font-ui)",
      fontSize: 13,
      fontWeight: 600,
      color: "var(--ad-ink)",
    }}
  >
    <span>{title}</span>
    {badge}
  </div>
);

export const FlashRunning = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 700 }}>
    {jobHead("Flash · dayu200-openharmony-5.0.0.71.tar.gz · DAYU200", <Chip tone="warn">运行中</Chip>)}
    <PhaseTrack
      phases={[
        "准备镜像",
        "进入 Loader",
        "写入镜像",
        "重启并验证",
      ]}
      currentIndex={2}
      running
    />
  </div>
);

export const TraceRunning = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 700 }}>
    {jobHead("Trace · ArkUI 深度 15s · DAYU200", <Chip tone="warn">运行中</Chip>)}
    <PhaseTrack
      phases={[
        "Preflight",
        "SnapshotParams",
        "Configure",
        "Reboot",
        "WaitReconnect",
        "Capturing",
        "Receiving",
        "Validating",
        "Restore",
        "Complete",
      ]}
      currentIndex={5}
      running
    />
  </div>
);

export const UiDumpFinished = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 700 }}>
    {jobHead(
      "UI Dump · elementTree · w12 · DAYU200",
      <Chip tone="ok" icon="✓">
        成功
      </Chip>,
    )}
    <PhaseTrack
      phases={[
        "Preflight",
        "WindowInventory",
        "SnapshotParam",
        "Capture",
        "Sidecars",
        "Receive",
        "Validate",
        "RestoreParam",
        "Complete",
      ]}
      currentIndex={9}
    />
  </div>
);

/** Internal/history-only simulated session; v0.6 does not expose this as a Flash mode switch. */
export const SimulatedInjection = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8, maxWidth: 700 }}>
    {jobHead(
      "Flash(simulated)· fixture-a3 断连注入",
      <Chip tone="simulated" icon="▤">
        SIMULATED · fixture-a3
      </Chip>,
    )}
    <PhaseTrack
      phases={[
        "Preflight",
        "EnterUpdater",
        "flash boot",
        "注入断连",
        "WaitReconnect",
        "Rebind 确认",
        "reconcile",
        "Complete",
      ]}
      currentIndex={5}
      running
    />
  </div>
);
