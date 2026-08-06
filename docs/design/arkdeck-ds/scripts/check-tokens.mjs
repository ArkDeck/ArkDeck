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

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// Bump ONLY after re-reading the docs and confirming this package still
// expresses them. This is the deliberate acknowledgement step: a docs version
// bump is exactly the event that silently invalidated the library once.
const ALIGNED_VERSION = "v0.3";

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
  `tokens match the design docs (${ALIGNED_VERSION}): ` +
    `${Object.keys(MAPPING).length} mapped × 2 themes, ${Object.keys(DS_ONLY).length} DS-only`,
);
