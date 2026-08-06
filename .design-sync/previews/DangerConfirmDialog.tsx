import { DangerConfirmDialog } from "@arkdeck/ds";

export const FlashPartitions = () => (
  <DangerConfirmDialog
    title="刷写 rk3568-dev 的 2 个分区"
    impactTitle="影响范围"
    impact={[
      "设备:rk3568-dev · serial 150100469… · binding rev 3(已确认)",
      "写入:boot(64MB)、system(2.1GB)——将覆盖现有系统",
      "失败可能导致设备无法启动,需使用厂商恢复工具;ArkDeck 不保证可自动恢复",
    ]}
    acknowledgements={[
      "我确认目标设备与镜像匹配(rk3568 · OpenHarmony 5.0)",
      "我已确认稳定供电与厂商恢复路径可用",
    ]}
    confirmLabel="刷写 rk3568-dev 的 2 个分区"
  />
);

export const ArchiveInterrupted = () => (
  <DangerConfirmDialog
    title="结束恢复并归档为「已中断」?"
    impactTitle="该动作只停止 ArkDeck 的跟踪。它不会:"
    impact={[
      "证明设备已经恢复正常",
      "停止可能仍在设备上运行的远端任务",
      "回滚已修改的 persist.* 参数或清理远端文件",
    ]}
    acknowledgements={["我已阅读恢复指引,并自行确认过设备状态"]}
    confirmLabel="归档为已中断"
  />
);

export const ClearDeviceLogBuffer = () => (
  <DangerConfirmDialog
    title="清空设备日志 buffer?"
    impactTitle="hilog -r 是全局且不可恢复的设备端操作"
    impact={[
      "会影响其他工具正在进行的采集",
      "普通的开始 / 停止采集绝不自动清空",
      "该操作计入审计",
    ]}
    acknowledgements={["我了解这会清空所有工具可见的设备日志"]}
    confirmLabel="清空设备 buffer"
  />
);
