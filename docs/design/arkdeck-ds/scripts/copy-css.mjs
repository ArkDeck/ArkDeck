import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkgRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const dist = join(pkgRoot, "dist");
mkdirSync(dist, { recursive: true });

// tokens.css ships standalone for consumers that only want the palette.
copyFileSync(join(pkgRoot, "src", "tokens.css"), join(dist, "tokens.css"));

// dist/styles.css must be self-contained: consumers (and claude.ai/design's
// render pipeline) receive only this file's transitive @import closure, and a
// relative sibling import does not survive being copied into a bundle root.
// So the tokens are inlined here rather than imported.
const tokens = readFileSync(join(pkgRoot, "src", "tokens.css"), "utf8");
const styles = readFileSync(join(pkgRoot, "src", "styles.css"), "utf8").replace(
  /^@import\s+"\.\/tokens\.css";\s*/m,
  "",
);
writeFileSync(join(dist, "styles.css"), `${tokens}\n${styles}`);
console.log("wrote dist/tokens.css and self-contained dist/styles.css");
