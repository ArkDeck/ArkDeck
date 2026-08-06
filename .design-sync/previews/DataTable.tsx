import { Button, Chip, DataTable, EffectBadge } from "@arkdeck/ds";

const planColumns = [
  { key: "n", header: "#", mono: true },
  { key: "step", header: "step", mono: true },
  { key: "args", header: "参数摘要", mono: true },
  { key: "effect", header: "effect" },
];

export const FlashExactPlan = () => (
  <DataTable
    columns={planColumns}
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
);

export const CapabilityMatrix = () => (
  <DataTable
    columns={[
      { key: "cap", header: "能力" },
      { key: "state", header: "状态" },
      { key: "note", header: "", mono: true },
    ]}
    rows={[
      {
        id: "hidumper",
        cells: {
          cap: "hidumper",
          state: <Chip tone="ok">可用</Chip>,
          note: "-w/-element/-lastpage 已确认",
        },
      },
      {
        id: "hitrace",
        cells: {
          cap: "hitrace",
          state: <Chip tone="ok">可用</Chip>,
          note: "tag×11 · buffer ≤ 307200",
        },
      },
      {
        id: "bytrace",
        cells: { cap: "bytrace", state: <Chip tone="dim">不存在</Chip>, note: "" },
      },
      {
        id: "flashd",
        cells: {
          cap: "flashd",
          state: <Chip tone="warn">无法确认</Chip>,
          note: <Button>查看 raw</Button>,
        },
      },
    ]}
  />
);

export const ProfileImageSet = () => (
  <DataTable
    columns={[
      { key: "part", header: "分区", mono: true },
      { key: "img", header: "镜像", mono: true },
      { key: "size", header: "大小", mono: true },
      { key: "sha", header: "SHA-256", mono: true },
    ]}
    rows={[
      {
        id: "boot",
        cells: { part: "boot", img: "boot.img", size: "64MB", sha: "c9d2…41aa ✓" },
      },
      {
        id: "system",
        cells: { part: "system", img: "system.img", size: "2.1GB", sha: "8b07…9e35 ✓" },
      },
    ]}
  />
);

const historyColumns = [
  { key: "id", header: "Session", mono: true },
  { key: "st", header: "状态" },
  { key: "dev", header: "设备", mono: true },
  { key: "what", header: "内容" },
  { key: "when", header: "时间", mono: true },
];

export const HistorySessions = () => (
  <DataTable
    columns={historyColumns}
    selectedId="S-0711-04"
    rows={[
      {
        id: "S-0713-06",
        cells: {
          id: "S-0713-06",
          st: (
            <Chip tone="dim" icon="⊘">
              已取消
            </Chip>
          ),
          dev: "rk3568-dev",
          what: "Trace · 渲染/动画 30s(用户取消)",
          when: "07-13 10:21",
        },
      },
      {
        id: "S-0712-02",
        cells: {
          id: "S-0712-02",
          st: (
            <Chip tone="planned" icon="◇">
              PLANNED
            </Chip>
          ),
          dev: "rk3568-dev",
          what: "Flash · rk3568-5.0-full(3 分区)",
          when: "07-12 15:40",
        },
      },
      {
        id: "S-0712-03",
        cells: {
          id: "S-0712-03",
          st: (
            <>
              <Chip tone="ok" icon="✓">
                成功
              </Chip>{" "}
              <Chip tone="simulated" icon="▤">
                SIMULATED
              </Chip>
            </>
          ),
          dev: "SIM-fixture-a3",
          what: "Flash · 断连注入场景(reconcile 一致)",
          when: "07-12 16:11",
        },
      },
      {
        id: "S-0711-04",
        cells: {
          id: "S-0711-04",
          st: (
            <Chip tone="warn" icon="⚠">
              已中断 · 结果未知
            </Chip>
          ),
          dev: "rk3568-dev",
          what: "Flash · system 分区(outcomeUnknown)",
          when: "07-11 23:47",
        },
      },
      {
        id: "S-0711-05",
        cells: {
          id: "S-0711-05",
          st: (
            <Chip tone="danger" icon="✕">
              失败
            </Chip>
          ),
          dev: "rk3568-dev",
          what: "UI Dump · elementTree(设备离线)",
          when: "07-11 20:15",
        },
      },
    ]}
  />
);

export const HistoryFilteredEmpty = () => (
  <DataTable columns={historyColumns} rows={[]} emptyText="无匹配项" />
);
