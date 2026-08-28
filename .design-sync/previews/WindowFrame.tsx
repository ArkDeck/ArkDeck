import {
  Button,
  Callout,
  Card,
  Chip,
  DeterminateProgress,
  KeyValueList,
  WindowFrame,
} from "@arkdeck/ds";

const TITLE = "ArkDeck — OpenHarmony 设备工作台";
const AC = <Button>AC 标注</Button>;

export const OverviewWindow = () => (
  <div style={{ width: 820 }}>
    <WindowFrame title={TITLE} toolbar={AC}>
      <Card title="HDC 工具链" action={<Button>刷新</Button>}>
        <KeyValueList
          items={[
            { term: "来源", description: "DevEco SDK(external)" },
            { term: "路径", description: "/Applications/DevEco-Studio.app/…/toolchains/hdc" },
            {
              term: "client / server",
              description: (
                <>
                  3.1.0e / 3.1.0a <Chip tone="warn">mismatchUnverified</Chip>
                </>
              ),
            },
            { term: "endpoint", description: "127.0.0.1:8710 · ownership: external" },
            { term: "SHA-256", description: "9f31…c2ae · 最近验证 07-13 09:12" },
          ]}
        />
      </Card>
      <Card title="连接与通道保护">
        <KeyValueList
          items={[
            {
              term: "DAYU200",
              description: (
                <>
                  USB · <Chip tone="ok">已授权</Chip> <Chip tone="warn">加密未验证</Chip>
                </>
              ),
            },
            {
              term: "策略",
              description: "无可靠加密证据 → 按未受保护通道处理;设备授权 ≠ 链路机密性",
            },
          ]}
        />
      </Card>
    </WindowFrame>
  </div>
);

export const FlashWorkspaceWriting = () => (
  <div style={{ width: 820 }}>
    <WindowFrame title="ArkDeck — 刷机" toolbar={AC}>
      <div>
        <h1 style={{ margin: 0, fontSize: 20 }}>刷机</h1>
        <p style={{ margin: "4px 0 0", color: "var(--ad-ink-2)", fontSize: 13 }}>
          选择镜像后开始刷机；进行中只突出进度，完成后直接显示结果。
        </p>
      </div>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "10px 12px",
          border: "1px solid var(--ad-line)",
          borderRadius: 8,
        }}
      >
        <b>DAYU200</b>
        <span style={{ flex: 1, color: "var(--ad-ink-2)", fontSize: 12 }}>
          USB · OpenHarmony 5.0.0.71
        </span>
        <Chip tone="ok">✓ 设备已就绪</Chip>
        <span style={{ color: "var(--ad-ink-2)", fontSize: 12 }}>3 项必需安全检查通过</span>
      </div>
      <Card title="正在写入镜像">
        <p style={{ margin: 0, color: "var(--ad-ink-2)", fontSize: 12 }}>
          刷机过程中请勿拔线、断电或合盖。当前分区写入不会被强制中断。
        </p>
        <DeterminateProgress
          label="镜像写入估算"
          value={2_000_000_000}
          max={6_400_000_000}
          valueText="已确认写入 2 GB / 6.4 GB"
        />
        <div style={{ display: "flex", justifyContent: "space-between", fontSize: 12 }}>
          <span style={{ color: "var(--ad-ok)" }}>● 准备</span>
          <b style={{ color: "var(--ad-accent)" }}>● 写入镜像</b>
          <span style={{ color: "var(--ad-ink-2)" }}>○ 重启与验证</span>
        </div>
      </Card>
      <div style={{ color: "var(--ad-ink-2)", fontSize: 12 }}>
        <b style={{ color: "var(--ad-ink)" }}>dayu200-openharmony-5.0.0.71.tar.gz</b> · 6.4 GB
      </div>
      <details style={{ borderTop: "1px solid var(--ad-line)", paddingTop: 10 }}>
        <summary style={{ cursor: "pointer", color: "var(--ad-ink-2)", fontSize: 12 }}>
          查看刷机详情
        </summary>
      </details>
    </WindowFrame>
  </div>
);

export const DeviceAuthWindow = () => (
  <div style={{ width: 720 }}>
    <WindowFrame title={TITLE} toolbar={AC}>
      <Card title="设备授权 — unknown-tablet · 此设备尚未信任本机(E000002)">
        <ol style={{ margin: 0, paddingLeft: 20, fontSize: 13.5, lineHeight: 1.8 }}>
          <li>解锁设备屏幕;</li>
          <li>
            在设备弹出的「是否信任此计算机?」中选择 <b>信任</b> 或 <b>始终信任</b>;
          </li>
          <li>ArkDeck 将自动检测授权结果(有界轮询,不反复弹通知)。</li>
        </ol>
        <Callout tone="warn">
          授权被拒绝或弹窗超时(E000003)。请检查设备的 USB 调试开关后重试。
        </Callout>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
          <Button variant="primary">重试:开始等待授权</Button>
          <Button variant="danger">重启共享 HDC server…</Button>
        </div>
      </Card>
    </WindowFrame>
  </div>
);
