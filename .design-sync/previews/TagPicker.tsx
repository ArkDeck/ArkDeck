import { Card, Chip, SegmentedControl, TagPicker } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const row = { display: "flex", gap: 14, alignItems: "center", flexWrap: "wrap" as const, fontSize: 13 };

/** 设备已确认支持的 11 个 tag,加上两个只探测到「未报告」的。后者不隐藏。 */
const TAGS = [
  "ace",
  "app",
  "ability",
  "graphic",
  "ohos",
  "sched",
  "freq",
  "sync",
  "binder",
  "disk",
  "workq",
  { value: "distributeddata", unavailable: true, unavailableReason: "设备未报告支持该 tag" },
  { value: "mmc", unavailable: true, unavailableReason: "设备未报告支持该 tag" },
];

/** ArkUI 深度 preset 的 8 个 tag。 */
const ARKUI_DEEP = ["ace", "app", "ability", "graphic", "ohos", "sched", "freq", "sync"];

const ALL_CONFIRMED = [
  "ace",
  "app",
  "ability",
  "graphic",
  "ohos",
  "sched",
  "freq",
  "sync",
  "binder",
  "disk",
  "workq",
];

/** 一格里同时看见三态:已选(accent 实线)、可选未选(灰实线)、未确认(虚线禁用)。 */
export const CustomTagPicker = () => (
  <div style={{ width: "100%", maxWidth: 600 }}>
    <Card title="抓取配置 · 自定义 tag">
      <p style={hint}>
        仅设备已确认支持的 tag 可选(能力探测 tag×11);未确认的 tag 禁用并标注原因,不猜测。
      </p>
      <TagPicker label="Trace tags" options={TAGS} selected={ARKUI_DEEP} />
      <p style={hint}>已选 8 个 tag。</p>
    </Card>
  </div>
);

/** Trace 抓取配置卡的实景:Preset / 自定义 tag 分段、tag 面板、duration、buffer 与工具来源。 */
export const TraceCaptureConfig = () => (
  <div style={{ width: "100%", maxWidth: 640 }}>
    <Card
      title="抓取配置"
      action={
        <SegmentedControl
          size="sm"
          label="tag 选择方式"
          value="custom"
          options={[
            { value: "preset", label: "Preset" },
            { value: "custom", label: "自定义 tag" },
          ]}
        />
      }
    >
      <p style={hint}>
        仅设备已确认支持的 tag 可选(能力探测 tag×11);未确认的 tag 禁用并标注原因,不猜测。
      </p>
      <TagPicker label="Trace tags" options={TAGS} selected={ARKUI_DEEP} />
      <p style={hint}>已选 8 个 tag。</p>
      <div style={row}>
        <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
          duration
          <SegmentedControl
            size="sm"
            label="duration"
            value="15"
            options={[
              { value: "10", label: "10s" },
              { value: "15", label: "15s" },
              { value: "30", label: "30s" },
            ]}
          />
        </span>
        <span>
          buffer <b>307200</b>
        </span>
        <Chip tone="dim">工具:hitrace(设备已确认)</Chip>
      </div>
    </Card>
  </div>
);

/** 全选:11 个已确认的 tag 全部点亮,那两个未确认的仍旧是虚线禁用 —— 全选也够不到。 */
export const AllConfirmedSelected = () => (
  <div style={{ width: "100%", maxWidth: 600 }}>
    <Card title="抓取配置 · 全景(11 tags)">
      <TagPicker label="Trace tags" options={TAGS} selected={ALL_CONFIRMED} />
      <p style={hint}>已选 11 个 tag。</p>
      <p style={hint}>
        {"选满也只到 11:distributeddata 与 mmc 不在「未选」里,而在「未确认」里 —— 两者的差别正是这个控件存在的理由。"}
      </p>
    </Card>
  </div>
);

/** 只剩一个 tag 的下限态,并把 hover 才可见的禁用原因写成正文,截图里也能读到。 */
export const UnconfirmedNotHidden = () => (
  <div style={{ width: "100%", maxWidth: 600 }}>
    <Card title="未确认 ≠ 不存在">
      <TagPicker label="Trace tags" options={TAGS} selected={["ace"]} />
      <p style={hint}>已选 1 个 tag。</p>
      <p style={hint}>
        {"distributeddata 与 mmc 保持可见但禁用、边框为虚线,hover 给出原因「设备未报告支持该 tag」。把它们藏起来会让人以为该 tag 不存在,而真正发生的是 ArkDeck 没能确认它。"}
      </p>
      <p style={hint}>{"最后一个 tag 取消不掉:已选数为 1 时 toggle 不再移除,抓取始终至少带一个 tag。"}</p>
    </Card>
  </div>
);
