// Bundles the standalone overlay (React included) into the Flan server's
// static dir, where `include_str!` embeds it as `/flan.js`.
import { build } from 'esbuild';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const outfile = resolve(here, '../../../server/flan_server/static/flan.js');

await build({
  entryPoints: [resolve(here, '../src/standalone.tsx')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: 'es2020',
  jsx: 'automatic',
  define: { 'process.env.NODE_ENV': '"production"' },
  outfile,
  logLevel: 'info',
});
