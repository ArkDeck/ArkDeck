// Bundle every design preview, one entry point each.
//
// The audit used to assert that all 32 previews bundle independently; that was
// a hand-run loop nobody could repeat (F52-8). Bundling them individually — not
// as one combined entry — is the point: a preview that only compiles because a
// sibling imported something for it would still pass a combined build.
import {build} from 'esbuild';
import {readdirSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {join, basename} from 'node:path';

const packageRoot = fileURLToPath(new URL('..', import.meta.url));
const previewDir = join(packageRoot, '../../../.design-sync/previews');
const outDir = join(packageRoot, 'dist/previews');

const entries = readdirSync(previewDir).filter(name => name.endsWith('.tsx')).sort();
if (entries.length === 0) {
  console.error('build-previews: no previews found at', previewDir);
  process.exit(1);
}

let failed = 0;
for (const entry of entries) {
  try {
    await build({
      entryPoints: [join(previewDir, entry)],
      bundle: true,
      format: 'esm',
      jsx: 'automatic',
      logLevel: 'silent',
      alias: {
        '@arkdeck/ds': join(packageRoot, 'src/index.ts'),
        react: join(packageRoot, 'node_modules/react'),
        'react-dom': join(packageRoot, 'node_modules/react-dom'),
      },
      outfile: join(outDir, basename(entry, '.tsx') + '.js'),
    });
  } catch (error) {
    failed += 1;
    console.error(`build-previews: ${entry} failed\n${error.message}`);
  }
}

if (failed > 0) {
  console.error(`build-previews: ${failed} of ${entries.length} previews failed to bundle`);
  process.exit(1);
}
console.log(`build-previews: ${entries.length} previews bundled independently`);
