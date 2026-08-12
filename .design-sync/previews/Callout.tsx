import { Callout } from "@arkdeck/ds";

export const ToneAxis = () => (
  <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
    <Callout tone="ok">完成:postflight 校验通过,设备回报 build 与镜像期望一致。</Callout>
    <Callout tone="warn">recoveryPath unsatisfied → Runtime 拒绝提交，重新检测设备后再试。</Callout>
    <Callout tone="danger">
      系统拒绝访问 USB 设备节点(permissionDenied);设备本身在线。请在系统设置 →
      隐私与安全性中允许 ArkDeck 访问 USB 配件。
    </Callout>
  </div>
);

export const TraceBufferClamp = () => (
  <Callout tone="warn">
    附件兼容 preset 的 buffer 327680 超出该设备建议值,已按能力探测收敛到 307200。
  </Callout>
);

export const FlashCriticalSection = () => (
  <Callout tone="danger">
    正在写入镜像 —— <b>当前分区写入不会被强制中断</b>
    ；停止只作用于后续步骤。请勿合盖、手动睡眠、断电或拔线(idle sleep
    已由系统保持,但合盖无法被阻止)。
  </Callout>
);

export const AuthDenied = () => (
  <Callout tone="warn">
    授权被拒绝或弹窗超时(E000003)。请检查设备的 USB 调试开关后重试。若重试无效,可重启共享 HDC
    server——这会影响 DevEco 与所有已连接设备,需要你显式确认。
  </Callout>
);

export const AuthGranted = () => (
  <Callout tone="ok">已授权,设备 Ready——列表与 Overview 已更新。</Callout>
);
