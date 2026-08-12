import { Chip, KeyValueList } from "@arkdeck/ds";

export const HdcToolchain = () => (
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
);

export const ChannelProtection = () => (
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
);

export const PostflightVerify = () => (
  <KeyValueList
    items={[
      {
        term: "设备回报 build",
        description: (
          <>
            OpenHarmony 5.0.0.71 <Chip tone="ok">= 镜像期望 ✓</Chip>
          </>
        ),
      },
      { term: "设备身份", description: "同一稳定身份 · binding revision 3→3" },
    ]}
  />
);

export const OutputAndRetention = () => (
  <KeyValueList
    items={[
      { term: "输出根目录", description: "~/Library/Application Support/ArkDeck" },
      { term: "历史配额", description: "20GB · 保留 90 天 · pinned 除外" },
      { term: "当前占用", description: "6.4GB · 42 个 Session · 3 pinned" },
    ]}
  />
);
