import { Card, JobInspector } from "@arkdeck/ds";
import type { Job } from "@arkdeck/ds";
import type { ReactNode } from "react";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

/** 840 而非 820:rebind 那行在 820 下会把「中止」挤到第二行,两个决定应当并排。 */
const WIDTH = 840;

const col = {
  width: "100%",
  maxWidth: WIDTH,
  display: "flex",
  flexDirection: "column" as const,
  gap: 12,
};

/** Inspector 是窗口底部的 chrome:它用 --ad-chrome + backdrop-filter,
 *  贴在纯白纸面上会糊掉。给它一块 --ad-ground 桌面和上方的页面内容,
 *  它才读成「停靠条」而不是漂浮卡片。 */
const shell = {
  width: "100%",
  maxWidth: WIDTH,
  background: "var(--ad-ground)",
  border: "1px solid var(--ad-line)",
  borderRadius: 12,
  overflow: "hidden",
  display: "flex",
  flexDirection: "column" as const,
  fontFamily: "var(--ad-font-ui)",
};
const shellBody = { padding: 14, display: "flex", flexDirection: "column" as const, gap: 10 };

const Dock = ({ above, children }: { above?: ReactNode; children: ReactNode }) => (
  <div style={shell}>
    <p style={{ ...hint, padding: 12 }}>组件交互样本：App 已接通精确记录、标准日志与取消请求；本例不连接 Runtime。rebind 确认仍是未接通的历史概念，不得用于续刷或替代身份/覆盖证明。</p>
    {above ? <div style={shellBody}>{above}</div> : null}
    {children}
  </div>
);

const FLASH_PHASES = [
  "准备镜像",
  "进入 Loader",
  "写入镜像",
  "重启并验证",
];

const SIM_PHASES = [
  "Preflight",
  "EnterUpdater",
  "flash boot",
  "注入断连",
  "WaitReconnect",
  "Rebind 确认",
  "reconcile",
  "Complete",
];

const flashRunning = (over: Partial<Job> = {}): Job => ({
  id: "J4",
  title: "Flash · dayu200-openharmony-5.0.0.71.imgpkg · DAYU200",
  state: "running",
  mode: "execute",
  risk: 3,
  phases: FLASH_PHASES,
  currentIndex: 2,
  cancelLabel: "取消(在安全边界)",
  log: ["已获取 CriticalActivityLease(idle sleep 保持)", "→ 进入 Loader", "→ 写入镜像"],
  onCancel: () => {},
  ...over,
});

const DUMP_DONE: Job = {
  id: "J3",
  title: "UI Dump · elementTree · w12 · DAYU200",
  state: "succeeded",
  mode: "execute",
  risk: 2,
  phases: ["Preflight", "WindowInventory", "SnapshotParam", "Capture", "Sidecars", "Receive", "Validate", "RestoreParam", "Complete"],
  currentIndex: 9,
  log: ["完成:raw 产物 hash 已写入 manifest。"],
};

const PLAN_ONLY: Job = {
  id: "J1",
  title: "Flash(plan-only)· dayu200-openharmony-5.0.0.71.imgpkg",
  state: "planned",
  mode: "planOnly",
  risk: 1,
  phases: ["Preflight", "Validate", "makePlan", "Persist plan"],
  currentIndex: 4,
  log: ["完整计划含 1 个 destructive 写入阶段,全部 notExecuted(planned);mutation dispatch = 0。"],
};

const SIM_DONE: Job = {
  id: "J2",
  title: "Flash(simulated)· fixture-a3 断连注入",
  state: "succeeded",
  mode: "simulated",
  fixture: "fixture-a3",
  risk: 3,
  phases: SIM_PHASES,
  currentIndex: 8,
  log: ["完成:reconcile 与注入脚本一致;SIMULATED 标识永久保留。"],
};

const SIM_REBIND: Job = {
  id: "J5",
  title: "Flash(simulated)· fixture-a3 断连注入",
  state: "running",
  mode: "simulated",
  fixture: "fixture-a3",
  risk: 3,
  phases: SIM_PHASES,
  currentIndex: 5,
  rebind: {
    evidence: "同一 serial · binding revision 3→4 · updater 阶段与 plan 一致",
    onConfirm: () => {},
    onAbort: () => {},
  },
  log: ["→ WaitReconnect", "检测到断连后回连:等待用户 rebind 确认(不静默续刷)。"],
};

/** 折叠态 36pt:一行说清「几个在跑、最高风险那个跑到哪」。 */
export const CollapsedFlashRunning = () => (
  <div style={col}>
    <Dock
      above={
        <Card title="Flash · dayu200-openharmony-5.0.0.71.imgpkg">
          <p style={hint}>
            正在写入镜像。任务在页间不中断，离开本页去看 History 时，下方这条依然在。
          </p>
        </Card>
      }
    >
      <JobInspector jobs={[DUMP_DONE, flashRunning()]} open={false} />
    </Dock>
    <Card title="摘要由组件自己算,给不进来">
      <p style={hint}>
        「1 个运行中 — Flash · dayu200-openharmony-5.0.0.71.imgpkg · DAYU200:写入镜像(3/4)」:运行中数量 +
        risk 最高那个任务的当前阶段 i/n。摘要若能与下面的列表打架,还不如不给。
      </p>
      <p style={hint}>
        右侧 indeterminate 条只表示「有任务在动」。字节百分比属于 Flash 页面，并且只在 Runtime
        提供已确认写入量和 materialized 总量时显示。
      </p>
    </Card>
  </div>
);

/** 展开态:最新在上,一个在跑、一个已完成。 */
export const ExpandedNewestFirst = () => (
  <div style={col}>
    <Dock>
      <JobInspector jobs={[DUMP_DONE, flashRunning()]} open height={280} />
    </Dock>
    <Card title="展开态 220–320pt:阶段、日志尾部、以及策略给的取消文案">
      <p style={hint}>
        Inspector 使用阶段序列解释完整 timeline；Flash 页面另以 Runtime byte facts 表达写入估算。
        已完成的任务全绿且没有 accent —— 那是终态，不是丢了当前步。
      </p>
    </Card>
  </div>
);

/** 停在 rebind 上的任务:摆证据,不给结论,也不给取消。 */
export const RebindParked = () => (
  <div style={col}>
    <Dock>
      <JobInspector jobs={[SIM_REBIND]} open height={260} />
    </Dock>
    <Card title="历史 rebind 概念 · 当前 App 不提供确认续刷">
      <p style={hint}>
        当前 App 只读取 Runtime 恢复证据；同一 serial、binding revision 或用户确认都不能
        单独证明安全。原 unknown intent 永不重放，只有 Runtime 的完整机械证明可建立独立恢复。
      </p>
      <p style={hint}>
        它不提供取消:此刻没有任何东西在跑可以取消。折叠条上这台会显示「等待 rebind 确认(6/8)」。
      </p>
    </Card>
  </div>
);

/** 已请求取消 + 临界区:按钮改口成「等待安全边界…」并禁用。 */
export const CancelRequestedCritical = () => (
  <div style={col}>
    <Dock>
      <JobInspector
        jobs={[
          flashRunning({
            cancelRequested: true,
            criticalNote:
              "正在写入镜像 —— 当前分区写入不会被强制中断；取消只停止后续步骤。请勿合盖、手动睡眠、断电或拔线。",
            log: [
              "→ 写入镜像",
              "用户请求取消(策略:atSafeBoundary)",
              "— 已请求取消:等待安全边界 —",
            ],
          }),
        ]}
        open
        height={260}
      />
    </Dock>
    <Card title="取消按钮只说 CancellationPolicy 允许的话">
      <p style={hint}>
        默认文案是「取消(在安全边界)」,不是「取消」;一旦按下就改口成「等待安全边界…」并禁用 ——
        请求已收下,但停下来的时刻由策略定,不由按钮定。
      </p>
      <p style={hint}>
        临界步骤期间额外挂一行红色边注:取消停止的是后续动作,当前这笔写入不会被强杀。
      </p>
    </Card>
  </div>
);

/** plan-only 与 simulated 的徽标跟着任务走,进 History 与导出都不脱落。 */
export const ModeBadgesSurvive = () => (
  <div style={col}>
    <Dock>
      <JobInspector jobs={[PLAN_ONLY, SIM_DONE]} open height={230} />
    </Dock>
    <Card title="没有运行中时,折叠条报「2 个任务(无运行中)」">
      <p style={hint}>
        execute 不带徽标;plan-only 是紫色 ◇ PLANNED,simulated 是橙色 ▤ SIMULATED · fixture-a3。两者都不是「更弱的成功」:plan-only 的 mutation dispatch = 0,simulated 压根没碰真设备。
      </p>
      <p style={hint}>
        徽标在标题、列表、History、详情与导出中永久保留,不因为任务成功就摘掉。
      </p>
    </Card>
  </div>
);
