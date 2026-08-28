import { useState } from "react";
import { Button, Callout, Card, RecoveryBanner } from "@arkdeck/ds";
import type { RecoveryItem } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

const col = {
  width: "100%",
  maxWidth: 820,
  display: "flex",
  flexDirection: "column" as const,
  gap: 12,
};

/** 历史概念输入，不是当前 App 的操作或 Runtime 事实。 */
const FLASH_DETAIL = (
  <>
    上次会话在「Flash Steps · flashPartition(system)」写入 intent 后异常退出,未记录 outcome。设备最后处于 updater 模式。
    <br />
    原 unknown intent 永不重放；只有 Runtime 证明完整覆盖后才可执行独立恢复，人工确认不能代替证明。
  </>
);

/** 归档被拒时不传 onArchive:按钮本来就 disabled,再挂回调只会骗到读代码的人。 */
const flashUnknown = (archiveBlockedReason?: string): RecoveryItem => ({
  kind: "outcomeUnknown",
  title: "Flash · DAYU200 · system 分区",
  detail: FLASH_DETAIL,
  onGuide: () => {},
  onArchive: archiveBlockedReason ? undefined : () => {},
  archiveBlockedReason,
});

/** 原型第二项。剩余时间从正文里挪进 remaining —— DS 把它渲染成右侧 chip。 */
const TRACE_WAITING: RecoveryItem = {
  kind: "waiting",
  title: "Trace · DAYU200",
  detail: "等待设备重启回连。回连后自动继续参数恢复。",
  remaining: "04:12",
};

const DUMP_RESUME: RecoveryItem = {
  kind: "resumeSafe",
  title: "UI Dump · elementTree · w12 · DAYU200",
  detail:
    "上次会话停在 RestoreParam 之前退出:参数快照完整,persist.ace.debug.enabled 仍停在临时开启值。Provider 声明该步骤 restartSafe,可原地重放。",
  resumeLabel: "从 RestoreParam 继续",
  onResume: () => {},
  onArchive: () => {},
};

/** Harness 被人挡住:reasonCode 取自设备授权页的 E000003,最小动作即该页的信任流程。 */
const AUTH_BLOCKED: RecoveryItem = {
  kind: "humanRequired",
  title: "Automation · HTASK-DEMO-001 · unknown-tablet",
  detail:
    "typed HAP deployment 需要一台已授权设备。unknown-tablet 的授权等待超时（不等同于 denied）,ArkDeck 不自动重试。",
  reasonCode: "E000003",
  minimalAction:
    "解锁设备屏幕,在设备弹出的「是否信任此计算机?」中选择「信任」或「始终信任」;若重试无效,再检查设备的 USB 调试开关。",
  resumesAtStage: "deploying",
  onDone: () => {},
};

const CURRENT_RECORDS = [
  { id: "unknown", title: "设备影响未知", detail: "条件允许时请保持设备状态不变。在通过已批准的 Runtime 路径核对未决影响前，不要开始其他设备操作。" },
  { id: "human", title: "需要人工处理", detail: "请先检查已记录的原因和证据，再通过已批准的 Runtime 路径继续。" },
  { id: "safe", title: "已有安全恢复边界", detail: "Runtime 已记录确认过的安全边界。请先检查记录，再通过已批准的 Runtime 路径恢复。" },
  { id: "archive", title: "恢复归档正在等待", detail: "Runtime 正在等待安全边界，之后才能完成恢复记录；此 App 不能强制停止当前步骤。" },
  { id: "waiting", title: "恢复正在等待", detail: "请保持设备当前状态不变，并在 Runtime 记录中检查所需的恢复步骤。" },
];

/** 当前 App surface。示例点击仅选择精确来源，不调用 Runtime 或创建设备 Job。 */
export const SessionBanner = () => {
  const [selectedJob, setSelectedJob] = useState<string | null>(null);
  return <div style={col}>
    <p style={hint}>当前实现 · 演示记录。恢复区最多占 detail 可用高度的 45%，同时为工作区预留 400pt；空间更小时在 45% 上限内保留 96pt 滚动视口。多条显示总数，单条按内容收缩；此独立预览以 300px 示意。独立 Settings/Trace Viewer 不显示。每个动作仅打开对应 Job 的 History 并清除旧筛选；没有恢复、重试或归档动作。</p>
    <div role="region" aria-label="恢复记录" tabIndex={0} style={{ maxHeight: 300, overflowY: "auto", display: "grid", gap: 8 }}>
    <p style={hint}>5 条记录待检查</p>
    {CURRENT_RECORDS.map(record => {
      const jobID = `job-demo-recovery-${record.id}`;
      return <Callout key={jobID} tone="warn">
        <b>{record.title}</b><p>{record.detail}</p>
        <p className="ad-mono">{jobID} · target-demo-{record.id}</p>
        <Button onClick={() => setSelectedJob(jobID)}>在历史记录中检查</Button>
      </Callout>;
    })}
    </div>
    {selectedJob ? <Card title="精确 History 来源（仅演示）">
      <p className="ad-mono">{selectedJob}</p><p style={hint}>没有提交、恢复或改变原 Job outcome；完整双语交互见 prototype.html 的 recovery=mixed。</p>
    </Card> : null}
  </div>;
};

/** 四种 kind 同框,按「现在就需要人」递减排列。 */
export const AllFourKinds = () => (
  <div style={col}>
    <p style={hint}>历史组件示例：当前 App banner 只打开 History，不提供 resume/archive；内置 Harness/task.* 已退役。确认不能覆盖未知 destructive outcome。</p>
    <RecoveryBanner items={[flashUnknown(), AUTH_BLOCKED, DUMP_RESUME, TRACE_WAITING]} />
    <Card title="四种 kind 的动作面各不相同">
      <p style={hint}>
        outcomeUnknown 只有恢复指引与归档;humanRequired 摊开 reasonCode / 需要你做 / 之后回到;
        resumeSafe 才有具名续跑按钮;waiting 没有任何按钮,只剩一枚剩余时间 chip —— 它没有被人挡住。
      </p>
    </Card>
  </div>
);

/** outcomeUnknown:没有任何看起来可以继续的主按钮,连回调都没处传。 */
export const OutcomeUnknownNoResume = () => (
  <div style={col}>
    <p style={hint}>历史组件示例：当前 App banner 只打开 History，不提供 resume/archive；内置 Harness/task.* 已退役。确认不能覆盖未知 destructive outcome。</p>
    <RecoveryBanner items={[flashUnknown()]} />
    <Card title="规格 §4.2:这里不渲染任何像是可续跑的东西">
      <p style={hint}>
        intent 已写、outcome 未记 —— 包括 ArkDeck 在内没人知道设备做了什么。所以该 kind 在类型上就没有 resume 回调可传,只有 Provider 的 RecoveryGuide 与显式归档。
      </p>
      <p style={hint}>
        归档按 danger 描边:它只停止 ArkDeck 的跟踪,不会证明设备已恢复正常、不会停止可能仍在设备上运行的远端任务、不会回滚已改的 persist.* 参数。归档后该 Session 永久保留 outcomeUnknown 与
        needsAttention 标记,与其冲突的新任务将被 preflight 阻断。
      </p>
    </Card>
  </div>
);

/** humanRequired:三行事实块,不给笼统的「继续」。 */
export const HumanRequiredBlock = () => (
  <div style={col}>
    <p style={hint}>历史组件示例：当前 App banner 只打开 History，不提供 resume/archive；内置 Harness/task.* 已退役。确认不能覆盖未知 destructive outcome。</p>
    <RecoveryBanner items={[AUTH_BLOCKED]} />
    <Card title="被人挡住时,要说清哪一步、做什么、之后回到哪">
      <p style={hint}>
        reasonCode 是机器可读的 block(E000003 = 授权等待超时（不等同于 denied）);「需要你做」是最小人工动作,
        不是一句「请检查设备」;「之后回到」写明恢复到的 stage,让人知道自己按下按钮会发生什么。
      </p>
      <p style={hint}>按钮写「我已完成上述动作」,而不是「继续」—— 人只能为自己做过的事作证。</p>
    </Card>
  </div>
);

/** 归档被拒:按钮 disabled 且带原因;waiting 项同时说明为什么还在等。 */
export const ArchiveBlocked = () => (
  <div style={col}>
    <p style={hint}>历史组件示例：当前 App banner 只打开 History，不提供 resume/archive；内置 Harness/task.* 已退役。确认不能覆盖未知 destructive outcome。</p>
    <RecoveryBanner items={[flashUnknown("仍在等待窗口内,归档不可用"), TRACE_WAITING]} />
    <Card title="critical child 未到安全边界时,归档被拒并说明原因">
      <p style={hint}>
        第一条的「结束恢复并归档…」为 0.45 不透明度的禁用态,原因串「仍在等待窗口内,归档不可用」挂在
        title 上 —— 悬停才出现,截图里看不到,读代码可核对。
      </p>
      <p style={hint}>
        第二条给出还在等什么:有界等待窗口内没有人该做的事,所以它一个按钮都不提供,只报剩余 04:12。
      </p>
    </Card>
  </div>
);
