import type { ReactNode } from "react";
import { Chip } from "./primitives.js";

interface RecoveryItemBase {
  /** What was interrupted — "Flash · rk3568-dev · system 分区". Name the device;
   *  a reader with several boards attached cannot act on "Flash". */
  title: string;
  /** What happened and what it means, in the user's terms. */
  detail: ReactNode;
}

/**
 * The four kinds of unfinished work, as separate shapes rather than one shape
 * with optional everything.
 *
 * That is deliberate: spec §4.2 says an `outcomeUnknown` item must never render
 * something that looks resumable, and the cheapest way to guarantee it is to
 * give that variant no resume callback to pass. The same reasoning gives
 * `waiting` no actions at all — it is not blocked on a person.
 */
export type RecoveryItem =
  | (RecoveryItemBase & {
      /** The provider declared this step restart-safe and the last outcome is known. */
      kind: "resumeSafe";
      /** Where execution would pick up, named exactly — not "continue". */
      resumeLabel: string;
      onResume?: () => void;
      onArchive?: () => void;
    })
  | (RecoveryItemBase & {
      /** Inside a bounded wait; nothing for a person to do yet. */
      kind: "waiting";
      /** Time left in the window, pre-formatted ("04:12"). */
      remaining?: string;
    })
  | (RecoveryItemBase & {
      /** An intent was written and no outcome recorded. Nobody knows what the
       *  device did — including ArkDeck. */
      kind: "outcomeUnknown";
      /** Opens the provider's own RecoveryGuide, shown verbatim. */
      onGuide?: () => void;
      /** Archiving only stops ArkDeck tracking; the sheet must say so. */
      onArchive?: () => void;
      /** Set when a critical child has not reached a safe boundary — archiving
       *  is refused and this says why. */
      archiveBlockedReason?: string;
    })
  | (RecoveryItemBase & {
      /** A Harness task is blocked on a person (§4.2, last bullet). */
      kind: "humanRequired";
      /** The machine-readable block, e.g. `E000003`. */
      reasonCode: string;
      /** The smallest thing the person must do — never a vague "continue". */
      minimalAction: string;
      /** Which stage the task resumes at afterwards. */
      resumesAtStage: string;
      onDone?: () => void;
    });

const KIND_CHIP = {
  resumeSafe: { tone: "ok" as const, label: "resume-safe" },
  waiting: { tone: "dim" as const, label: "waiting" },
  outcomeUnknown: { tone: "warn" as const, label: "outcomeUnknown" },
  humanRequired: { tone: "warn" as const, label: "humanRequired" },
};

export interface RecoveryBannerProps {
  items: RecoveryItem[];
  /** Defaults to 「存在未完成的恢复项」. */
  heading?: string;
  className?: string;
}

function Action({
  label,
  danger,
  disabled,
  reason,
  onClick,
}: {
  label: string;
  danger?: boolean;
  disabled?: boolean;
  reason?: string;
  onClick?: () => void;
}) {
  return (
    <button
      type="button"
      className={["ad-btn", danger && !disabled ? "ad-btn--danger" : ""].filter(Boolean).join(" ")}
      disabled={disabled}
      title={reason}
      onClick={onClick}
    >
      {label}
    </button>
  );
}

/**
 * Recovery banner — what a previous session left unfinished (REQ-UX-003).
 *
 * Sits at the top of the detail pane, above the page's own content and below
 * the toolbar, because it changes what the rest of the page means: a device
 * with an unresolved `outcomeUnknown` may not be in the state the page implies.
 *
 * It renders each item's kind as a chip itself, so the label can never
 * contradict the shape, and it offers only the actions that kind allows.
 * Archiving is destructive-styled on purpose — it does not fix anything, it
 * stops ArkDeck from tracking, and the confirmation sheet has to say the three
 * things it does *not* do.
 */
export function RecoveryBanner({
  items,
  heading = "存在未完成的恢复项",
  className,
}: RecoveryBannerProps) {
  if (items.length === 0) return null;
  return (
    <section
      className={["ad-banner", className].filter(Boolean).join(" ")}
      aria-label={heading}
    >
      <header className="ad-banner__head">{heading}</header>
      {items.map((item, i) => {
        const chip = KIND_CHIP[item.kind];
        return (
          <div className="ad-ritem" key={i}>
            <div className="ad-ritem__body">
              <b>{item.title}</b> <Chip tone={chip.tone}>{chip.label}</Chip>
              <p>{item.detail}</p>
              {item.kind === "humanRequired" ? (
                <dl className="ad-ritem__block">
                  <dt>reasonCode</dt>
                  <dd className="ad-mono">{item.reasonCode}</dd>
                  <dt>需要你做</dt>
                  <dd>{item.minimalAction}</dd>
                  <dt>之后回到</dt>
                  <dd className="ad-mono">{item.resumesAtStage}</dd>
                </dl>
              ) : null}
            </div>
            <div className="ad-ritem__actions">
              {item.kind === "resumeSafe" ? (
                <>
                  <Action label={item.resumeLabel} onClick={item.onResume} />
                  {item.onArchive ? (
                    <Action label="结束恢复并归档…" danger onClick={item.onArchive} />
                  ) : null}
                </>
              ) : null}
              {item.kind === "waiting" && item.remaining ? (
                <Chip tone="dim">剩余 {item.remaining}</Chip>
              ) : null}
              {item.kind === "outcomeUnknown" ? (
                <>
                  {item.onGuide ? <Action label="恢复指引" onClick={item.onGuide} /> : null}
                  <Action
                    label="结束恢复并归档…"
                    danger
                    disabled={Boolean(item.archiveBlockedReason)}
                    reason={item.archiveBlockedReason}
                    onClick={item.onArchive}
                  />
                </>
              ) : null}
              {item.kind === "humanRequired" && item.onDone ? (
                <Action label="我已完成上述动作" onClick={item.onDone} />
              ) : null}
            </div>
          </div>
        );
      })}
    </section>
  );
}
