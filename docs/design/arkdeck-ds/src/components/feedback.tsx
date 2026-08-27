import { useState } from "react";
import type { ReactNode } from "react";
import { Button } from "./primitives.js";

export type CalloutTone = "ok" | "warn" | "danger";

export interface CalloutProps {
  tone?: CalloutTone;
  /**
   * Replaces the tone's default glyph. The default is drawn by CSS, so the
   * callout's text content stays free of decorative characters — only pass this
   * when a specific mark carries meaning the tone does not.
   */
  icon?: ReactNode;
  children: ReactNode;
  className?: string;
}

/**
 * Inline callout for a condition the reader must weigh before acting.
 *
 * Carries a glyph as well as the color so the severity survives without hue —
 * a resource ceiling that was clamped, a critical section in progress, a
 * restored parameter set. The default glyph comes from CSS (`::before`),
 * keeping it out of the accessible name and out of copied text.
 */
export function Callout({ tone = "warn", icon, children, className }: CalloutProps) {
  return (
    <div
      className={[
        "ad-callout",
        `ad-callout--${tone}`,
        icon ? "ad-callout--custom-icon" : null,
        className,
      ]
        .filter(Boolean)
        .join(" ")}
      role={tone === "danger" ? "alert" : undefined}
    >
      {icon ? (
        <span className="ad-callout__icon" aria-hidden="true">
          {icon}
        </span>
      ) : null}
      <div>{children}</div>
    </div>
  );
}

export interface DangerConfirmDialogProps {
  /** Verb + object, never "Are you sure" — e.g. "Flash 2 partitions on rk3568-dev". */
  title: string;
  /** Heading of the impact block, e.g. "What this affects". */
  impactTitle?: ReactNode;
  /** One line per consequence: device identity, what gets erased, what cannot be undone. */
  impact: ReactNode[];
  /** Each must be ticked before the confirm button enables. Erase-class actions use two. */
  acknowledgements: string[];
  /** Repeats the complete action; this text is the last thing read before dispatch. */
  confirmLabel: string;
  cancelLabel?: string;
  onConfirm?: () => void;
  onCancel?: () => void;
  className?: string;
}

/**
 * Optional confirmation layout for flows that explicitly call for one.
 * This is not Runtime authority. The current one-click Flash flow uses an
 * inline impact statement, and headless execution does not require this UI.
 *
 * The shape is deliberately not configurable: title naming the action, an
 * impact block spelling out device identity and what is overwritten, one
 * checkbox per thing the operator is certifying, and a confirm button whose
 * label is the whole action. Focus starts on Cancel, and the confirm button
 * stays disabled until every box is ticked.
 */
export function DangerConfirmDialog({
  title,
  impactTitle = "What this affects",
  impact,
  acknowledgements,
  confirmLabel,
  cancelLabel = "Cancel",
  onConfirm,
  onCancel,
  className,
}: DangerConfirmDialogProps) {
  const [checked, setChecked] = useState<boolean[]>(() => acknowledgements.map(() => false));
  const allChecked = checked.every(Boolean);

  return (
    <div
      className={["ad-dialog", className].filter(Boolean).join(" ")}
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      <h3 className="ad-dialog__title">{title}</h3>
      <div className="ad-dialog__impact">
        <b>{impactTitle}</b>
        <ul>
          {impact.map((line, i) => (
            <li key={i}>{line}</li>
          ))}
        </ul>
      </div>
      <div className="ad-dialog__checks">
        {acknowledgements.map((a, i) => (
          <label key={i}>
            <input
              type="checkbox"
              checked={checked[i]}
              onChange={(e) =>
                setChecked((prev) => prev.map((v, j) => (j === i ? e.target.checked : v)))
              }
            />
            {a}
          </label>
        ))}
      </div>
      <div className="ad-dialog__foot">
        <Button onClick={onCancel}>{cancelLabel}</Button>
        <Button variant="danger" disabled={!allChecked} onClick={onConfirm}>
          {confirmLabel}
        </Button>
      </div>
    </div>
  );
}
