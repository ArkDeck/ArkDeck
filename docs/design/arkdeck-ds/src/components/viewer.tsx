import {
  useId,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from "react";

export interface ViewerBounds {
  /** Percentage coordinates within the captured screenshot. */
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ViewerRegion {
  id: string;
  type: string;
  label?: string;
  bounds: ViewerBounds;
}

export interface ViewerWorkspaceProps {
  toolbar?: ReactNode;
  footer?: ReactNode;
  children: ReactNode;
  className?: string;
}

/**
 * Full-height Viewer shell: in-page controls above screenshot + inspector.
 * The window toolbar owns the single page title, matching the SwiftUI App.
 */
export function ViewerWorkspace({
  toolbar,
  footer,
  children,
  className,
}: ViewerWorkspaceProps) {
  return (
    <section className={["ad-viewer", className].filter(Boolean).join(" ")}>
      {toolbar && (
        <header className="ad-viewer__lead" aria-label="Viewer controls">
          <div className="ad-viewer__toolbar">{toolbar}</div>
        </header>
      )}
      <div className="ad-viewer__workspace">{children}</div>
      {footer && <footer className="ad-viewer__footer">{footer}</footer>}
    </section>
  );
}

export interface ViewerInspectorStackProps {
  tree: ReactNode;
  inspector: ReactNode;
  treeToolbar?: ReactNode;
  treeLabel?: ReactNode;
  initialTreePercent?: number;
  className?: string;
}

/**
 * Chrome DevTools-style right-hand inspector: the deep UI tree stays above
 * the selected node's fields, with an accessible horizontal resize handle.
 */
export function ViewerInspectorStack({
  tree,
  inspector,
  treeToolbar,
  treeLabel = "UI tree",
  initialTreePercent = 60,
  className,
}: ViewerInspectorStackProps) {
  const host = useRef<HTMLDivElement>(null);
  const [treePercent, setTreePercent] = useState(() => clampTreePercent(initialTreePercent));

  function updateFromPointer(event: ReactPointerEvent<HTMLDivElement>) {
    const rect = host.current?.getBoundingClientRect();
    if (!rect) return;
    setTreePercent(clampTreePercent(((event.clientY - rect.top) / rect.height) * 100));
  }

  function handlePointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    event.preventDefault();
    event.currentTarget.setPointerCapture(event.pointerId);
    updateFromPointer(event);
  }

  function handlePointerMove(event: ReactPointerEvent<HTMLDivElement>) {
    if (event.currentTarget.hasPointerCapture(event.pointerId)) updateFromPointer(event);
  }

  function handleKey(event: KeyboardEvent<HTMLDivElement>) {
    let next = treePercent;
    if (event.key === "ArrowUp") next -= 4;
    else if (event.key === "ArrowDown") next += 4;
    else if (event.key === "Home") next = 35;
    else if (event.key === "End") next = 68;
    else return;
    event.preventDefault();
    setTreePercent(clampTreePercent(next));
  }

  return (
    <div
      ref={host}
      className={["ad-viewer-inspector-stack", className].filter(Boolean).join(" ")}
      style={{ "--ad-viewer-tree-size": `${treePercent}%` } as CSSProperties}
    >
      <section className="ad-viewer-inspector-stack__tree" aria-label="Complete UI tree">
        <header>
          <h2>{treeLabel}</h2>
          {treeToolbar}
        </header>
        <div className="ad-viewer-inspector-stack__tree-body">{tree}</div>
      </section>
      <div
        className="ad-viewer-inspector-stack__separator"
        role="separator"
        tabIndex={0}
        aria-label="Resize UI tree and node properties"
        aria-orientation="horizontal"
        aria-valuemin={35}
        aria-valuemax={68}
        aria-valuenow={Math.round(treePercent)}
        aria-valuetext={`UI tree uses ${Math.round(treePercent)} percent of the inspector`}
        onPointerDown={handlePointerDown}
        onPointerMove={handlePointerMove}
        onPointerUp={(event) => event.currentTarget.releasePointerCapture(event.pointerId)}
        onPointerCancel={(event) => event.currentTarget.releasePointerCapture(event.pointerId)}
        onKeyDown={handleKey}
      />
      <section className="ad-viewer-inspector-stack__details" aria-label="Selected node properties">
        {inspector}
      </section>
    </div>
  );
}

function clampTreePercent(value: number) {
  return Math.max(35, Math.min(68, Math.round(value)));
}

export interface ViewerScreenshotProps {
  src: string;
  alt: string;
  regions: ViewerRegion[];
  selectedId?: string;
  showBounds?: boolean;
  onSelect?: (id: string) => void;
  className?: string;
}

/**
 * Captured device screen with selectable component bounds.
 *
 * Regions are real buttons, not pointer-only overlays. Overlapping bounds
 * should be ordered deepest-node last so the same hit test used by the visual
 * map is also used by pointer selection.
 */
export function ViewerScreenshot({
  src,
  alt,
  regions,
  selectedId,
  showBounds = false,
  onSelect,
  className,
}: ViewerScreenshotProps) {
  return (
    <div className={["ad-viewer-shot", className].filter(Boolean).join(" ")}>
      <img src={src} alt={alt} />
      {showBounds &&
        regions.map((region) => {
          const selected = region.id === selectedId;
          const style = {
            insetInlineStart: `${region.bounds.x}%`,
            insetBlockStart: `${region.bounds.y}%`,
            width: `${region.bounds.width}%`,
            height: `${region.bounds.height}%`,
          } satisfies CSSProperties;
          return (
            <button
              key={region.id}
              type="button"
              className="ad-viewer-shot__region"
              style={style}
              aria-pressed={selected}
              aria-label={`Select component ${region.type} #${region.id}`}
              onClick={() => onSelect?.(region.id)}
            >
              {selected && (
                <span aria-hidden="true">
                  #{region.id} {region.type}
                </span>
              )}
            </button>
          );
        })}
    </div>
  );
}

export interface ComponentTreeNode {
  id: string;
  type: string;
  text?: string;
  level: number;
  parentId?: string;
  hasChildren?: boolean;
  expanded?: boolean;
}

export interface ComponentTreeProps {
  nodes: ComponentTreeNode[];
  selectedId?: string;
  onSelect?: (id: string) => void;
  ariaLabel?: string;
  className?: string;
}

/** Flat outline projection of the complete ArkUI dump tree. */
export function ComponentTree({
  nodes,
  selectedId,
  onSelect,
  ariaLabel = "ArkUI dump tree",
  className,
}: ComponentTreeProps) {
  const rows = useRef(new Map<string, HTMLButtonElement>());

  function focusAt(index: number) {
    const node = nodes[Math.max(0, Math.min(index, nodes.length - 1))];
    if (node) rows.current.get(node.id)?.focus();
  }

  function handleKey(event: KeyboardEvent<HTMLButtonElement>, node: ComponentTreeNode, index: number) {
    if (event.key === "ArrowDown") {
      event.preventDefault();
      focusAt(index + 1);
    } else if (event.key === "ArrowUp") {
      event.preventDefault();
      focusAt(index - 1);
    } else if (event.key === "Home") {
      event.preventDefault();
      focusAt(0);
    } else if (event.key === "End") {
      event.preventDefault();
      focusAt(nodes.length - 1);
    } else if (event.key === "ArrowLeft" && node.parentId) {
      event.preventDefault();
      onSelect?.(node.parentId);
      rows.current.get(node.parentId)?.focus();
    } else if (event.key === "ArrowRight") {
      const child = nodes.find((candidate) => candidate.parentId === node.id);
      if (child) {
        event.preventDefault();
        onSelect?.(child.id);
        rows.current.get(child.id)?.focus();
      }
    }
  }

  return (
    <div className={["ad-component-tree", className].filter(Boolean).join(" ")} role="tree" aria-label={ariaLabel}>
      {nodes.map((node, index) => {
        const selected = node.id === selectedId;
        return (
          <button
            key={node.id}
            ref={(element) => {
              if (element) rows.current.set(node.id, element);
              else rows.current.delete(node.id);
            }}
            type="button"
            className="ad-component-tree__row"
            style={{ "--ad-tree-level": node.level } as CSSProperties}
            role="treeitem"
            aria-level={node.level}
            aria-expanded={node.hasChildren ? node.expanded : undefined}
            aria-selected={selected}
            tabIndex={selected || (!selectedId && index === 0) ? 0 : -1}
            onClick={() => onSelect?.(node.id)}
            onKeyDown={(event) => handleKey(event, node, index)}
          >
            <span className="ad-component-tree__chevron" aria-hidden="true">
              {node.hasChildren ? (node.expanded ? "▾" : "▸") : ""}
            </span>
            <span className="ad-component-tree__icon" aria-hidden="true" />
            <span className="ad-component-tree__label">
              {node.type}
              {node.text && <small>{node.text}</small>}
            </span>
            <span className="ad-component-tree__id">#{node.id}</span>
          </button>
        );
      })}
    </div>
  );
}

export interface DumpField {
  key: string;
  value: ReactNode;
}

export interface DumpInspectorProps {
  id: string;
  type: string;
  breadcrumb: string[];
  fields: DumpField[];
  layoutFields?: DumpField[];
  accessibilityFields?: DumpField[];
  /** Caller-owned loading, search, refusal or componentDetail fields. */
  advancedContent?: ReactNode;
  onRequestAdvancedDump?: () => void;
  raw: string;
  interactive?: boolean;
  visible?: boolean;
  className?: string;
}

type InspectorTab = "attributes" | "layout" | "accessibility" | "raw" | "advanced";

/** Structured dump fields with the complete raw record always reachable. */
export function DumpInspector({
  id,
  type,
  breadcrumb,
  fields,
  layoutFields = [],
  accessibilityFields = [],
  advancedContent,
  onRequestAdvancedDump,
  raw,
  interactive,
  visible,
  className,
}: DumpInspectorProps) {
  const [tab, setTab] = useState<InspectorTab>("attributes");
  const tabBase = useId();
  const tabs: Array<[InspectorTab, string]> = [
    ["attributes", "Properties"],
    ["layout", "Layout"],
    ["accessibility", "Accessibility"],
    ["raw", "Raw dump"],
    ["advanced", "Advanced Dump"],
  ];
  const activeFields = tab === "layout" ? layoutFields : tab === "accessibility" ? accessibilityFields : fields;

  function selectTab(value: InspectorTab) {
    setTab(value);
    if (value === "advanced") onRequestAdvancedDump?.();
  }

  function handleTabKey(event: KeyboardEvent<HTMLButtonElement>, index: number) {
    let next = index;
    if (event.key === "ArrowRight") next = (index + 1) % tabs.length;
    else if (event.key === "ArrowLeft") next = (index - 1 + tabs.length) % tabs.length;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = tabs.length - 1;
    else return;
    event.preventDefault();
    selectTab(tabs[next][0]);
    const buttons = event.currentTarget.parentElement?.querySelectorAll<HTMLButtonElement>("[role=tab]");
    buttons?.[next]?.focus();
  }

  return (
    <aside className={["ad-dump-inspector", className].filter(Boolean).join(" ")} aria-label="Component details">
      <header className="ad-dump-inspector__head">
        <div className="ad-dump-inspector__title">
          <strong>{type}</strong>
          <span>#{id}</span>
          {interactive && <span>Interactive</span>}
          {visible && <span>Visible</span>}
        </div>
        <div className="ad-dump-inspector__breadcrumb" title={breadcrumb.join(" / ")}>
          {breadcrumb.join(" / ")}
        </div>
      </header>
      <div className="ad-dump-inspector__tabs" role="tablist" aria-label="Dump information">
        {tabs.map(([value, label], index) => (
          <button
            key={value}
            id={`${tabBase}-${value}-tab`}
            type="button"
            role="tab"
            aria-selected={tab === value}
            aria-controls={`${tabBase}-panel`}
            tabIndex={tab === value ? 0 : -1}
            onClick={() => selectTab(value)}
            onKeyDown={(event) => handleTabKey(event, index)}
          >
            {label}
          </button>
        ))}
      </div>
      <div
        id={`${tabBase}-panel`}
        className="ad-dump-inspector__body"
        role="tabpanel"
        aria-labelledby={`${tabBase}-${tab}-tab`}
        tabIndex={0}
      >
        {tab === "advanced" ? (
          advancedContent ?? <p>No componentDetail data was supplied to this preview.</p>
        ) : tab === "raw" ? (
          <pre>{raw}</pre>
        ) : (
          <dl>
            {activeFields.map((field) => (
              <div key={field.key}>
                <dt>{field.key}</dt>
                <dd>{field.value}</dd>
              </div>
            ))}
          </dl>
        )}
      </div>
    </aside>
  );
}
