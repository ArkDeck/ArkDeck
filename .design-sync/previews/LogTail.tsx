import { LogTail } from "@arkdeck/ds";

export const HilogStream = () => (
  <LogTail
    emphasis
    maxHeight={220}
    lines={[
      "07-13 11:02:11.482 W ArkUI: [list_layout] measure retry, node 88",
      "07-13 11:02:11.490 W ArkUI: [render] flush delayed 22ms",
      "07-13 11:02:12.013 E AbilityMS: connect timeout, bundle=com.example.settings",
      "07-13 11:02:12.400 W ArkUI: [list_layout] measure retry, node 91",
      "07-13 11:02:12.867 W Multimodal: touch dispatch queue depth 3",
      "07-13 11:02:13.204 I RenderService: flush composition, 1 surface dirty",
      "07-13 11:02:13.641 W ArkUI: [render] flush delayed 18ms",
      "07-13 11:02:14.088 I WindowManager: focus window unchanged (12)",
      "07-13 11:02:14.503 E AbilityMS: connect timeout, bundle=com.example.settings",
      "07-13 11:02:15.017 W ArkUI: [list_layout] measure retry, node 94",
      "07-13 11:02:15.462 I Hiview: cpu usage snapshot written",
    ]}
  />
);

export const JobLogTail = () => (
  <LogTail
    lines={[
      "→ Preflight",
      "已获取 CriticalActivityLease(idle sleep 保持)",
      "→ EnterUpdater",
      "→ Re-identify",
      "→ flash boot",
      "→ flash system",
    ]}
  />
);

export const CommandEcho = () => (
  <LogTail
    lines={[
      "$ hdc -t 150100469… shell bm dump -a",
      "exit 0 · 812ms",
      "com.example.settings",
      "com.demo.gallery",
      "com.ohos.launcher",
    ]}
  />
);

export const CapabilityProbeRaw = () => (
  <LogTail
    maxHeight={180}
    lines={[
      "$ hdc -t 150100469… shell flashd --help",
      "/system/bin/sh: flashd: inaccessible or not found",
      "exit 127",
      "",
      '$ hdc -t 150100469… shell "ls /bin/flashd 2>/dev/null; ls /system/bin/flashd 2>/dev/null"',
      "(空输出)",
      "exit 0",
    ]}
  />
);
