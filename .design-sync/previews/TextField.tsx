import { Button, Card, Chip, SegmentedControl, Select, TextField } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };
const row = { display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" as const };
const foot = { display: "flex", gap: 8, justifyContent: "flex-end" };
const inline = { fontSize: 12.5, color: "var(--ad-ink-2)" };

/** 「添加 TCP / UART 目标」对话框:传输方式 Select + 地址 mono 输入,展示 placeholder 态。 */
export const AddTargetAddress = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="添加 TCP / UART 目标">
      <p style={hint}>
        ArkDeck 不扫描网络,目标只能由你显式添加;断线后需按规格 §5.1 重新确认身份,不做静默重绑。
      </p>
      <div style={row}>
        <Select options={["TCP", "UART"]} defaultValue="TCP" aria-label="目标类型" />
        <TextField
          mono
          aria-label="目标地址"
          placeholder="192.168.1.30:8710 或 /dev/tty.usbserial-1420"
          style={{ flex: 1, minWidth: 260 }}
        />
      </div>
      <div style={foot}>
        <Button>取消</Button>
        <Button variant="primary">添加目标</Button>
      </div>
    </Card>
  </div>
);

/** UI Dump 的 compId 字段:只接受数字的窄 mono 输入,右上角命令随输入实时改写。 */
export const CompIdField = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card
      title="Recipe"
      action={
        <span style={{ ...mono, fontSize: 12, color: "var(--ad-accent)" }}>
          -w 12 -element -lastpage 33
        </span>
      }
    >
      <div style={{ ...row, fontSize: 12.5 }}>
        <span style={inline}>compId(安全手输,只接受数字):</span>
        <TextField
          mono
          aria-label="compId"
          defaultValue="33"
          inputMode="numeric"
          style={{ width: "100%", maxWidth: 100 }}
        />
      </div>
      <p style={hint}>
        {"componentDetail 需要一个 compId。字段每次按键都剥掉非数字,所以不可用的值从不存在;标题右侧那条 accent 色命令是它当前会执行的东西。"}
      </p>
    </Card>
  </div>
);

/** 「新建端口转发」对话框:两个 90px 端口字段,中间是方向箭头,读法即 hdc fport 的写法。 */
export const PortForwardPorts = () => (
  <div style={{ width: "100%", maxWidth: 480 }}>
    <Card title="新建端口转发">
      <p style={hint}>forward:本机端口 → 设备端口(hdc fport)。</p>
      <div style={{ ...row, fontSize: 12.5 }}>
        <span style={inline}>本机 tcp:</span>
        <TextField
          mono
          aria-label="本机端口"
          defaultValue="9223"
          inputMode="numeric"
          style={{ width: "100%", maxWidth: 90 }}
        />
        <span style={inline}>→ 设备 tcp:</span>
        <TextField
          mono
          aria-label="设备端口"
          defaultValue="9223"
          inputMode="numeric"
          style={{ width: "100%", maxWidth: 90 }}
        />
      </div>
      <div style={foot}>
        <Button>取消</Button>
        <Button variant="primary">添加转发</Button>
      </div>
    </Card>
  </div>
);

/** Debug · Logs 工具条:110px 的 tag 过滤字段与按钮、分段控件、配额 chip 同处一行。 */
export const LogTagFilter = () => (
  <div style={{ width: "100%", maxWidth: 660 }}>
    <Card title="Logs · host 分片轮转">
      <div style={{ ...row, fontSize: 12.5 }}>
        <Button variant="primary">开始采集</Button>
        <Button disabled title="尚未开始采集,无界面可暂停">
          暂停界面
        </Button>
        <span style={inline}>level ≥</span>
        <SegmentedControl
          size="sm"
          label="日志级别下限"
          value="W"
          options={[
            { value: "I", label: "I" },
            { value: "W", label: "W" },
            { value: "E", label: "E" },
          ]}
        />
        <TextField mono aria-label="tag 过滤" placeholder="tag 过滤" style={{ width: "100%", maxWidth: 110 }} />
      </div>
      <div style={row}>
        <Chip tone="dim">host 轮转: 片 #3 · 11.8MB/64MB · 配额 1GB</Chip>
      </div>
      <p style={hint}>
        {"过滤字段是 mono 的:tag 要和日志行里的 ArkUI / AbilityMS 逐字符对上,不是散文。它与 level ≥ 一样只改本机呈现,不改设备上正在采集的东西。"}
      </p>
    </Card>
  </div>
);
