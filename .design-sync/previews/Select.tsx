import {
  Button,
  Callout,
  Card,
  KeyValueList,
  LogTail,
  Select,
  Symbol,
  TextField,
} from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };
const row = { display: "flex", gap: 8, alignItems: "center", flexWrap: "wrap" as const };
const foot = { display: "flex", gap: 8, justifyContent: "flex-end" };

const TEMPLATES = [
  { value: "device.packageInventory", label: "已安装包清单" },
  { value: "device.debugParameterRead", label: "读取 ArkUI Debug 参数" },
  { value: "device.windowInventory", label: "窗口清单" },
  { value: "device.uptime", label: "设备运行时长" },
];

/** 添加目标对话框 · TCP:Select 决定后面那个地址该怎么读 —— 这里是 host:port。 */
export const AddTargetTcp = () => (
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
          defaultValue="192.168.1.30:8710"
          placeholder="192.168.1.30:8710 或 /dev/tty.usbserial-1420"
          style={{ flex: 1, minWidth: 240 }}
        />
      </div>
      <div style={foot}>
        <Button>取消</Button>
        <Button variant="primary">添加目标</Button>
      </div>
    </Card>
  </div>
);

/** 同一个对话框 · UART:选项换成 UART,同一个字段现在装的是一条串口设备路径。 */
export const AddTargetUart = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="添加 TCP / UART 目标">
      <div style={row}>
        <Select options={["TCP", "UART"]} defaultValue="UART" aria-label="目标类型" />
        <TextField
          mono
          aria-label="目标地址"
          defaultValue="/dev/tty.usbserial-1420"
          placeholder="192.168.1.30:8710 或 /dev/tty.usbserial-1420"
          style={{ flex: 1, minWidth: 240 }}
        />
      </div>
      <p style={hint}>
        {"两个选项对应两种地址形态:TCP 是 "}
        <span style={mono}>192.168.1.30:8710</span>
        {",UART 是 "}
        <span style={mono}>/dev/tty.usbserial-1420</span>
        {"。选项集合固定且已知,所以用 Select;能力探测得到的集合不该走这里 —— 下拉说不出某一项为何不可用。"}
      </p>
    </Card>
  </div>
);

/** Debug · Commands 的 typed template 下拉:mono Select + 只读 lowering,没有自由文本 argv。 */
export const CommandTemplateSelect = () => (
  <div style={{ width: "100%", maxWidth: 660 }}>
    <Card title="Commands · typed template only · no raw surface">
      <Callout tone="warn" icon={<Symbol name="warning" small />}>
        {"App 只提交 approved typed template 与 schema-defined inputs。下面的 executable / argv 是 Provider lowering 的只读预览,不是输入框。"}
      </Callout>
      <div style={row}>
        <Select
          mono
          options={TEMPLATES}
          defaultValue="device.packageInventory"
          aria-label="typed template"
        />
        <Button variant="primary">运行 typed template</Button>
      </div>
      <KeyValueList
        items={[
          { term: "template id", description: "device.packageInventory" },
          { term: "effect", description: "readOnly" },
          { term: "lowered argv", description: "hdc -t 150100469… shell bm dump -a" },
        ]}
      />
      <p style={hint}>不存在自由文本 command / argv / path 字段;PTY 与 raw shell 不属于此界面。</p>
    </Card>
  </div>
);

/** 换一个选项,下面整段 lowering 与输出都跟着换 —— 四个 template 的 argv 列在末行。 */
export const TemplateLoweringPreview = () => (
  <div style={{ width: "100%", maxWidth: 660 }}>
    <Card title="Commands · 窗口清单">
      <div style={row}>
        <Select
          mono
          options={TEMPLATES}
          defaultValue="device.windowInventory"
          aria-label="typed template"
        />
        <Button variant="primary">运行 typed template</Button>
      </div>
      <KeyValueList
        items={[
          { term: "template id", description: "device.windowInventory" },
          { term: "effect", description: "readOnly" },
          {
            term: "lowered argv",
            description: "hdc -t 150100469… shell hidumper -s WindowManagerService -a -a",
          },
        ]}
      />
      <LogTail
        maxHeight={110}
        lines={[
          "template device.windowInventory · 窗口清单",
          "provider lowering (read-only): hdc -t 150100469… shell hidumper -s WindowManagerService -a -a",
          "exit 0 · 436ms",
          "WindowName  DisplayId  Pid   WinId  Type",
          "settings0   0          2841  12     APP",
          "launcher    0          1203  8      LAUNCHER",
        ]}
      />
      <p style={hint}>
        {"下拉里只有四项,截图只能看见选中的那一项,所以把它们的 argv 写在这里:bm dump -a / param get persist.ace.debug.enabled / hidumper -s WindowManagerService -a -a / uptime。"}
      </p>
    </Card>
  </div>
);
