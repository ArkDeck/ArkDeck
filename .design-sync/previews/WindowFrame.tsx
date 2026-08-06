import {
  Button,
  Callout,
  Card,
  Chip,
  DataTable,
  EffectBadge,
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
              term: "rk3568-dev",
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

export const FlashPlanWindow = () => (
  <div style={{ width: 820 }}>
    <WindowFrame title={TITLE} toolbar={AC}>
      <Card title="Exact Plan · rk3568-5.0-full" action={<Button>查看 plan artifact</Button>}>
        <DataTable
          columns={[
            { key: "n", header: "#", mono: true },
            { key: "step", header: "step", mono: true },
            { key: "args", header: "参数摘要", mono: true },
            { key: "effect", header: "effect" },
          ]}
          rows={[
            {
              id: "1",
              cells: {
                n: "1",
                step: "enterUpdater",
                args: "—",
                effect: <EffectBadge effect="deviceMutation" />,
              },
            },
            {
              id: "2",
              cells: {
                n: "2",
                step: "flashPartition",
                args: "boot · boot.img · 64MB",
                effect: <EffectBadge effect="destructive" />,
              },
            },
            {
              id: "3",
              cells: {
                n: "3",
                step: "flashPartition",
                args: "system · system.img · 2.1GB",
                effect: <EffectBadge effect="destructive" />,
              },
            },
            {
              id: "4",
              cells: {
                n: "4",
                step: "reboot + waitReconnect",
                args: "binding revision + 强证据",
                effect: <EffectBadge effect="deviceMutation" />,
              },
            },
            {
              id: "5",
              cells: {
                n: "5",
                step: "postflight verify",
                args: "版本/设备校验",
                effect: <EffectBadge effect="readOnly" />,
              },
            },
          ]}
        />
        <div style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
          <Button
            variant="danger"
            disabled
            title="required prerequisite flashd 为 unknown,临界步骤前阻断"
          >
            刷写 rk3568-dev(2 个分区)…
          </Button>
          <Chip tone="warn">flashd unknown → 执行分支被阻断</Chip>
        </div>
      </Card>
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
