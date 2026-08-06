import { Card, Chip, PhaseTrack, StageTrack } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const goal = { margin: 0, fontSize: 13, lineHeight: 1.6, color: "var(--ad-ink)" };

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

/** Automation 的「修复目标」卡:目标一句话,随后是任务声明的八个阶段。 */
export const RepairGoal = () => (
  <div style={{ width: "100%", maxWidth: 820 }}>
    <Card title="修复目标">
      <p style={goal}>
        复现并修复设置页启动后闪退;完成 build、typed HAP deployment 与同一设备复验后才允许成功。
      </p>
      <StageTrack stages={STAGES} currentIndex={4} />
      <p style={hint}>
        阶段、lifecycle 与 conditions 是三条正交信息;回退到 analyzing 不会被画成新的成功阶段。
      </p>
    </Card>
  </div>
);

/** 回退是合法迁移:同一条轨,当前标记退回 analyzing,不追加节点。 */
export const BackToAnalyzing = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <Card title="修复目标" action={<Chip tone="warn">● running</Chip>}>
      <StageTrack stages={STAGES} currentIndex={3} />
      <p style={hint}>
        verifying 未通过后任务退回 analyzing:阶段序列不变,只是当前标记回到第 4 个节点。
      </p>
      <p style={hint}>
        既不追加一个「重试」节点,也不把已走过的阶段抹掉 —— 回退本身就是被允许的迁移。
      </p>
    </Card>
  </div>
);

/** 起跑前:currentIndex = -1,八个阶段全部未达,没有任何节点被点亮。 */
export const BeforeTaskStarts = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <Card title="修复目标" action={<Chip tone="dim">尚未开始</Chip>}>
      <StageTrack stages={STAGES} currentIndex={-1} />
      <p style={hint}>
        任务已声明阶段但还未进入第一个:先把要走的路摊开,再开始走。没有「正在进行」的绿点或 accent 点。
      </p>
    </Card>
  </div>
);

/** 与 PhaseTrack 不可互换:一个是任务生命周期,一个是单个 Job 的执行阶段。 */
export const NotAPhaseTrack = () => (
  <div style={{ width: "100%", maxWidth: 820, display: "flex", flexDirection: "column", gap: 12 }}>
    <Card title="StageTrack — HarnessTask 声明的阶段(可回退)">
      <StageTrack stages={STAGES} currentIndex={4} />
    </Card>
    <Card title="PhaseTrack — 单个 Job 的执行阶段(只前进)">
      <PhaseTrack
        phases={[
          "Preflight",
          "EnterUpdater",
          "Re-identify",
          "flash boot",
          "flash system",
          "Verify",
          "Reboot",
          "Postflight",
          "Complete",
        ]}
        currentIndex={4}
        running
      />
      <p style={hint}>
        上面那条画的是阶段之间的连接,任务可以沿它往回走;下面这条是一次 Job
        的相邻药丸,跑完即止。选错会让读者以为任务能倒着执行,或者 Job 可以重来。
      </p>
    </Card>
  </div>
);
