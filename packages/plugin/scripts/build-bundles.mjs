import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')

await build({
  entryPoints: [join(root, 'src/index.ts')],
  bundle: true,
  platform: 'node',
  format: 'esm',
  sourcemap: true,
  outfile: join(root, 'dist/index.js'),
  external: ['@deepseek-ai/*', '@roamhq/wrtc', 'qrcode', 'werift', 'ws'],
})

// Two consumers, two formats:
//  - the Desktop/web loader imports the entry as an ES module, so `client.js` is ESM;
//  - the GitHub-root bundle is injected as a classic script, so it stays an IIFE.
for (const [moduleId, outfile, format] of [
  ['ds-harness-remote', 'client.js', 'esm'],
  ['ds-harness-remote', 'client.github.js', 'iife'],
]) {
  await build({
    entryPoints: [join(root, 'src/client.ts')],
    bundle: true,
    platform: 'browser',
    format,
    minifySyntax: true,
    define: {
      DSH_REMOTE_CLIENT_MODULE_ID: JSON.stringify(moduleId),
    },
    outfile: join(root, 'dist', outfile),
  })
}
