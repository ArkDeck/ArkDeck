import type { ReactNode } from "react";
import { Chip, IndeterminateBar } from "./primitives.js";
import { LogTail, PhaseTrack } from "./data.js";

export type JobState = "running" | "succeeded" | "failed" | "cancelled" | "planned";
export type ExecutionMode = "execute" | "planOnly" | "simulated";

export interface RebindPrompt {
  /** What was compared, shown verbatim — serial, binding revision, mode. The
   *  user is being asked to vouch for identity, so show the evidence, not a
   *  verdict. */
  evidence: string;
  onConfirm?: () => void;
  onAbort?: () => void;
}

export interface Job {
  id: string;
  /** Names the work and the target: "Flash · rk3568-5.0-full · rk3568-dev". */
  title: string;
  state: JobState;
  mode?: ExecutionMode;
  /** Fixture id, shown inside the SIMULATED badge. */
  fixture?: string;
  phases: string[];
  currentIndex: number;
  /** Blast radius, used only to pick which job the collapsed bar summarises.
   *  Higher wins, so a flash outranks a dump. */
  risk?: number;
  /** Cancel was requested and the job is running to its next safe boundary. */
  cancelRequested?: boolean;
  /** Wording from the job's own CancellationPolicy. Defaults to the
   *  at-safe-boundary phrasing; pass the policy's words, never "Cancel". */
  cancelLabel?: string;
  /** Set while a critical step is mid-write: cancelling stops what follows and
   *  does not kill the write in flight. */
  criticalNote?: string;
  /** Present when the job is parked waiting for a person to confirm identity
   *  after a reconnect. A job in this state offers no cancel — it is not
   *  running anything to cancel. */
  rebind?: RebindPrompt;
  /** Newest last; the inspector shows the tail. */
  log: string[];
  onCancel?: () => void;
}

const STATE_CHIP: Record<JobState, { tone: "ok" | "warn" | "danger" | "dim" | "planned"; label: string }> = {
  running: { tone: "warn", label: "运行中" },
  succeeded: { tone: "ok", label: "成功" },
  failed: { tone: "danger", label: "失败" },
  cancelled: { tone: "dim", label: "已取消" },
  planned: { tone: "planned", label: "PLANNED" },
};

export interface JobInspectorProps {
  /** Newest last. The inspector shows them newest-first itself. */
  jobs: Job[];
  open?: boolean;
  onToggle?: () => void;
  /** Body height when open. Spec §4.1 puts the draggable range at 220–320. */
  height?: number;
  className?: string;
}

/** The collapsed bar's one line: how many are running, and the riskiest one's
 *  current phase. Computed here rather than taken as a prop — a summary that
 *  can disagree with the list underneath it is worse than none. */
function summarise(jobs: Job[]): string {
  const running = jobs.filter((j) => j.state === "running");
  if (running.length === 0) {
    return jobs.length ? `${jobs.length} 个任务(无运行中)` : "没有运行中的任务";
  }
  const top = [...running].sort((a, b) => (b.risk ?? 1) - (a.risk ?? 1))[0];
  const where = top.rebind
    ? "等待 rebind 确认"
    : (top.phases[top.currentIndex] ?? top.phases[top.phases.length - 1]);
  const at = Math.min(top.currentIndex + 1, top.phases.length);
  return `${running.length} 个运行中 — ${top.title}:${where}(${at}/${top.phases.length})`;
}

function ModeBadge({ mode, fixture }: { mode?: ExecutionMode; fixture?: string }) {
  if (mode === "planOnly") return <Chip tone="planned">◇ PLANNED</Chip>;
  if (mode === "simulated") {
    return <Chip tone="simulated">▤ SIMULATED{fixture ? ` · ${fixture}` : ""}</Chip>;
  }
  return null;
}

/**
 * The global Job inspector (AC-UX-001-01).
 *
 * Docked to the bottom of the window and present on every page, because work
 * outlives the page it was started from: a flash keeps running while you read
 * History, and its phase has to stay visible from there.
 *
 * Collapsed it is one line — how many jobs are running and where the riskiest
 * one is. Expanded it lists them newest-first with phases, the log tail, and a
 * cancel button whose words come from the job's own CancellationPolicy, so the
 * button never promises more than the policy allows. A job parked on a rebind
 * prompt shows the evidence and the two decisions instead, and offers no
 * cancel: it is not running anything to cancel.
 *
 * `plan-only` and `simulated` badges ride along here and never come off —
 * they follow a session into History and into exports (REQ-UX-006).
 */
export function JobInspector({
  jobs,
  open = false,
  onToggle,
  height = 300,
  className,
}: JobInspectorProps) {
  const running = jobs.filter((j) => j.state === "running");
  return (
    <div className={["ad-drawer", open ? "ad-drawer--open" : "", className].filter(Boolean).join(" ")}>
      <button
        type="button"
        className="ad-drawer__bar"
        onClick={onToggle}
        aria-expanded={open}
      >
        <span className="ad-drawer__caret" aria-hidden="true">
          {open ? "▾" : "▸"}
        </span>
        <b>任务</b>
        {/* The summary changes as work advances, so it is the live region — the
            log tail is not, or a screen reader would read every line. */}
        <span className="ad-drawer__status" aria-live="polite">
          {summarise(jobs)}
        </span>
        {running.length > 0 ? <IndeterminateBar label="有任务正在运行" /> : null}
      </button>

      <div className="ad-drawer__body" style={open ? { maxHeight: height } : undefined} aria-hidden={!open}>
        {jobs.length === 0 ? (
          <div className="ad-job ad-job--empty">本次会话尚无任务。</div>
        ) : (
          [...jobs].reverse().map((job) => {
            const chip = STATE_CHIP[job.state];
            const isRunning = job.state === "running";
            return (
              <article className="ad-job" key={job.id}>
                <div className="ad-job__head">
                  <b>{job.title}</b>
                  <ModeBadge mode={job.mode} fixture={job.fixture} />
                  <Chip tone={chip.tone}>{chip.label}</Chip>
                  <span className="ad-job__spacer" />
                  {isRunning && !job.rebind ? (
                    <button
                      type="button"
                      className="ad-btn"
                      disabled={job.cancelRequested}
                      onClick={job.onCancel}
                    >
                      {job.cancelRequested
                        ? "等待安全边界…"
                        : (job.cancelLabel ?? "取消(在安全边界)")}
                    </button>
                  ) : null}
                </div>

                <PhaseTrack
                  phases={job.phases}
                  currentIndex={job.currentIndex}
                  running={isRunning && !job.rebind}
                />

                {job.criticalNote ? (
                  <p className="ad-job__critical">{job.criticalNote}</p>
                ) : null}

                {job.rebind ? (
                  <div className="ad-rebind">
                    <b>设备回连,需确认后继续</b>
                    <span className="ad-mono">{job.rebind.evidence}</span>
                    <span className="ad-job__spacer" />
                    <button type="button" className="ad-btn ad-btn--primary" onClick={job.rebind.onConfirm}>
                      确认同一设备,继续
                    </button>
                    <button type="button" className="ad-btn" onClick={job.rebind.onAbort}>
                      中止
                    </button>
                  </div>
                ) : null}

                <LogTail lines={job.log.slice(-200)} maxHeight={110} />
              </article>
            );
          })
        )}
      </div>
    </div>
  );
}
