import { Button, Chip, DataTable, EffectBadge } from "@arkdeck/ds";

const planColumns = [
  { key: "stage", header: "计划阶段" },
  { key: "count", header: "步骤数", mono: true },
  { key: "effect", header: "最高 effect" },
];

export const FlashExactPlan = () => (
  <DataTable
    columns={planColumns}
    rows={[
      {
        id: "1",
        cells: {
          stage: "准备与校验",
          count: "3",
          effect: <EffectBadge effect="hostOnly" />,
        },
      },
      {
        id: "2",
        cells: {
          stage: "进入 Loader 与身份绑定",
          count: "4",
          effect: <EffectBadge effect="deviceMutation" />,
        },
      },
      {
        id: "3",
        cells: {
          stage: "写入分区",
          count: "1",
          effect: <EffectBadge effect="destructive" />,
        },
      },
      {
        id: "4",
        cells: {
          stage: "回读、重启与验证",
          count: "6",
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
        id: "rockusb",
        cells: {
          cap: "RockUSB Flash",
          state: <Chip tone="ok">可用</Chip>,
          note: <Button>查看 raw</Button>,
        },
      },
    ]}
  />
);

export const SelectedFlashImage = () => (
  <DataTable
    columns={[
      { key: "img", header: "镜像包", mono: true },
      { key: "size", header: "大小", mono: true },
      { key: "build", header: "期望 build", mono: true },
    ]}
    rows={[
      {
        id: "dayu200-image",
        cells: {
          img: "dayu200-openharmony-5.0.0.71.tar.gz",
          size: "6.4 GB",
          build: "OpenHarmony 5.0.0.71",
        },
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
          dev: "DAYU200",
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
          dev: "DAYU200",
          what: "Flash · dayu200-openharmony-5.0.0.71.tar.gz",
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
          dev: "DAYU200",
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
          dev: "DAYU200",
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
