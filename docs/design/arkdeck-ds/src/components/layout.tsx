import type { ReactNode } from "react";

export interface CardProps {
  /** Section heading, rendered in the muted label style. */
  title?: ReactNode;
  /** Right-aligned control in the heading row (a refresh or "view raw" button). */
  action?: ReactNode;
  children: ReactNode;
  className?: string;
}

/**
 * Panel card — the unit every workbench page is built from.
 *
 * One card holds one coherent fact set: a toolchain summary, a capability
 * matrix, a plan table. Cards stack in a single column or a two-up grid; they
 * never nest more than one level.
 */
export function Card({ title, action, children, className }: CardProps) {
  return (
    <section className={["ad-card", className].filter(Boolean).join(" ")}>
      {title || action ? (
        <div className="ad-card__head">
          {title}
          {action ? <span className="ad-card__action">{action}</span> : null}
        </div>
      ) : null}
      {children}
    </section>
  );
}

export interface WindowFrameProps {
  /** Centered title in the chrome bar. */
  title: string;
  /** Right-aligned chrome controls (e.g. the AC-annotation toggle). */
  toolbar?: ReactNode;
  children: ReactNode;
  className?: string;
}

/**
 * macOS window shell.
 *
 * Frames a full screen mock so previews read as the real desktop app rather
 * than a floating fragment. Not used inside the product — it *is* the product's
 * window.
 */
export function WindowFrame({ title, toolbar, children, className }: WindowFrameProps) {
  return (
    <div className={["ad-window", className].filter(Boolean).join(" ")}>
      <div className="ad-window__bar">
        <div className="ad-window__lights" aria-hidden="true">
          <i />
          <i />
          <i />
        </div>
        <div className="ad-window__title">{title}</div>
        {toolbar}
      </div>
      <div className="ad-window__body">{children}</div>
    </div>
  );
}

export interface KeyValueItem {
  term: ReactNode;
  /** Rendered monospace — paths, hashes, versions, endpoints. */
  description: ReactNode;
}

export interface KeyValueListProps {
  items: KeyValueItem[];
  className?: string;
}

/**
 * Two-column fact list.
 *
 * The description column is monospace by construction: everything shown here is
 * a path, hash, version string, or endpoint that a reader may need to compare
 * character by character.
 */
export function KeyValueList({ items, className }: KeyValueListProps) {
  return (
    <dl className={["ad-kv", className].filter(Boolean).join(" ")}>
      {items.map((it, i) => (
        <div key={i} style={{ display: "contents" }}>
          <dt>{it.term}</dt>
          <dd>{it.description}</dd>
        </div>
      ))}
    </dl>
  );
}
