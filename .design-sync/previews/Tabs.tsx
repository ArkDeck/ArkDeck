import { Tabs } from "@arkdeck/ds";

const DEBUG_TABS = [
  { value: "logs", label: "Logs" },
  { value: "apps", label: "Apps" },
  { value: "net", label: "Network" },
  { value: "cmd", label: "Commands" },
];

/** Debug 工作台默认 tab:等级/tag 过滤、暂停界面、host 分片轮转状态。 */
export const DebugLogs = () => (
  <Tabs label="Debug 工作台" tabs={DEBUG_TABS} value="logs" />
);

/** Apps:已安装包、运行状态与 pid。 */
export const DebugApps = () => (
  <Tabs label="Debug 工作台" tabs={DEBUG_TABS} value="apps" />
);

/** Network:forward 列表的增删。 */
export const DebugNetwork = () => (
  <Tabs label="Debug 工作台" tabs={DEBUG_TABS} value="net" />
);

/** Commands:模板 + 精确命令回显 + 退出码。 */
export const DebugCommands = () => (
  <Tabs label="Debug 工作台" tabs={DEBUG_TABS} value="cmd" />
);

/** 切 tab 只换视图 —— 每个工作区自己的显式目标不随之改变。 */
export const TabBarInPanel = () => (
  <div
    style={{
      background: "var(--ad-panel)",
      border: "1px solid var(--ad-line)",
      borderRadius: 10,
      padding: "12px 16px 16px",
      display: "flex",
      flexDirection: "column",
      gap: 12,
      minWidth: 380,
    }}
  >
    <Tabs label="Debug 工作台" tabs={DEBUG_TABS} value="net" />
    <span
      style={{
        fontFamily: "var(--ad-font-mono)",
        fontSize: 11.5,
        color: "var(--ad-ink-2)",
      }}
    >
      tcp:9222 → tcp:9222 · DAYU200
    </span>
  </div>
);
