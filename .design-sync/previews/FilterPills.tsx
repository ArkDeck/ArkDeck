import { FilterPills } from "@arkdeck/ds";

const STATUS = [
  { value: "all", label: "全部" },
  { value: "succeeded", label: "成功" },
  { value: "failed", label: "失败" },
  { value: "cancelled", label: "已取消" },
  { value: "planned", label: "planned" },
  { value: "interrupted", label: "已中断" },
];

const MODE = [
  { value: "all", label: "全部" },
  { value: "execute", label: "execute" },
  { value: "planOnly", label: "plan-only" },
  { value: "simulated", label: "simulated" },
];

const DEVICE = [
  { value: "all", label: "全部" },
  { value: "rk3568-dev", label: "rk3568-dev" },
  { value: "SIM-fixture-a3", label: "SIM-fixture-a3" },
];

/** History 状态维度 — interrupted 与 failed 是可分的两种终态,不是同一个「没成功」。 */
export const HistoryStatusFilter = () => (
  <FilterPills label="状态" options={STATUS} value="interrupted" />
);

/** History 模式维度 — plan-only / simulated 的标识在历史里永久保留,所以能被单独筛出来。 */
export const HistoryModeFilter = () => (
  <FilterPills label="模式" options={MODE} value="simulated" />
);

/** History 设备维度 — 模拟 fixture 与真实设备并列,选中项即当前作用域。 */
export const HistoryDeviceFilter = () => (
  <FilterPills label="设备" options={DEVICE} value="rk3568-dev" />
);

/** 三个维度叠成一张过滤卡:当前组合应当能被当成一句话读出来。 */
export const HistoryFilterStack = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
    <FilterPills label="状态" options={STATUS} value="failed" />
    <FilterPills label="模式" options={MODE} value="execute" />
    <FilterPills label="设备" options={DEVICE} value="rk3568-dev" />
  </div>
);
