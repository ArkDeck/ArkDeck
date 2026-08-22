import * as React from "react";
import { Chip } from "./primitives.js";

export interface Budget {
  /** What is being spent — "Rounds", "Wall clock", "Model calls". */
  name: string;
  /** Spent against the ceiling, already formatted: "4 / 8", "07:42 / 30:00".
   *  Rendered with tabular numerals so a column of these stays aligned while
   *  the numbers change. */
  value: string;
  /** 0–100. Clamped, so a run that overshoots its ceiling still draws a full
   *  bar rather than overflowing the track. */
  percent: number;
}

export interface BudgetMetersProps {
  budgets: Budget[];
  className?: string;
}

/** The stop conditions of a bounded run, shown as spend against a ceiling.
 *
 *  Determinate bars require a real denominator. A budget has one by definition;
 *  Flash may also use one when Runtime confirms written bytes against the
 *  materialized image/partition total. Other device stages use
 *  `IndeterminateBar` and never fabricate a percentage. */
export function BudgetMeters({ budgets, className }: BudgetMetersProps) {
  return (
    <div className={["ad-budget-grid", className].filter(Boolean).join(" ")}>
      {budgets.map((b, i) => (
        <div className="ad-metric" key={i}>
          <div className="ad-metric__v">
            <span>{b.name}</span>
            <b>{b.value}</b>
          </div>
          <div
            className="ad-meter"
            role="progressbar"
            aria-label={b.name}
            aria-valuenow={Math.min(Math.max(b.percent, 0), 100)}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuetext={b.value}
          >
            <i style={{ width: `${Math.min(Math.max(b.percent, 0), 100)}%` }} />
          </div>
        </div>
      ))}
    </div>
  );
}

export interface DeterminateProgressProps {
  /** Confirmed numerator reported by Runtime. */
  value: number;
  /** Materialized denominator owned by Runtime. Must be greater than zero. */
  max: number;
  /** Visible description of what the ratio measures, for example `镜像写入估算`. */
  label: string;
  /** Locale-formatted numerator and denominator, for example `已确认写入 2 GB / 6.4 GB`. */
  valueText: string;
  className?: string;
}

/** A determinate progress indicator for a fact-backed ratio.
 *
 *  Flash may use this only for Runtime-confirmed written bytes divided by the
 *  materialized image/partition total. It is not an overall Job percentage:
 *  preparation, Loader entry, reboot and verification still use stage text or
 *  `IndeterminateBar`. Reaching 100% therefore means "write complete", never
 *  "Flash succeeded". */
export function DeterminateProgress({
  value,
  max,
  label,
  valueText,
  className,
}: DeterminateProgressProps) {
  const safeMax = Number.isFinite(max) && max > 0 ? max : 1;
  const safeValue = Number.isFinite(value) ? Math.min(Math.max(value, 0), safeMax) : 0;
  const percent = Math.round((safeValue / safeMax) * 100);
  return (
    <div className={["ad-determinate", className].filter(Boolean).join(" ")}>
      <div className="ad-determinate__head">
        <span>{label}</span>
        <strong>{percent}%</strong>
      </div>
      <div
        className="ad-determinate__track"
        role="progressbar"
        aria-label={label}
        aria-valuenow={safeValue}
        aria-valuemin={0}
        aria-valuemax={safeMax}
        aria-valuetext={`${percent}% · ${valueText}`}
      >
        <i style={{ width: `${percent}%` }} />
      </div>
      <div className="ad-determinate__value">{valueText}</div>
    </div>
  );
}

export interface StageTrackProps {
  /** The task's declared stages, in order. */
  stages: string[];
  /** Index of the stage the task is in now. Everything before it is drawn as
   *  reached. Pass `-1` before the task starts. */
  currentIndex: number;
  className?: string;
}

/** A Harness task's stage sequence as a connected track.
 *
 *  Not interchangeable with `PhaseTrack`: that one shows the phases of a single
 *  Job as separate pills, while this shows a task's declared lifecycle, where
 *  the connection between stages is the point. A task can also go *backwards*
 *  here — returning to `analyzing` after `verifying` fails is a legitimate
 *  transition, and it must not be drawn as a new stage or as progress lost.
 *  Stage, lifecycle and conditions are three orthogonal facts (spec v0.8 §5.9);
 *  do not collapse them into one indicator. */
export function StageTrack({ stages, currentIndex, className }: StageTrackProps) {
  return (
    <div
      className={["ad-stage-line", className].filter(Boolean).join(" ")}
      aria-label="任务阶段"
    >
      {stages.map((s, i) => (
        <div
          className={[
            "ad-stage-node",
            i < currentIndex ? "ad-stage-node--done" : "",
            i === currentIndex ? "ad-stage-node--now" : "",
          ]
            .filter(Boolean)
            .join(" ")}
          key={i}
          aria-current={i === currentIndex ? "step" : undefined}
        >
          <span>{s}</span>
        </div>
      ))}
    </div>
  );
}

export interface OperationListProps {
  /** Fully-qualified typed operation references, e.g. `workspace.apply-patch@1`.
   *  Show them verbatim — the version suffix is load-bearing. */
  operations: string[];
  className?: string;
}

/** The exact set of typed operations a bounded run may dispatch.
 *
 *  The list is the allowlist, not a summary of it: raw argv, shell, remote paths
 *  and unregistered commands are refused before submission, so anything absent
 *  here cannot run. Render it next to the refusal note rather than alone. */
export function OperationList({ operations, className }: OperationListProps) {
  return (
    <div className={["ad-op-list", className].filter(Boolean).join(" ")}>
      {operations.map((op) => (
        <Chip tone="dim" key={op}>
          {op}
        </Chip>
      ))}
    </div>
  );
}
