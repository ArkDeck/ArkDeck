import type { ReactNode } from "react";
import { DeviceRow } from "@arkdeck/ds";

const sidebar = (children: ReactNode) => (
  <div
    style={{
      width: 230,
      background: "var(--ad-panel-2)",
      border: "1px solid var(--ad-line)",
      borderRadius: 10,
      padding: "10px 10px",
      display: "flex",
      flexDirection: "column",
      gap: 2,
    }}
  >
    {children}
  </div>
);

export const SidebarList = () =>
  sidebar(
    <>
      <div
        style={{
          fontFamily: "var(--ad-font-ui)",
          fontSize: 11,
          fontWeight: 600,
          letterSpacing: "0.06em",
          color: "var(--ad-ink-2)",
          textTransform: "uppercase",
          padding: "0 8px 4px",
        }}
      >
        设备
      </div>
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
      <DeviceRow
        name="192.168.1.30:8710"
        detail="未连接 — 等待首次确认"
        transport="TCP"
        state="offline"
      />
    </>,
  );

export const ReadySelected = () =>
  sidebar(
    <DeviceRow
      name="DAYU200"
      detail="OpenHarmony 5.0.0.71"
      transport="USB"
      state="ready"
      selected
    />,
  );

export const Unauthorized = () =>
  sidebar(
    <DeviceRow
      name="unknown-tablet"
      detail="未授权 — 点击处理"
      transport="USB"
      state="unauthorized"
    />,
  );

export const OfflineTcpTarget = () =>
  sidebar(
    <DeviceRow
      name="192.168.1.30:8710"
      detail="未连接 — 等待首次确认"
      transport="TCP"
      state="offline"
    />,
  );
