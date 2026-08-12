import { Card, DeterminateProgress } from "@arkdeck/ds";

const hint = {
  margin: 0,
  color: "var(--ad-ink-2)",
  fontFamily: "var(--ad-font-ui)",
  fontSize: 12,
  lineHeight: 1.5,
} as const;

/** v0.6 Flash writing state: the ratio is confirmed bytes / materialized write total. */
export const FlashImageWrite = () => (
  <Card title="正在写入镜像">
    <DeterminateProgress
      label="镜像写入估算"
      value={2_000_000_000}
      max={6_400_000_000}
      valueText="已确认写入 2 GB / 6.4 GB"
    />
    <p style={hint}>只度量镜像写入；达到 100% 后仍需重启并验证，不能提前显示刷机成功。</p>
  </Card>
);

/** Values outside the Runtime-owned denominator are clamped instead of overflowing. */
export const CompletedWriteAwaitingVerification = () => (
  <Card title="写入完成，正在重启并验证">
    <DeterminateProgress
      label="镜像写入估算"
      value={6_400_000_000}
      max={6_400_000_000}
      valueText="已确认写入 6.4 GB / 6.4 GB"
    />
    <p style={hint}>100% 是写入事实，不是 Job 成功；postflight 未完成前保持运行态。</p>
  </Card>
);
