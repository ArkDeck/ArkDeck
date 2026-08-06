import { Button, Callout, Card, RadioGroup, Symbol } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };
const left = { display: "flex", gap: 8 };
const foot = { display: "flex", gap: 8, justifyContent: "flex-end" };

const RECIPES = [
  {
    value: "elementTree",
    label: (
      <>
        elementTree — <span style={mono}>{"-w <w> -element -c"}</span>
      </>
    ),
  },
  {
    value: "nodeSummary",
    label: (
      <>
        nodeSummary — <span style={mono}>{"-w <w> -default"}</span>
      </>
    ),
  },
  {
    value: "fullDefaultTree",
    label: (
      <>
        fullDefaultTree — <span style={mono}>{"-w <w> -default -all"}</span>
      </>
    ),
  },
  {
    value: "componentDetail",
    label: (
      <>
        componentDetail — <span style={mono}>{"-w <w> -element -lastpage <compId>"}</span>
      </>
    ),
  },
];

const POLICIES = [
  { value: "none", label: "不改变参数", description: "— 以设备当前状态采集" },
  { value: "temp", label: "临时开启,结束后恢复", description: "— 仅当原值可读且可写回时可选" },
  { value: "keep", label: "保持开启", description: "— 需要二次确认,状态栏持续提醒" },
];

/** UI Dump 的 Recipe 四选一:每个选项自带它将要执行的那条命令,标题右侧是当前生效的实参。 */
export const DumpRecipe = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card
      title="Recipe"
      action={
        <span style={{ ...mono, fontSize: 12, color: "var(--ad-accent)" }}>-w 12 -element -c</span>
      }
    >
      <RadioGroup name="rc" label="Dump recipe" value="elementTree" options={RECIPES} />
      <p style={hint}>
        {"选项 label 里就是命令本身,不放在 tooltip 里:选 recipe 等于选一条 hidumper 参数,读者要在按「采集」之前对得上。"}
      </p>
    </Card>
  </div>
);

/** 「Debug 参数策略」:description 才是让这个选择安全的东西 —— 前置条件与代价紧贴选项。 */
export const DebugParameterPolicy = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="Debug 参数策略">
      <RadioGroup name="pp" label="Debug 参数策略" value="none" options={POLICIES} />
      <div style={left}>
        <Button variant="primary">采集</Button>
      </div>
      <p style={hint}>
        {"「仅当原值可读且可写回时可选」与「需要二次确认,状态栏持续提醒」写在选项旁边而不是另起一段:读者正在做选择,代价就该在选项这一行。"}
      </p>
    </Card>
  </div>
);

/** 选中「保持开启」:持久改设备状态,于是二次确认与 impact 直接接在这一组下面。 */
export const KeepEnabledConsequence = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="Debug 参数策略 · 已选「保持开启」">
      <RadioGroup name="pp2" label="Debug 参数策略" value="keep" options={POLICIES} />
      <Callout tone="danger">
        {"persist.ace.debug.enabled 等参数将持久保留在设备上,可能影响性能与后续测量;设备状态栏将持续显示提醒,且该变更计入审计。"}
      </Callout>
      <div style={foot}>
        <Button>取消</Button>
        <Button variant="danger">确认保持开启</Button>
      </div>
    </Card>
  </div>
);

/** Settings 的 HDC 工具二选一:mono 路径与版本在 label 里,SHA/重探测的代价在 description 里。 */
export const HdcToolChoice = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="HDC 工具">
      <RadioGroup
        name="hdc"
        label="HDC 工具"
        value="deveco"
        options={[
          {
            value: "deveco",
            label: (
              <>
                DevEco SDK — <span style={mono}>…/toolchains/hdc · 3.1.0e</span>
              </>
            ),
          },
          {
            value: "manual",
            label: (
              <>
                手动选择 — <span style={mono}>/usr/local/bin/hdc · 3.0.0b</span>
              </>
            ),
            description: "(SHA-256 已计算 · 能力需重新探测)",
          },
        ]}
      />
      <Callout tone="warn" icon={<Symbol name="warning" small />}>
        有任务正在运行:切换不影响运行中的 Job——工具在 Job 创建时固化,仅新任务使用新选择。
      </Callout>
    </Card>
  </div>
);
