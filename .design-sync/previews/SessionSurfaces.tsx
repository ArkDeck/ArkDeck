import { useState } from "react";
import {
  SectionGroup, DiagnosticAlignmentDisclosure, DiagnosticTimeline, DiagnosticTrack,
  DiagnosticTimeCursor, DiagnosticLogRow, DiagnosticScreenThumbnail, DiagnosticTraceEvent,
  DiagnosticLogMarker, DiagnosticMarker, DiagnosticScreenshotPoint, DiagnosticUnalignedTrackNotice,
  PartialSessionBanner, ProductionBoundaryCallout, DiagnosticPresetPicker, DiagnosticChannelStatus,
  DeviceScreenshotEmptyState, DeviceFrameCountStepper, DeviceControlSurface, DeviceTouchFeedback,
  DeviceStaleInputGuard, DeviceControlEventRow, PerformanceImpactNotice, RecordingArtifactResult,
} from "@arkdeck/ds";

/** Local component review only. No recording, device input or export is performed. */
export function SessionSurfaces({ language = "zh-Hans" }: { language?: string }) {
  const t = (zh: string, en: string) => language === "en" ? en : zh;
  const [cursor, setCursor] = useState(2);
  const [selected, setSelected] = useState("mark");
  const [frames, setFrames] = useState(40);
  const [preset, setPreset] = useState("bounded");
  return <div style={{ display:"grid", gap:16, padding:20, color:"var(--ad-ink)", background:"var(--ad-ground)" }}>
    <ProductionBoundaryCallout kind="concept" title={t("组件演示 · 无 Runtime 连接", "Component demo · no Runtime connection")}>
      {t("以下状态是明确标注的设计样本，交互只修改本机预览。", "These states are design samples. Controls change only this preview.")}
    </ProductionBoundaryCallout>
    <SectionGroup title="Diagnostic Session">
      <DiagnosticAlignmentDisclosure alignment={{kind:"cannotAlign", label:t("无法对齐", "Cannot align"), detail:t("此记录没有主机与设备的时钟校准。", "No host-to-device clock calibration was recorded.")}} />
      <PartialSessionBanner title={t("部分产物缺失", "Partial session")} missing={[{name:"trace.htrace", reason:t("未发布", "Not published")}]} />
      <DiagnosticPresetPicker label={t("采集预设", "Capture preset")} value={preset} onChange={setPreset}
        options={[{value:"bounded",label:t("有界采集", "Bounded capture")},{value:"interactive",label:t("交互式会话（尚未接通）", "Interactive session (not connected)"),unavailable:true}]} />
      <DiagnosticChannelStatus name="HiLog" status={t("此样本未采集", "Not captured in this sample")} detail={t("不将缺少数据视为没有问题。", "Missing data is not an all-clear.")} tone="warn" />
      <DiagnosticTimeline label={t("时间线组件", "Timeline components")} controls={<DiagnosticTimeCursor
        label={t("游标", "Cursor")} minimum={0} maximum={10} value={cursor} valueText={`${cursor.toFixed(1)} s`} onChange={setCursor} />}>
        <DiagnosticTrack label="Trace"><DiagnosticUnalignedTrackNotice>{t("无校准，不与主机时刻对齐", "No calibration; not aligned to host time")}</DiagnosticUnalignedTrackNotice></DiagnosticTrack>
        <DiagnosticTrack label={t("事件", "Events")}><DiagnosticTraceEvent label="doComposition" selected={selected==="event"} onSelect={()=>setSelected("event")} /><DiagnosticLogMarker label="W · ArkUI" onSelect={()=>setSelected("log")} /></DiagnosticTrack>
        <DiagnosticTrack label={t("标记", "Marks")}><DiagnosticMarker origin="manual" label={t("手动标记", "Manual mark")} selected={selected==="mark"} onSelect={()=>setSelected("mark")} /><DiagnosticMarker origin="auto" label="stepFailed" onSelect={()=>setSelected("auto")} /><DiagnosticScreenshotPoint label={t("截图失败", "Screenshot failed")} failed onSelect={()=>setSelected("shot")} /></DiagnosticTrack>
      </DiagnosticTimeline>
      <DiagnosticLogRow time="+2.100s" level="W" tag="ArkUI" text={t("演示日志：帧处理超时", "Demo log: frame processing exceeded its budget")} selected={selected==="log"} tone="warn" onSelect={()=>setSelected("log")} />
      <DiagnosticScreenThumbnail label={t("标记 1", "Mark 1")} absenceReason={t("该时刻没有截图", "No screenshot at this moment")} />
    </SectionGroup>
    <SectionGroup title="Device">
      <DeviceFrameCountStepper label={t("帧数（2–300）", "Frames (2–300)")} value={frames} onChange={setFrames} />
      <div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(240px,1fr))",gap:16}}>
        <DeviceControlSurface alt={t("设备截图", "Device screenshot")}>
          <DeviceTouchFeedback xPercent={50} yPercent={65} label={t("演示触点，未派发", "Demo touch point, not dispatched")} pending />
          <DeviceStaleInputGuard reason={t("样本截图已过期，输入不可用。", "The sample frame is stale; input is unavailable.")} refreshLabel={t("需要 Runtime 截图", "Runtime capture required")} />
        </DeviceControlSurface>
        <SectionGroup>
          <DeviceScreenshotEmptyState title={t("没有截图", "No screenshot")} detail={t("本演示没有连接设备。", "This demo is not connected to a device.")} />
          <DeviceControlEventRow title="tap" outcome="unknown" outcomeLabel={t("结果未知", "Outcome unknown")} detail={t("不重放；需重新读取设备状态。", "Do not replay; read fresh device state.")} />
          <PerformanceImpactNotice title={t("采集影响", "Capture impact")}>{t("采集会占用设备资源。帧率以测量结果为准。", "Capture consumes device resources. Frame rate must come from measurements.")}</PerformanceImpactNotice>
          <RecordingArtifactResult title={t("产物组件样本（无文件）", "Artifact component sample (no file)")} path="demo/recording.mov"
            summary={t("无实际录制，不显示推算帧率。", "No recording occurred; no frame rate is inferred.")} revealLabel={t("没有可打开的文件", "No file to reveal")} />
        </SectionGroup>
      </div>
    </SectionGroup>
  </div>;
}
