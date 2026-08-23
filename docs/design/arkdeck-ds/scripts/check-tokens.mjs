// Fails the build when this package's tokens stop matching the design docs.
//
// Why it exists: the first design-sync built this library from prototype v0.2
// while `main` had already moved to v0.3 — a different accent, translucent
// separators, and a new value for every semantic color. Nothing caught it; it
// surfaced only because a rebase happened to pull the newer docs in. This runs
// first in `npm run build`, which is also `cfg.buildCmd`, so every sync passes
// through it — and because it is fail-closed, a failure leaves no `dist/` and
// the converter stops at [NO_DIST] rather than shipping stale tokens.
//
// It cannot live under `scripts/` or `.github/`: both are governance-sensitive
// paths, and touching them requires one active task whose Allowed paths cover
// the whole diff. See .design-sync/NOTES.md.

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

/** Every .tsx/.css under a directory, recursively. */
function srcFiles(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    if (e.isDirectory()) return srcFiles(p);
    return /\.(tsx?|css)$/.test(e.name) ? [p] : [];
  });
}

// Bump ONLY after re-reading the docs and confirming this package still
// expresses them. This is the deliberate acknowledgement step: a docs version
// bump is exactly the event that silently invalidated the library once.
const ALIGNED_VERSION = "v0.8";

const pkgRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const designDir = join(pkgRoot, "..");
const SPEC = join(designDir, "macos-ux-interaction-spec.md");
const PROTOTYPE = join(designDir, "prototype.html");
const TOKENS = join(pkgRoot, "src", "tokens.css");

/** Prototype token -> this package's token. Every prototype `:root` custom
 *  property must appear here or in PROTOTYPE_NOT_ADOPTED, so a token added
 *  upstream fails the build instead of being silently ignored. */
const MAPPING = {
  ground: "ad-ground",
  panel: "ad-panel",
  "panel-solid": "ad-panel-solid",
  panel2: "ad-panel-2",
  ink: "ad-ink",
  ink2: "ad-ink-2",
  ink3: "ad-ink-3",
  line: "ad-line",
  accent: "ad-accent",
  "accent-fill": "ad-accent-fill",
  "accent-ink": "ad-accent-ink",
  "accent-weak": "ad-accent-weak",
  selection: "ad-accent-sel",
  ok: "ad-ok",
  warn: "ad-warn",
  danger: "ad-danger",
  "danger-fill": "ad-danger-fill",
  "danger-weak": "ad-danger-weak",
  planned: "ad-planned",
  sim: "ad-simulated",
  chrome: "ad-chrome",
  shadow: "ad-shadow",
  "control-shadow": "ad-control-shadow",
  mono: "ad-font-mono",
};

/** Prototype tokens deliberately not carried over, with the reason. */
const PROTOTYPE_NOT_ADOPTED = {};

/** This package's tokens with no prototype counterpart, with the reason. */
const DS_ONLY = {
  "ad-font-ui": "the prototype sets the UI stack on `body`, not as a custom property",
  "ad-radius-sm": "scale token; the spec gives radii in prose (§2), not as a table row",
  "ad-radius-md": "scale token",
  "ad-radius-lg": "scale token",
  "ad-radius-xl": "scale token",
  "ad-space-1": "scale token; spec §2 gives spacing in prose",
  "ad-space-2": "scale token",
  "ad-space-3": "scale token",
  "ad-space-4": "scale token",
  "ad-space-5": "scale token",
  "ad-space-6": "scale token",
  "ad-text-xs": "type scale; spec §2 gives sizes in prose",
  "ad-text-sm": "type scale",
  "ad-text-md": "type scale",
  "ad-text-lg": "type scale",
  "ad-text-title": "type scale",
};

const problems = [];
let gaps = [];
const fail = (msg) => problems.push(msg);

/** Canonicalize a CSS value so `rgba(60,60,67,.18)` and
 *  `rgba(60, 60, 67, 0.18)` compare equal. */
function norm(value) {
  return value
    .trim()
    .toLowerCase()
    .replace(/(rgba?)\(([^)]+)\)/g, (_, fn, inner) =>
      `${fn}(${inner
        .split(",")
        .map((n) => String(Number(n.trim())))
        .join(",")})`,
    )
    .replace(/\s*,\s*/g, ",")
    .replace(/\s+/g, " ");
}

/** Pull `--name: value` pairs out of one CSS block. */
function declarations(block) {
  const out = new Map();
  for (const [, name, value] of block.matchAll(/--([a-z0-9-]+)\s*:\s*([^;]+);/gi)) {
    out.set(name.toLowerCase(), norm(value));
  }
  return out;
}

function blockAfter(source, marker, label) {
  const at = source.indexOf(marker);
  if (at === -1) {
    fail(`could not find ${label} (looked for \`${marker}\`) — the file's shape changed`);
    return "";
  }
  const from = source.indexOf("{", at + marker.length - 1);
  let depth = 0;
  for (let i = from; i < source.length; i++) {
    if (source[i] === "{") depth++;
    else if (source[i] === "}" && --depth === 0) return source.slice(from, i);
  }
  fail(`${label} is not brace-balanced`);
  return "";
}

const spec = readFileSync(SPEC, "utf8");
const prototype = readFileSync(PROTOTYPE, "utf8");
const tokensCss = readFileSync(TOKENS, "utf8");

// ---- 1. versions -----------------------------------------------------------
const specVersion = spec.match(/Status[：:]\s*draft\s+(v[\d.]+)/)?.[1];
const protoVersion = prototype.match(/交互原型\s+(v[\d.]+)/)?.[1];

if (!specVersion) fail("could not read the spec's `Status：draft vX` line");
if (!protoVersion) fail("could not read the prototype's `交互原型 vX` title");
if (specVersion && protoVersion && specVersion !== protoVersion) {
  fail(
    `the spec (${specVersion}) and the prototype (${protoVersion}) are on different ` +
      `versions — they are meant to move together; fix the docs before touching this package`,
  );
}
if (specVersion && specVersion !== ALIGNED_VERSION) {
  fail(
    `the design docs are ${specVersion}, this package is aligned to ${ALIGNED_VERSION}.\n` +
      `      Re-read the spec's §2 token table and §1 direction, update src/tokens.css and\n` +
      `      src/styles.css where they diverge, then set ALIGNED_VERSION = "${specVersion}"\n` +
      `      in this file. Bumping it without reading is how the v0.2/v0.3 drift happened.`,
  );
}

// ---- 2. spec §2 hex values must actually be in the prototype ---------------
const protoLight = declarations(blockAfter(prototype, ":root{", "the prototype's `:root` block"));
const protoDark = declarations(
  blockAfter(prototype, ':root[data-theme="dark"]', "the prototype's dark block"),
);
const protoValues = new Set([...protoLight.values(), ...protoDark.values()]);

const tableStart = spec.indexOf("| 角色");
if (tableStart === -1) {
  fail("could not find the spec's §2 token table (a row starting `| 角色`)");
} else {
  const table = spec.slice(tableStart, spec.indexOf("\n\n", tableStart));
  const specHexes = new Set((table.match(/#[0-9a-f]{6}/gi) ?? []).map((h) => h.toLowerCase()));
  const orphans = [...specHexes].filter((h) => !protoValues.has(h));
  if (orphans.length) {
    fail(
      `spec §2 names ${orphans.join(", ")} but no prototype token carries that value — ` +
        `the spec and the prototype have diverged from each other`,
    );
  }
}

// ---- 3. this package's tokens must equal the prototype's -------------------
const dsLight = declarations(blockAfter(tokensCss, ":root {", "tokens.css `:root`"));
const dsDark = declarations(blockAfter(tokensCss, ':root[data-theme="dark"]', "tokens.css dark"));

// `:root` carries the full palette; the dark block redefines only what actually
// changes (fonts, for one, do not). So light is compared exhaustively, and dark
// is compared on whether the two sides agree about *which* tokens get overridden
// — a token the prototype re-themes but this package doesn't would otherwise
// keep its light value in dark mode and never be noticed.
for (const [protoName, dsName] of Object.entries(MAPPING)) {
  const want = protoLight.get(protoName);
  const got = dsLight.get(dsName);
  if (want === undefined) {
    fail(`the prototype no longer defines --${protoName} (mapped to --${dsName})`);
    continue;
  }
  if (got === undefined) {
    fail(`tokens.css is missing --${dsName} (should mirror --${protoName})`);
    continue;
  }
  if (want !== got) {
    fail(`--${dsName} is "${got}" but the prototype's --${protoName} is "${want}"`);
  }

  const wantDark = protoDark.get(protoName);
  const gotDark = dsDark.get(dsName);
  if (wantDark === undefined && gotDark !== undefined) {
    fail(
      `[dark] tokens.css re-themes --${dsName}, but the prototype leaves --${protoName} at its light value`,
    );
  } else if (wantDark !== undefined && gotDark === undefined) {
    fail(
      `[dark] the prototype re-themes --${protoName} to "${wantDark}", but tokens.css leaves ` +
        `--${dsName} at its light value — dark mode would be wrong`,
    );
  } else if (wantDark !== undefined && wantDark !== gotDark) {
    fail(`[dark] --${dsName} is "${gotDark}" but the prototype's --${protoName} is "${wantDark}"`);
  }
}

// ---- 4. neither side may grow a token the other doesn't know about ---------
for (const name of protoLight.keys()) {
  if (!(name in MAPPING) && !(name in PROTOTYPE_NOT_ADOPTED)) {
    fail(
      `the prototype defines --${name}, which this package neither mirrors nor declines.\n` +
        `      Add it to MAPPING (with a token in src/tokens.css) or to PROTOTYPE_NOT_ADOPTED with a reason.`,
    );
  }
}
const mapped = new Set(Object.values(MAPPING));
for (const name of dsLight.keys()) {
  if (!mapped.has(name) && !(name in DS_ONLY)) {
    fail(
      `tokens.css defines --${name}, which has no prototype counterpart.\n` +
        `      Map it in MAPPING, or record it in DS_ONLY with the reason it is ours alone.`,
    );
  }
}

// ---- 5. every var() in the source must resolve ----------------------------
// Porting markup from the prototype carries its *unprefixed* token names along
// with it (`var(--panel-solid)`), and an unresolvable var() does not error —
// the property silently falls back, so the component renders subtly wrong and
// nothing anywhere complains. Caught once in a ported SVG glyph.
{
  const files = srcFiles(join(pkgRoot, "src")).map((f) => [f, readFileSync(f, "utf8")]);

  // Resolvable = a palette token, or a component-local custom property set
  // somewhere in src/ — a CSS declaration, or a quoted key in a style object
  // (a component may set one in TSX and read it back in CSS, as StatusStrip
  // does for its column count, so this set has to be collected across files).
  const resolvable = new Set(dsLight.keys());
  for (const [file, text] of files) {
    const pattern = file.endsWith(".css") ? /--([a-z0-9-]+)\s*:/gi : /["']--([a-z0-9-]+)["']/gi;
    for (const [, name] of text.matchAll(pattern)) resolvable.add(name.toLowerCase());
  }

  for (const [file, text] of files) {
    for (const [, name] of text.matchAll(/var\(\s*--([a-z0-9-]+)/gi)) {
      const token = name.toLowerCase();
      if (resolvable.has(token)) continue;
      fail(
        `${file.slice(pkgRoot.length + 1)} references var(--${token}), which nothing defines — ` +
          `an unresolvable var() falls back silently instead of erroring` +
          (resolvable.has(`ad-${token}`) ? `. Did you mean --ad-${token}?` : ""),
      );
    }
  }
}

// ---- 6. every prototype class is accounted for ----------------------------
// Token drift is only half of it. When v0.3 landed, the palette was realigned
// but the component roster was not, and the library went on expressing v0.2's
// screens in v0.3's colors — caught only by hand-diffing two prototypes, which
// nothing would have prompted anyone to do. So each of the prototype's
// top-level classes must be claimed here: by a component, by SCAFFOLDING (it
// will never be one), or by KNOWN_GAPS (it should be, and isn't yet). A class
// the prototype grows that nobody has classified fails the build.
{
  const CLASS_TO_COMPONENT = {
    btn: "Button",
    warnbox: "Callout", okbox: "Callout",
    card: "Card",
    chip: "Chip",
    modal: "DangerConfirmDialog", "modal-bg": "DangerConfirmDialog",
    impact: "DangerConfirmDialog", checks: "DangerConfirmDialog", mfoot: "DangerConfirmDialog",
    tablewrap: "DataTable",
    dev: "DeviceRow", dot: "DeviceRow", tag: "DeviceRow",
    effect: "EffectBadge",
    filters: "FilterPills",
    ibar: "IndeterminateBar",
    kv: "KeyValueList",
    logtail: "LogTail", stream: "LogTail",
    nav: "NavItem",
    phases: "PhaseTrack", ph: "PhaseTrack",
    seg: "SegmentedControl",
    tabs: "Tabs",
    window: "WindowFrame", titlebar: "WindowFrame", lights: "WindowFrame",
    "budget-grid": "BudgetMeters", metric: "BudgetMeters", meter: "BudgetMeters",
    "flash-progress-track": "DeterminateProgress",
    "op-list": "OperationList",
    "stage-line": "StageTrack", "stage-node": "StageTrack",
    "summary-strip": "StatusStrip", "summary-cell": "StatusStrip",
    symbol: "Symbol",
    "toolbar-btn": "ToolbarButton", acbtn: "ToolbarButton",
    banner: "RecoveryBanner", ritem: "RecoveryBanner",
    drawer: "JobInspector", job: "JobInspector", rebind: "JobInspector",
    inp: "TextField", radio: "RadioGroup", tagpick: "TagPicker",
    "viewer-page": "ViewerWorkspace", "viewer-lead": "ViewerWorkspace",
    "viewer-toolbar": "ViewerWorkspace", "viewer-status": "ViewerWorkspace",
    "viewer-workspace": "ViewerWorkspace", "viewer-pane": "ViewerWorkspace",
    "viewer-pane-head": "ViewerWorkspace", "viewer-footer": "ViewerWorkspace",
    "viewer-devtools": "ViewerInspectorStack", "viewer-tree-pane": "ViewerInspectorStack",
    "viewer-splitter": "ViewerInspectorStack",
    "viewer-screen-canvas": "ViewerScreenshot", "viewer-screen": "ViewerScreenshot",
    "viewer-hit": "ViewerScreenshot",
    "viewer-tree": "ComponentTree", "viewer-tree-row": "ComponentTree",
    "viewer-tree-id": "ComponentTree", "viewer-chevron": "ComponentTree",
    "viewer-node-icon": "ComponentTree",
    "viewer-inspector": "DumpInspector", "viewer-inspector-head": "DumpInspector",
    "viewer-inspector-title": "DumpInspector", "viewer-breadcrumb": "DumpInspector",
    "viewer-group-title": "DumpInspector",
    "viewer-inspector-body": "DumpInspector", "viewer-kv": "DumpInspector",
    "viewer-disclosure": "DumpInspector", "viewer-raw": "DumpInspector",
  };

  /** Never becomes a component. */
  const SCAFFOLDING = {
    // vs-* 画的是被抓取的那台设备自己的界面（占位截图），不是 ArkDeck 的界面。
    // 生产 Viewer 这里放的是 screenshot.png，所以它们永远不会变成 DS 组件。
    "vs-card": "device-screenshot stand-in", "vs-nav": "device-screenshot stand-in",
    "vs-statusbar": "device-screenshot stand-in", "vs-si": "device-screenshot stand-in",
    "vs-title": "device-screenshot stand-in", "vs-search": "device-screenshot stand-in",
    "vs-avatar": "device-screenshot stand-in", "vs-name": "device-screenshot stand-in",
    "vs-sub": "device-screenshot stand-in", "vs-icon": "device-screenshot stand-in",
    "vs-label": "device-screenshot stand-in", "vs-value": "device-screenshot stand-in",
    "vs-switch": "device-screenshot stand-in", "vs-chev": "device-screenshot stand-in",
    "vs-safe": "device-screenshot stand-in",
    ac: "AC-annotation overlay — spec §5 says the review tool does not ship",
    acin: "AC-annotation overlay", acmode: "AC-annotation overlay",
    main: "page scaffolding", content: "page scaffolding", page: "page scaffolding",
    // Carries `data-page-title` for the title bar and nothing else; it is
    // `display:contents`, so it never becomes a component.
    "page-lead": "page scaffolding",
    sidebar: "page scaffolding", two: "layout grid", grid2: "layout grid",
    "device-layout": "responsive device-detail layout grid",
    "device-section": "device-detail section grouping",
    "device-actions": "device-detail action row",
    "context-menu": "HTML approximation of a native macOS context menu",
    "flash-shell": "Flash page layout",
    "flash-lead": "Flash page heading group",
    "flash-target": "Flash page target summary",
    "flash-target-main": "Flash target text layout",
    "flash-image": "Flash image selection layout",
    "flash-file-icon": "prototype file icon frame",
    "flash-image-copy": "Flash image text layout",
    "flash-actions": "Flash primary action row",
    "flash-impact": "Flash userdata impact copy",
    "flash-progress-card": "Flash running-state layout",
    "flash-progress-head": "Flash progress heading layout",
    "flash-percent": "Flash byte-derived progress value",
    "flash-progress-meta": "Flash progress metadata row",
    "flash-stages": "Flash coarse stage layout",
    "flash-stage": "Flash coarse stage item",
    "flash-result": "Flash terminal result layout",
    "flash-result-icon": "Flash terminal result symbol frame",
    "flash-result-copy": "Flash terminal result text layout",
    "flash-details": "native disclosure for secondary Flash facts",
    "flash-detail-grid": "Flash fact layout inside disclosure",
    sec: "sidebar section heading",
    hint: "text utility", note: "text utility", empty: "empty-state text utility",
    mono: "type utility", livetag: "inline marker in a History row",
    pulse: "animation utility", addlink: "a plain text link",
  };

  /** Should be a component; isn't yet. Reported on every run, never silent.
   *  Empty today — every surface the prototype draws has a component. Put the
   *  next one here rather than leaving it unclassified, so it stays visible. */
  const KNOWN_GAPS = {};

  // Read what the package *exports*, not what some previous build emitted.
  // Anchoring this to the converter's output deadlocks the one workflow the
  // check exists to support: adding a component means updating the mapping,
  // but the bundle cannot be regenerated until the build — which runs this
  // check — passes. src/index.ts answers the question immediately and is the
  // actual source of truth for the package's surface.
  const indexTs = readFileSync(join(pkgRoot, "src", "index.ts"), "utf8");
  const built = new Set(
    [...indexTs.matchAll(/^export\s*\{([^}]*)\}\s*from/gm)]
      .flatMap(([, names]) => names.split(","))
      .map((n) => n.trim().split(/\s+as\s+/).pop())
      .filter((n) => /^[A-Z]/.test(n ?? "")),
  );
  const classes = new Set([...prototype.matchAll(/^\.([a-z][a-z0-9_-]*)/gm)].map((m) => m[1]));

  for (const cls of classes) {
    const component = CLASS_TO_COMPONENT[cls];
    if (component) {
      // a mapping naming a component nobody built is worse than no mapping
      if (built.size && !built.has(component)) {
        fail(`.${cls} maps to a component named ${component}, which this package does not export`);
      }
      continue;
    }
    if (cls in SCAFFOLDING || cls in KNOWN_GAPS) continue;
    fail(
      `the prototype defines .${cls}, which nothing here classifies.\n` +
        `      Add it to CLASS_TO_COMPONENT (and build the component), to SCAFFOLDING if it will\n` +
        `      never be one, or to KNOWN_GAPS with what it should become. This check exists because\n` +
        `      a whole roster of missing components once went unnoticed for exactly this reason.`,
    );
  }

  for (const [cls, component] of Object.entries(CLASS_TO_COMPONENT)) {
    if (!classes.has(cls)) {
      fail(`.${cls} is mapped to ${component} but the prototype no longer defines it`);
    }
  }

  gaps = Object.entries(KNOWN_GAPS).map(([cls, what]) => `.${cls} → ${what}`);
}

// ---- report ----------------------------------------------------------------
if (problems.length) {
  console.error(
    `\n✗ ${problems.length} token drift problem(s) between @arkdeck/ds and the design docs:\n`,
  );
  for (const p of problems) console.error(`  - ${p}`);
  console.error(
    `\n  Docs: docs/design/macos-ux-interaction-spec.md §2, docs/design/prototype.html\n` +
      `  Background: .design-sync/NOTES.md\n`,
  );
  process.exit(1);
}

console.log(
  `@arkdeck/ds matches the design docs (${ALIGNED_VERSION}): ` +
    `${Object.keys(MAPPING).length} tokens × 2 themes, ${Object.keys(DS_ONLY).length} DS-only, ` +
    `every prototype class accounted for`,
);
if (gaps.length) {
  // Printed every run on purpose: a backlog nobody sees is a backlog nobody works.
  console.log(`\n${gaps.length} prototype surface(s) still without a component:`);
  for (const g of gaps) console.log(`  · ${g}`);
  console.log("  (declared in KNOWN_GAPS in this file — build one and move it there once it exists)");
}
