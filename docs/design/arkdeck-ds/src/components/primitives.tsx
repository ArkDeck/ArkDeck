import type { ReactNode } from "react";
import { Symbol } from "./shell.js";
import type { SymbolName } from "./shell.js";

export type ChipTone = "ok" | "warn" | "danger" | "dim" | "planned" | "simulated";

export interface ChipProps {
  /** Semantic tone. `planned` and `simulated` are execution-mode badges and must survive into history and exports. */
  tone?: ChipTone;
  /** Leading glyph. Danger semantics are icon + text + border, never color alone. */
  icon?: ReactNode;
  children: ReactNode;
  className?: string;
}

/**
 * Status chip — the workbench's smallest unit of state.
 *
 * Use for device state, capability probes, prerequisite results, and the
 * `planned` / `simulated` execution-mode badges. The tone carries meaning
 * independently of the accent color: `ok`/`warn`/`danger` are semantic states,
 * never "selected". Always pair a tone with an icon or explicit word so the
 * meaning survives for color-blind readers.
 */
export function Chip({ tone = "dim", icon, children, className }: ChipProps) {
  return (
    <span className={["ad-chip", `ad-chip--${tone}`, className].filter(Boolean).join(" ")}>
      {icon ? <span aria-hidden="true">{icon}</span> : null}
      {children}
    </span>
  );
}

export type ButtonVariant = "default" | "primary" | "danger";

export interface ButtonProps {
  /** `danger` is reserved for actions that mutate or destroy device state. */
  variant?: ButtonVariant;
  disabled?: boolean;
  /** Shown natively on hover — use it to explain *why* a control is disabled. */
  title?: string;
  onClick?: () => void;
  children: ReactNode;
  className?: string;
}

/**
 * Action button.
 *
 * The label must name the complete action ("Flash 2 partitions on rk3568-dev"),
 * never "OK" or "Confirm" — the words are the last safety net before an
 * irreversible step. A disabled button always carries a `title` explaining the
 * unmet precondition.
 */
export function Button({
  variant = "default",
  disabled,
  title,
  onClick,
  children,
  className,
}: ButtonProps) {
  return (
    <button
      type="button"
      className={["ad-btn", variant !== "default" && `ad-btn--${variant}`, className]
        .filter(Boolean)
        .join(" ")}
      disabled={disabled}
      title={title}
      onClick={onClick}
    >
      {children}
    </button>
  );
}

export type Effect = "hostOnly" | "readOnly" | "deviceMutation" | "destructive";

export interface EffectBadgeProps {
  /** The step's blast radius, escalating left to right. */
  effect: Effect;
  className?: string;
}

/** One glyph per blast radius: a laptop that never leaves the host, an eye that
 *  only looks, a pencil that writes something recoverable, and the warning
 *  triangle for overwriting a partition. */
const EFFECT_GLYPH: Record<Effect, SymbolName> = {
  hostOnly: "host",
  readOnly: "eye",
  deviceMutation: "pencil",
  destructive: "warning",
};

/**
 * Effect-class badge for a plan step.
 *
 * Every step in an exact plan is classified before it runs, so a reader can see
 * the blast radius of a whole plan at a glance: `hostOnly` touches nothing on
 * the device, `readOnly` reads, `deviceMutation` changes recoverable state,
 * `destructive` overwrites partitions.
 *
 * The badge renders a glyph *and* the class name, because color is only
 * assisting here — the pairing is what keeps a plan readable under Increase
 * Contrast, and to anyone who does not separate these greens and reds.
 */
export function EffectBadge({ effect, className }: EffectBadgeProps) {
  return (
    <span className={["ad-effect", `ad-effect--${effect}`, className].filter(Boolean).join(" ")}>
      <Symbol name={EFFECT_GLYPH[effect]} small />
      {effect}
    </span>
  );
}

export interface IndeterminateBarProps {
  /** Accessible description of what is in flight. */
  label?: string;
  className?: string;
}

/**
 * Indeterminate progress bar.
 *
 * Deliberately has no percentage: the device reports no reliable byte total for
 * capture or flash, and a fabricated percentage is worse than none. Pair it with
 * the phase sequence so the reader still sees forward motion.
 */
export function IndeterminateBar({ label = "In progress", className }: IndeterminateBarProps) {
  return (
    <div
      className={["ad-ibar", className].filter(Boolean).join(" ")}
      role="progressbar"
      aria-label={label}
    />
  );
}
