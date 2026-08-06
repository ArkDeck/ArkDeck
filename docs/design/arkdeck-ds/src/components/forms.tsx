import type * as React from "react";
import type { ReactNode } from "react";

export interface TextFieldProps
  extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "size"> {
  /** Monospace. Use it for anything the user compares character by character —
   *  addresses, ports, serials, component ids, paths. */
  mono?: boolean;
}

/**
 * Single-line text input.
 *
 * Most fields in this product take an identifier rather than prose, so `mono`
 * is the common case, not the exception: a `/dev/tty.usbserial-1420` or a
 * `192.168.1.30:8710` is read by comparing it to something else.
 *
 * Where a value must be well-formed — a port, a component id — constrain it as
 * the user types rather than validating on submit. The prototype's compId field
 * strips non-digits on every keystroke, so an unusable value never exists.
 */
export function TextField({ mono, className, ...rest }: TextFieldProps) {
  return (
    <input
      className={["ad-inp", mono ? "ad-inp--mono" : "", className].filter(Boolean).join(" ")}
      {...rest}
    />
  );
}

export interface SelectOption {
  value: string;
  label?: string;
}

export interface SelectProps
  extends Omit<React.SelectHTMLAttributes<HTMLSelectElement>, "size" | "children"> {
  options: (SelectOption | string)[];
  mono?: boolean;
}

/**
 * Dropdown for a closed set of choices.
 *
 * Use it where the options are fixed and known — transport kind, a command
 * template. Where the set comes from probing the device, prefer `TagPicker` or
 * a table: a `<select>` cannot show *why* an option is unavailable, and this
 * product never silently omits a capability it merely failed to confirm.
 */
export function Select({ options, mono, className, ...rest }: SelectProps) {
  return (
    <select
      className={["ad-inp", mono ? "ad-inp--mono" : "", className].filter(Boolean).join(" ")}
      {...rest}
    >
      {options.map((o) => {
        const opt = typeof o === "string" ? { value: o } : o;
        return (
          <option value={opt.value} key={opt.value}>
            {opt.label ?? opt.value}
          </option>
        );
      })}
    </select>
  );
}

export interface RadioOption {
  value: string;
  /** The choice itself. A node, so a recipe can show its exact command inline. */
  label: ReactNode;
  /** The consequence of choosing it — when it applies, what it costs. Shown
   *  muted beside the label, not in a tooltip: these choices change what
   *  happens to a device, so the trade-off has to be readable without hovering. */
  description?: ReactNode;
  disabled?: boolean;
}

export interface RadioGroupProps {
  /** Shared input name; must be unique on the page. */
  name: string;
  options: RadioOption[];
  value?: string;
  onChange?: (value: string) => void;
  /** Labels the group for assistive tech — say what is being chosen. */
  label?: string;
  className?: string;
}

/**
 * A vertical set of mutually exclusive choices.
 *
 * This is the shape the product uses for its consequential decisions — which
 * dump recipe to run, whether to leave a debug parameter switched on, which
 * hdc binary to bind a job to. So each option carries its own consequence in
 * `description` rather than relying on a separate paragraph: the reader is
 * choosing, and the cost belongs next to the choice.
 */
export function RadioGroup({
  name,
  options,
  value,
  onChange,
  label,
  className,
}: RadioGroupProps) {
  return (
    <div
      className={["ad-radio", className].filter(Boolean).join(" ")}
      role="radiogroup"
      aria-label={label}
    >
      {options.map((o) => (
        <label key={o.value}>
          <input
            type="radio"
            name={name}
            value={o.value}
            checked={value === o.value}
            disabled={o.disabled}
            onChange={() => onChange?.(o.value)}
          />
          <span>
            {o.label}
            {o.description ? <span className="ad-radio__desc">{o.description}</span> : null}
          </span>
        </label>
      ))}
    </div>
  );
}

export interface TagOption {
  value: string;
  /** Set when the device did not report support. The tag stays visible and
   *  becomes unselectable — never omitted, because a missing tag and an
   *  unconfirmed one mean different things. */
  unavailable?: boolean;
  /** Why it is unavailable, shown on hover. Say what was not confirmed, not
   *  "unsupported" — the product does not claim knowledge it lacks. */
  unavailableReason?: string;
}

export interface TagPickerProps {
  options: (TagOption | string)[];
  /** Currently selected values. */
  selected: string[];
  onToggle?: (value: string) => void;
  label?: string;
  className?: string;
}

/**
 * Multi-select over a set the device itself confirmed.
 *
 * Built for Trace tags, where the list comes from capability probing. An option
 * the device did not confirm is rendered disabled with a dashed border and a
 * reason, rather than hidden: hiding it would imply the tag does not exist,
 * when what actually happened is that ArkDeck could not confirm it. The
 * distinction is the whole point — this product does not guess at capabilities.
 */
export function TagPicker({ options, selected, onToggle, label, className }: TagPickerProps) {
  const chosen = new Set(selected);
  return (
    <div
      className={["ad-tagpick", className].filter(Boolean).join(" ")}
      role="group"
      aria-label={label}
    >
      {options.map((o) => {
        const tag = typeof o === "string" ? { value: o } : o;
        const on = chosen.has(tag.value);
        return (
          <button
            type="button"
            key={tag.value}
            className={on ? "ad-tagpick__on" : undefined}
            aria-pressed={on}
            disabled={tag.unavailable}
            title={tag.unavailableReason}
            onClick={() => onToggle?.(tag.value)}
          >
            {tag.value}
          </button>
        );
      })}
    </div>
  );
}
