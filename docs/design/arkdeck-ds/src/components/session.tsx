import type { ReactNode } from "react";

export interface SectionGroupProps { title?: ReactNode; children: ReactNode }
export function SectionGroup({ title, children }: SectionGroupProps) {
  return <section className="ad-section-group">{title && <h3>{title}</h3>}{children}</section>;
}

export type DiagnosticAlignment =
  | { kind: "sameClock"; label: string; detail: string }
  | { kind: "calibrated"; label: string; detail: string; toleranceMs: number }
  | { kind: "cannotAlign"; label: string; detail: string };

/** The caller supplies measured facts, never a guessed calibration. */
export function DiagnosticAlignmentDisclosure({ alignment }: { alignment: DiagnosticAlignment }) {
  return <details className="ad-diagnostic-alignment" data-state={alignment.kind}>
    <summary>{alignment.label}{alignment.kind === "calibrated" ? ` ±${alignment.toleranceMs} ms` : ""}</summary>
    <p>{alignment.detail}</p>
  </details>;
}

export interface DiagnosticLogRowProps {
  time: string; level: string; tag: string; text: string;
  tone?: "normal" | "warn" | "error"; selected?: boolean; onSelect?: () => void;
}
export function DiagnosticLogRow({ time, level, tag, text, tone = "normal", selected = false, onSelect }: DiagnosticLogRowProps) {
  return <button type="button" className="ad-diagnostic-log-row" data-tone={tone}
    aria-pressed={selected} onClick={onSelect} disabled={!onSelect}>
    <time>{time}</time><b>{level}</b><span>{tag}</span><span>{text}</span>
  </button>;
}

export function DiagnosticTimeline({ label, controls, children }: { label: string; controls?: ReactNode; children: ReactNode }) {
  return <section className="ad-diagnostic-timeline" aria-label={label}>
    <header><h3>{label}</h3>{controls}</header><div className="ad-diagnostic-timeline__scroll">{children}</div>
  </section>;
}

export function DiagnosticTrack({ label, children }: { label: string; children: ReactNode }) {
  return <div className="ad-diagnostic-track"><strong>{label}</strong><div>{children}</div></div>;
}

export interface DiagnosticTimeCursorProps {
  label: string; minimum: number; maximum: number; value: number;
  valueText: string; onChange?: (value: number) => void;
}
export function DiagnosticTimeCursor({ label, minimum, maximum, value, valueText, onChange }: DiagnosticTimeCursorProps) {
  const valid = [minimum, maximum, value].every(Number.isFinite) && minimum < maximum;
  return <label className="ad-diagnostic-cursor"><span>{label}</span>
    <input type="range" min={minimum} max={maximum} step="any" value={value}
      aria-valuetext={valueText} disabled={!valid || !onChange}
      onChange={e => { const next = e.currentTarget.valueAsNumber;
        if (valid && Number.isFinite(next)) onChange?.(Math.min(maximum, Math.max(minimum, next))); }} />
    <output>{valueText}</output></label>;
}

export interface DiagnosticPointProps {
  label: string; at?: string; selected?: boolean; onSelect?: () => void;
  /** Omit for an unaligned lane. Percentages are display geometry, not clock facts. */
  positionPercent?: number;
}
function Point({ label, at, selected = false, onSelect, positionPercent, kind }: DiagnosticPointProps & { kind: string }) {
  const position = positionPercent !== undefined && Number.isFinite(positionPercent)
    ? Math.max(0, Math.min(100, positionPercent)) : undefined;
  return <button type="button" className="ad-diagnostic-point" data-kind={kind}
    aria-pressed={selected} disabled={!onSelect} onClick={onSelect}
    style={position === undefined ? undefined : { position: "absolute", left: `${position}%` }}>
    <span aria-hidden="true">{kind === "auto" ? "✦" : kind === "manual" ? "⚑" : "●"}</span>
    {label}{at && <time>{at}</time>}
  </button>;
}
export function DiagnosticTraceEvent(props: DiagnosticPointProps) { return <Point {...props} kind="event" />; }
export function DiagnosticLogMarker(props: DiagnosticPointProps) { return <Point {...props} kind="log" />; }
export function DiagnosticMarker(props: DiagnosticPointProps & { origin: "manual" | "auto" }) {
  return <Point {...props} kind={props.origin} />;
}
export function DiagnosticScreenshotPoint(props: DiagnosticPointProps & { failed?: boolean }) {
  return <Point {...props} kind={props.failed ? "failed" : "screenshot"} />;
}

export interface DiagnosticScreenThumbnailProps {
  label: string; source?: string; absenceReason?: string; capturedAt?: string;
  selected?: boolean; onSelect?: () => void;
}
export function DiagnosticScreenThumbnail({ label, source, absenceReason, capturedAt, selected = false, onSelect }: DiagnosticScreenThumbnailProps) {
  return <button type="button" className="ad-diagnostic-thumbnail" aria-pressed={selected}
    disabled={!onSelect} onClick={onSelect}>
    {source ? <img src={source} alt={label} /> : <span>{absenceReason ?? label}</span>}
    <span>{label}</span>{capturedAt && <time>{capturedAt}</time>}
  </button>;
}

export function DiagnosticUnalignedTrackNotice({ children }: { children: ReactNode }) {
  return <p className="ad-diagnostic-unaligned">{children}</p>;
}
export function PartialSessionBanner({ title, missing }: { title: string; missing: { name: string; reason: string }[] }) {
  if (!missing.length) return null;
  return <aside className="ad-session-partial" role="status"><strong>{title}</strong>
    <ul>{missing.map(item => <li key={item.name}><code>{item.name}</code> — {item.reason}</li>)}</ul></aside>;
}
export function ProductionBoundaryCallout({ title, children, kind }: { title: string; children: ReactNode; kind: "current" | "concept" }) {
  return <aside className="ad-production-boundary" data-kind={kind}><strong>{title}</strong><div>{children}</div></aside>;
}

export interface DiagnosticPresetPickerProps {
  label: string; value: string; options: { value: string; label: string; detail?: string; unavailable?: boolean }[];
  onChange?: (value: string) => void; disabled?: boolean;
}
export function DiagnosticPresetPicker({ label, value, options, onChange, disabled = false }: DiagnosticPresetPickerProps) {
  return <label className="ad-diagnostic-preset"><strong>{label}</strong>
    <select value={value} disabled={disabled || !onChange} onChange={e => {
      const next = options.find(option => option.value === e.currentTarget.value);
      if (!disabled && next && !next.unavailable) onChange?.(next.value);
    }}>{options.map(option => <option key={option.value} value={option.value} disabled={option.unavailable}>{option.label}</option>)}</select>
    <span>{options.find(option => option.value === value)?.detail}</span>
  </label>;
}
export function DiagnosticChannelStatus({ name, status, detail, tone = "normal" }: { name: string; status: string; detail?: string; tone?: "normal" | "warn" | "error" }) {
  return <div className="ad-diagnostic-channel" data-tone={tone}><strong>{name}</strong><span>{status}</span>{detail && <small>{detail}</small>}</div>;
}

export function DeviceScreenshotEmptyState({ title, detail, action }: { title: string; detail: string; action?: ReactNode }) {
  return <div className="ad-device-empty"><h3>{title}</h3><p>{detail}</p>{action}</div>;
}

export interface DeviceFrameCountStepperProps { label: string; value: number; disabled?: boolean; onChange?: (value: number) => void }
export function DeviceFrameCountStepper({ label, value, disabled = false, onChange }: DeviceFrameCountStepperProps) {
  return <label className="ad-device-frame-stepper"><span>{label}</span>
    <input type="number" min={2} max={300} step={1} value={value} disabled={disabled || !onChange}
      onChange={e => { const next = e.currentTarget.valueAsNumber;
        if (!disabled && Number.isInteger(next) && next >= 2 && next <= 300) onChange?.(next); }} /></label>;
}

/** A presentation surface, not a transport. The host owns the image/binding
 * identity and supplies its typed gesture controls in children. */
export function DeviceControlSurface({ source, alt, children }: { source?: string; alt: string; children?: ReactNode }) {
  return <div className="ad-device-control-surface">{source && <img src={source} alt={alt} draggable={false} />}{children}</div>;
}
export function DeviceTouchFeedback({ xPercent, yPercent, label, pending = false }: { xPercent: number; yPercent: number; label: string; pending?: boolean }) {
  if (!Number.isFinite(xPercent) || !Number.isFinite(yPercent)) return null;
  return <span className="ad-device-touch" data-pending={pending} role="status" aria-label={label}
    style={{ left: `${Math.max(0, Math.min(100, xPercent))}%`, top: `${Math.max(0, Math.min(100, yPercent))}%` }} />;
}
export function DeviceStaleInputGuard({ reason, refreshLabel, onRefresh }: { reason: string; refreshLabel: string; onRefresh?: () => void }) {
  return <div className="ad-device-stale" role="status"><p>{reason}</p>
    <button type="button" disabled={!onRefresh} onClick={onRefresh}>{refreshLabel}</button></div>;
}
export function DeviceControlEventRow({ title, detail, outcome, outcomeLabel }: { title: string; detail: string; outcome: "confirmed" | "failed" | "unknown" | "pending"; outcomeLabel: string }) {
  return <div className="ad-device-event" data-outcome={outcome}><strong>{title}</strong><span>{outcomeLabel}</span><p>{detail}</p></div>;
}
export function PerformanceImpactNotice({ title, children }: { title: string; children: ReactNode }) {
  return <aside className="ad-performance-notice"><strong>{title}</strong><div>{children}</div></aside>;
}
export interface RecordingArtifactResultProps {
  title: string; path: string; summary: string; revealLabel: string; onReveal?: () => void;
}
export function RecordingArtifactResult({ title, path, summary, revealLabel, onReveal }: RecordingArtifactResultProps) {
  return <div className="ad-recording-result"><strong>{title}</strong><code>{path}</code><span>{summary}</span>
    <button type="button" disabled={!onReveal} onClick={onReveal}>{revealLabel}</button></div>;
}
