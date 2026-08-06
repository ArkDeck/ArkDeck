import { NavItem } from "@arkdeck/ds";

const sidebar = {
  width: 200,
  background: "var(--ad-panel-2)",
  border: "1px solid var(--ad-line)",
  borderRadius: 10,
  padding: "12px 10px",
  display: "flex",
  flexDirection: "column" as const,
  gap: 2,
};

const sectionLabel = {
  fontFamily: "var(--ad-font-ui)",
  fontSize: 11,
  fontWeight: 600,
  letterSpacing: "0.06em",
  color: "var(--ad-ink-2)",
  textTransform: "uppercase" as const,
  padding: "0 8px 6px",
};

/** 侧栏功能导航全表 —— 选中行是整个侧栏里唯一使用 accent 的元素。 */
export const SidebarNav = () => (
  <div style={sidebar}>
    <span style={sectionLabel}>功能</span>
    <NavItem icon="◎" label="Overview" />
    <NavItem icon="⚡" label="Flash" active />
    <NavItem icon="🐞" label="Debug" />
    <NavItem icon="🌲" label="UI Dump" />
    <NavItem icon="📈" label="Trace" />
    <NavItem icon="🗂" label="History" />
    <NavItem icon="⚙" label="Settings" />
  </div>
);

/** 同一行的选中/未选中对照:accent 底色 + 字重,图标列宽度固定不跳。 */
export const ActiveVsInactive = () => (
  <div style={{ display: "flex", gap: 16, alignItems: "flex-start" }}>
    <div style={{ width: 180 }}>
      <NavItem icon="🗂" label="History" active />
    </div>
    <div style={{ width: 180 }}>
      <NavItem icon="🗂" label="History" />
    </div>
  </div>
);

/** History 停留态 —— 导航切页不改变目标设备,也不改变正在运行的任务。 */
export const SidebarNavOnHistory = () => (
  <div style={sidebar}>
    <span style={sectionLabel}>功能</span>
    <NavItem icon="◎" label="Overview" />
    <NavItem icon="⚡" label="Flash" />
    <NavItem icon="🐞" label="Debug" />
    <NavItem icon="🌲" label="UI Dump" />
    <NavItem icon="📈" label="Trace" />
    <NavItem icon="🗂" label="History" active />
    <NavItem icon="⚙" label="Settings" />
  </div>
);
