import { DangerConfirmDialog } from "@arkdeck/ds";

/** v0.6 Flash does not use a second confirmation sheet; shared HDC restart still does. */
export const RestartSharedHdcServer = () => (
  <DangerConfirmDialog
    title="重启共享 HDC server?"
    impactTitle="影响范围"
    impact={[
      "所有 HDC 连接会暂时中断",
      "DevEco 与其他工具正在进行的传输或调试会失败",
      "ArkDeck 不会把此操作当作默认修复步骤",
    ]}
    acknowledgements={["我了解会影响 DevEco 与其他设备会话"]}
    confirmLabel="重启共享 HDC server"
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
