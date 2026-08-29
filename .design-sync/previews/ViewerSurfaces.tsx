import { useState } from "react";
import {
  ComponentTree,
  DumpInspector,
  ViewerInspectorStack,
  ViewerScreenshot,
  ViewerWorkspace,
} from "@arkdeck/ds";
import type { ComponentTreeNode, ViewerRegion } from "@arkdeck/ds";

/**
 * The five controlled Viewer exports, shown together because that is the only
 * shape they exist in: `ViewerWorkspace` frames a `ViewerScreenshot` beside a
 * `ViewerInspectorStack` whose two halves are `ComponentTree` and
 * `DumpInspector`. The App's counterpart is
 * `ArkDeckApp/Features/UIDump/UIDumpWorkspaceView.swift`.
 *
 * Everything below is a declared design sample. There is no capture, no Job,
 * no device: the "screenshot" is an inline drawing, and the fields are made-up
 * values that must never be read as observed device facts.
 */

const hint = { margin: 0, fontSize: 12.5, lineHeight: 1.6, color: "var(--ad-ink-2)" };
const col = {
  width: "100%",
  maxWidth: 980,
  display: "flex",
  flexDirection: "column" as const,
  gap: 12,
};

/** An inline drawing, not a device capture. Kept as a data URI so the preview
 *  never reaches the network and never implies a real screen was recorded. */
const SAMPLE_SCREEN =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 270 480" width="270" height="480">
      <rect width="270" height="480" fill="#f2f2f7"/>
      <rect x="0" y="0" width="270" height="58" fill="#ffffff"/>
      <rect x="16" y="24" width="70" height="14" rx="4" fill="#c7c7cc"/>
      <rect x="12" y="70" width="246" height="26" rx="8" fill="#e5e5ea"/>
      <rect x="12" y="108" width="246" height="42" rx="10" fill="#ffffff"/>
      <rect x="12" y="162" width="246" height="36" rx="10" fill="#ffffff"/>
      <rect x="222" y="172" width="26" height="16" rx="8" fill="#34c759"/>
      <rect x="12" y="206" width="246" height="36" rx="10" fill="#ffffff"/>
      <rect x="12" y="250" width="246" height="36" rx="10" fill="#ffffff"/>
    </svg>`,
  );

const REGIONS: ViewerRegion[] = [
  { id: "1", type: "Root", bounds: { x: 0, y: 0, width: 100, height: 100 } },
  { id: "12", type: "Navigation", bounds: { x: 0, y: 0, width: 100, height: 12 } },
  { id: "15", type: "Search", bounds: { x: 4, y: 14, width: 92, height: 6 } },
  { id: "22", type: "ListItem", bounds: { x: 4, y: 33, width: 92, height: 8 } },
  { id: "42", type: "Toggle", bounds: { x: 82, y: 35, width: 11, height: 4 } },
];

const NODES: ComponentTreeNode[] = [
  { id: "1", type: "Root", level: 1, hasChildren: true, expanded: true },
  { id: "12", type: "Navigation", text: "Settings", level: 2, parentId: "1" },
  { id: "15", type: "Search", text: "Search settings", level: 2, parentId: "1" },
  { id: "22", type: "ListItem", text: "WLAN", level: 2, parentId: "1", hasChildren: true, expanded: true },
  { id: "42", type: "Toggle", text: "WLAN", level: 3, parentId: "22" },
];

const FIELDS = [
  { key: "id", value: "42" },
  { key: "type", value: "Toggle" },
  { key: "inspectorId", value: "wifi_switch" },
  { key: "enabled", value: "true" },
  { key: "checked", value: "true" },
];

const LAYOUT_FIELDS = [
  { key: "bounds", value: "[886, 614, 996, 678]" },
  { key: "opacity", value: "1" },
  { key: "clip", value: "false" },
];

const ACCESSIBILITY_FIELDS = [
  { key: "accessibilityText", value: "WLAN" },
  { key: "focusable", value: "true" },
  { key: "focused", value: "false" },
];

const RAW = JSON.stringify(
  {
    designSample: true,
    id: 42,
    type: "Toggle",
    inspectorId: "wifi_switch",
    bounds: "[886, 614, 996, 678]",
    checked: true,
  },
  null,
  2,
);

function Inspector({ id }: { id: string }) {
  const node = NODES.find((candidate) => candidate.id === id) ?? NODES[0];
  const breadcrumb = ["Root", node.parentId === "22" ? "ListItem" : node.type];
  return (
    <DumpInspector
      id={node.id}
      type={node.type}
      breadcrumb={breadcrumb}
      fields={node.id === "42" ? FIELDS : [{ key: "id", value: node.id }, { key: "type", value: node.type }]}
      layoutFields={node.id === "42" ? LAYOUT_FIELDS : []}
      accessibilityFields={node.id === "42" ? ACCESSIBILITY_FIELDS : []}
      raw={node.id === "42" ? RAW : JSON.stringify({ designSample: true, id: Number(node.id), type: node.type }, null, 2)}
      interactive={node.id === "42"}
      visible
      advancedContent={
        <p style={hint}>
          Advanced Dump reads `componentDetail` for the selected numeric
          hostWindowId/componentId only. This sample carries no capture, so it
          shows no fields rather than reusing the previous component's.
        </p>
      }
    />
  );
}

/** The linked selection the spec asks for: screenshot, tree and fields agree. */
export const LinkedSelection = () => {
  const [selected, setSelected] = useState("42");
  const [showBounds, setShowBounds] = useState(true);
  return (
    <div style={col}>
      <ViewerWorkspace
        toolbar={
          <label style={{ ...hint, display: "flex", alignItems: "center", gap: 6 }}>
            <input
              type="checkbox"
              checked={showBounds}
              onChange={(event) => setShowBounds(event.target.checked)}
            />
            Show component bounds
          </label>
        }
        footer={<span style={hint}>5 nodes · design sample · capture metrics not measured</span>}
      >
        <ViewerScreenshot
          src={SAMPLE_SCREEN}
          alt="Design sample drawing of a settings screen; not a device capture"
          regions={REGIONS}
          selectedId={selected}
          showBounds={showBounds}
          onSelect={setSelected}
        />
        <ViewerInspectorStack
          tree={<ComponentTree nodes={NODES} selectedId={selected} onSelect={setSelected} />}
          inspector={<Inspector id={selected} />}
        />
      </ViewerWorkspace>
      <p style={hint}>
        Selecting in the drawing, the tree or the inspector moves the same
        identity. The App keeps screenshot and tree in one capture epoch; when
        either side is missing it draws no clickable map at all.
      </p>
    </div>
  );
};

/** Bounds hidden is the default: only the current node keeps its outline. */
export const BoundsHidden = () => (
  <div style={col}>
    <ViewerWorkspace footer={<span style={hint}>Capture metrics not measured</span>}>
      <ViewerScreenshot
        src={SAMPLE_SCREEN}
        alt="Design sample drawing of a settings screen; not a device capture"
        regions={REGIONS}
        selectedId="22"
      />
      <ViewerInspectorStack
        tree={<ComponentTree nodes={NODES} selectedId="22" />}
        inspector={<Inspector id="22" />}
      />
    </ViewerWorkspace>
    <p style={hint}>
      "Show component bounds" is off by default, so the other nodes stay quiet.
      This sample publishes no geometry proof; a real capture without verified
      coordinates disables screenshot selection instead of guessing.
    </p>
  </div>
);
