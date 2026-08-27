// Historical Harness illustration: CHG-2026-064 removed App/CLI/daemon task.*. Not a product backlog.
import { Callout, Card, Chip, DataTable, KeyValueList, OperationList, Symbol } from "@arkdeck/ds";

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const mono = { fontFamily: "var(--ad-font-mono)" };

const OPS = [
  "workspace.apply-patch@1",
  "workspace.run-tests@1",
  "debug.hap@1",
  "capture.diagnostics@1",
];

const REFUSAL = "只允许上面的 typed operation。raw argv、shell、远端路径和未登记命令在提交前拒绝。";

const EVIDENCE = [
  { term: "base revision", description: "7c9e…e218" },
  { term: "patch revision", description: "candidate:2 · diff 6f2b…9d18" },
  { term: "confirmed", description: "crash=SIGABRT; source guard missing" },
  { term: "disproved", description: "device offline; package mismatch" },
  { term: "next readback", description: "launch state + crash signature absent" },
];

/** Attempt 证据卡实景:证据在上,可派发的 operation 集合在下,紧跟拒绝声明。 */
export const AttemptEvidence = () => (
  <div style={{ width: "100%", maxWidth: 560 }}>
    <Card title="Attempt 2 · Evidence">
      <KeyValueList items={EVIDENCE} />
      <OperationList operations={OPS} />
      <Callout tone="warn" icon={<Symbol name="warning" small />}>
        {REFUSAL}
      </Callout>
    </Card>
  </div>
);

/** 这份列表就是允许清单本身 —— 不在其中的东西根本无法提交。 */
export const TypedOperationAllowlist = () => (
  <div style={{ width: "100%", maxWidth: 700 }}>
    <Card title="本次 bounded run 可派发的 typed operation">
      <OperationList operations={OPS} />
      <Callout tone="warn" icon={<Symbol name="warning" small />}>
        {REFUSAL}
      </Callout>
      <p style={hint}>
        列表与拒绝声明必须同屏:单看四枚 chip 像是「已用过的命令」,配上声明才读得出「只有这四个能用」。
      </p>
    </Card>
  </div>
);

/** @1 是标识的一部分:同名不同版是两个 operation,不能省略。 */
export const VersionSuffixIsLoadBearing = () => (
  <div style={{ width: "100%", maxWidth: 700 }}>
    <Card title="逐字呈现,不做美化">
      <OperationList operations={OPS} />
      <p style={hint}>
        <span style={mono}>workspace.apply-patch@1</span>{" "}
        与未来的 <span style={mono}>@2</span> 是两个不同的 operation:版本后缀决定 schema 与副作用范围,
        显示时不折叠、不改写、不翻译成中文动词。
      </p>
      <p style={hint}>
        chip 用等宽字体,便于逐字符比对 host 侧登记表与这里列出的名字。
      </p>
    </Card>
  </div>
);

/** 页面上的两栏形态:左边 Attempts,右边证据与 operation 集合。 */
export const PageTwoUpWithAttempts = () => (
  <div
    style={{
      width: "100%",
      maxWidth: 840,
      display: "grid",
      gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
      gap: 14,
      alignItems: "start",
    }}
  >
    <Card title="Attempts">
      <DataTable
        columns={[
          { key: "n", header: "#", mono: true },
          { key: "outcome", header: "Outcome" },
          { key: "fp", header: "Strategy fingerprint", mono: true },
        ]}
        rows={[
          {
            id: "1",
            cells: { n: "1", outcome: <Chip tone="dim">noProgress</Chip>, fp: "91ac…74e0" },
          },
          {
            id: "2",
            cells: { n: "2", outcome: <Chip tone="warn">● active</Chip>, fp: "6f2b…9d18" },
          },
        ]}
      />
      <p style={hint}>重复失败由 strategy fingerprint 判断,不因改写 hypothesis 文案而伪装成新策略。</p>
    </Card>
    <Card title="Attempt 2 · Evidence">
      <KeyValueList items={EVIDENCE.slice(0, 3)} />
      <OperationList operations={OPS} />
      <Callout tone="warn" icon={<Symbol name="warning" small />}>
        {REFUSAL}
      </Callout>
    </Card>
  </div>
);
