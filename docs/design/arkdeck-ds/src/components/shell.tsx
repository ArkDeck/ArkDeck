import * as React from "react";

/** The macOS-style stroke glyphs the prototype ships as an SVG sprite. Inlined
 *  per icon here because a library dropped into an arbitrary page cannot rely
 *  on a `<defs>` sprite existing in that document. */
const GLYPHS: Record<string, React.ReactNode> = {
  "sidebar": <><rect x="2.5" y="3" width="15" height="14" rx="2" /><path d="M7 3v14" /></>,
  "overview": <><rect x="3" y="3" width="5.5" height="5.5" rx="1" /><rect x="11.5" y="3" width="5.5" height="5.5" rx="1" /><rect x="3" y="11.5" width="5.5" height="5.5" rx="1" /><rect x="11.5" y="11.5" width="5.5" height="5.5" rx="1" /></>,
  "flash": <><path d="M11.7 1.8 4.6 11h5l-1.2 7.2 7-10h-5z" /></>,
  "debug": <><path d="M7 6.2V4.8a3 3 0 0 1 6 0v1.4M5 8.5h10v4.2a5 5 0 0 1-10 0zM2.5 9.5H5m10 0h2.5M2.5 14H5m10 0h2.5M10 8.5V17" /></>,
  "dump": <><rect x="7" y="2.5" width="6" height="4" rx="1" /><rect x="2.5" y="13.5" width="6" height="4" rx="1" /><rect x="11.5" y="13.5" width="6" height="4" rx="1" /><path d="M10 6.5v3.2M5.5 13.5v-2h9v2" /></>,
  "trace": <><path d="M2 11h3l2-6 3.2 11 2.4-8 1.6 3H18" /></>,
  "history": <><path d="M4.2 5.4A7 7 0 1 1 3 11" /><path d="M2.5 4.8h3.8v3.8M10 6.2v4.2l3 1.8" /></>,
  "automation": <><path d="m10 2 .9 3.1L14 6l-3.1.9L10 10l-.9-3.1L6 6l3.1-.9zM15.5 10l.7 2.3 2.3.7-2.3.7-.7 2.3-.7-2.3-2.3-.7 2.3-.7zM5 11l.6 2 2 .6-2 .6-.6 2-.6-2-2-.6 2-.6z" /></>,
  "settings": <><path d="M4 5h12M4 10h12M4 15h12" /><circle cx="8" cy="5" r="1.7" fill="var(--ad-panel-solid)" /><circle cx="13" cy="10" r="1.7" fill="var(--ad-panel-solid)" /><circle cx="7" cy="15" r="1.7" fill="var(--ad-panel-solid)" /></>,
  "jobs": <><path d="m3 5 1.5 1.5L7 3.8M9 5h8M3 10l1.5 1.5L7 8.8M9 10h8M3 15l1.5 1.5L7 13.8M9 15h8" /></>,
  "plus": <><path d="M10 3v14M3 10h14" /></>,
  "host": <><rect x="3" y="4" width="14" height="9" rx="1.5" /><path d="M1.5 16.5h17" /></>,
  "eye": <><path d="M1.8 10S5 4.8 10 4.8 18.2 10 18.2 10 15 15.2 10 15.2 1.8 10 1.8 10Z" /><circle cx="10" cy="10" r="2.4" /></>,
  "pencil": <><path d="M13.6 3.4a1.9 1.9 0 0 1 2.7 2.7L7.2 15.2l-3.6.9.9-3.6z" /></>,
  "warning": <><path d="M9 2.8 1.8 16a1.2 1.2 0 0 0 1 1.7h14.4a1.2 1.2 0 0 0 1-1.7L11 2.8a1.2 1.2 0 0 0-2 0Z" /><path d="M10 7v4.5M10 14.5h.01" /></>,
};

export type SymbolName = keyof typeof GLYPHS & string;

export interface SymbolProps {
  /** Which glyph to draw. */
  name: SymbolName;
  /** 14px instead of 16px, for inline use inside dense rows. */
  small?: boolean;
  /** Accessible label. Omit for a decorative glyph that sits beside real text —
   *  the default is `aria-hidden`, which is what you want next to a visible
   *  label, since a screen reader should not announce the icon twice. */
  label?: string;
  className?: string;
}

/** A single stroke glyph, sized and colored from the surrounding text
 *  (`stroke: currentColor`), so it inherits a Button's or NavItem's color
 *  without any per-use styling. */
export function Symbol({ name, small, label, className }: SymbolProps) {
  const glyph = GLYPHS[name];
  if (!glyph) return null;
  return (
    <svg
      className={["ad-symbol", small ? "ad-symbol--sm" : "", className].filter(Boolean).join(" ")}
      viewBox="0 0 20 20"
      role={label ? "img" : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
    >
      {glyph}
    </svg>
  );
}

export interface ToolbarButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** Square 28×28 with no label — pass `aria-label` when you use it. */
  iconOnly?: boolean;
  children?: React.ReactNode;
}

/** A control for the window's unified toolbar (spec v0.8 §3), not for page
 *  content — it is 28px tall with a translucent fill so it reads as chrome.
 *  Use `Button` inside the content area instead. */
export function ToolbarButton({ iconOnly, className, children, ...rest }: ToolbarButtonProps) {
  return (
    <button
      type="button"
      className={["ad-toolbar-btn", iconOnly ? "ad-toolbar-btn--icon" : "", className]
        .filter(Boolean)
        .join(" ")}
      {...rest}
    >
      {children}
    </button>
  );
}

export interface StatusCell {
  /** Small caps-ish label above the value. */
  label: string;
  /** The value. A node, so a Chip can carry state here. */
  value: React.ReactNode;
}

export interface StatusStripProps {
  /** First cell is given the most room; the rest share the remainder evenly.
   *  Put the identifying fact first (which task, which device). */
  cells: StatusCell[];
  className?: string;
}

/** The dense summary row that opens a page (spec v0.8 §5.1) — the four things
 *  you check before reading anything else. Deliberately not a row of Cards:
 *  §1 asks for fewer bounded containers and more grouping. */
export function StatusStrip({ cells, className }: StatusStripProps) {
  return (
    <div
      className={["ad-summary-strip", className].filter(Boolean).join(" ")}
      style={{ ["--ad-strip-rest" as string]: Math.max(cells.length - 1, 1) }}
    >
      {cells.map((c, i) => (
        <div className="ad-summary-cell" key={i}>
          <small>{c.label}</small>
          <b>{c.value}</b>
        </div>
      ))}
    </div>
  );
}
