import { Button, Card, Chip, DataTable, KeyValueList } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };

export const HdcToolchain = () => (
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
    <p style={hint}>
      版本字符串不一致:只读能力已探测降级可用;Flash 需命中已验证组合。ArkDeck 不会自动重启 external server。
    </p>
  </Card>
);

export const ChannelProtection = () => (
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
    <p style={hint}>authorized 与 encrypted 分离展示:无加密证据即按未保护通道处理,不因已授权而放宽。</p>
  </Card>
);

export const CapabilityMatrix = () => (
  <Card title="能力矩阵(rk3568-dev)" action={<Button>查看 raw</Button>}>
    <DataTable
      columns={[
        { key: "cap", header: "能力" },
        { key: "state", header: "状态" },
        { key: "evidence", header: "探测证据", mono: true },
      ]}
      rows={[
        {
          id: "hidumper",
          cells: {
            cap: "hidumper",
            state: <Chip tone="ok">可用</Chip>,
            evidence: "-w/-element/-lastpage 已确认",
          },
        },
        {
          id: "hitrace",
          cells: {
            cap: "hitrace",
            state: <Chip tone="ok">可用</Chip>,
            evidence: "tag×11 · buffer ≤ 307200",
          },
        },
        {
          id: "bytrace",
          cells: { cap: "bytrace", state: <Chip tone="dim">不存在</Chip>, evidence: "—" },
        },
        {
          id: "flashd",
          cells: {
            cap: "flashd",
            state: <Chip tone="warn">无法确认</Chip>,
            evidence: "exit 127 · 仅 updater 模式提供",
          },
        },
      ]}
    />
    <p style={hint}>
      unknown 不折叠成「不存在」:ArkDeck 不从缺失推断,能力保持「无法确认」直到升级模式实测。
    </p>
  </Card>
);

export const FlashPrerequisites = () => (
  <Card title="Prerequisites" action={<Button>重新检查</Button>}>
    <DataTable
      columns={[
        { key: "req", header: "前置条件" },
        { key: "state", header: "状态" },
        { key: "note", header: "未满足时的处置" },
      ]}
      rows={[
        {
          id: "root",
          cells: { req: "root-capable build", state: <Chip tone="ok">satisfied</Chip>, note: "—" },
        },
        {
          id: "updater",
          cells: { req: "进入 updater", state: <Chip tone="ok">satisfied</Chip>, note: "—" },
        },
        {
          id: "flashd",
          cells: {
            req: "flashd 能力",
            state: <Chip tone="warn">unknown</Chip>,
            note: "required 未满足 → Execute 按钮禁用并指向原因(AC-FLASH-002-01)",
          },
        },
        {
          id: "power",
          cells: { req: "稳定供电", state: <Chip tone="ok">satisfied</Chip>, note: "—" },
        },
      ]}
    />
  </Card>
);
