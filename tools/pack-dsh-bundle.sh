#!/usr/bin/env bash
#
# pack-dsh-bundle.sh — install @deepseek-ai/dsh + its dependency tree for
# linux-arm64-musl and pack everything into packaging/dsh-bundle.tgz.
#
# Run on any machine with Node.js >= 20 and network access to npm. The
# resulting tarball is consumed by tools/prepare-dsh-rootfs.sh.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_DIR="$REPO_ROOT/packaging/dsh-bundle"
OUT_TGZ="${OUT_TGZ:-$REPO_ROOT/packaging/dsh-bundle.tgz}"

if [[ ! -f "$BUNDLE_DIR/package.json" ]]; then
  echo "missing $BUNDLE_DIR/package.json" >&2
  exit 1
fi

echo "==> npm ci (linux/arm64/musl) in $BUNDLE_DIR"
npm ci \
  --prefix "$BUNDLE_DIR" \
  --ignore-scripts \
  --os=linux \
  --cpu=arm64 \
  --libc=musl \
  --no-audit \
  --no-fund

# node-pty publishes only win32/darwin prebuilds; its linux-arm64 binary is
# compiled during rootfs preparation (see tools/prepare-dsh-rootfs.sh).
# Drop foreign prebuilds here to keep the bundle small.
NODE_PTY_PREBUILDS="$BUNDLE_DIR/node_modules/node-pty/prebuilds"
if [[ -d "$NODE_PTY_PREBUILDS" ]]; then
  rm -rf "$NODE_PTY_PREBUILDS"
fi

# iSH's Node (unofficial linux-arm64-musl build) exposes corrupt values in
# process.binding('constants').os.signals (observed: SIGTERM = 0.9375 instead
# of 15, and several entries are read-only). libuv truncates that to signum 0
# and uv_signal_start fails with EINVAL. The table cannot be repaired, so
# replace dsh's process.on("SIGTERM"/"SIGINT") calls with direct signal_wrap
# registrations using the correct numeric signal numbers.
echo "==> patching dsh signal registration for iSH compatibility"
node --input-type=commonjs - "$BUNDLE_DIR/node_modules/@deepseek-ai/dsh/lib" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const specs = [
  { sig: 'SIGTERM', num: 15, body: 'interrupt(0);' },
  { sig: 'SIGINT', num: 2, body: 'interrupt(130);' },
];
let changed = false;
for (const name of fs.readdirSync(dir)) {
  if (!name.startsWith('profile-boot-') || !name.endsWith('.js')) continue;
  const file = path.join(dir, name);
  let source = fs.readFileSync(file, 'utf8');
  for (const { sig, num, body } of specs) {
    const re = new RegExp(`process\\.on\\("${sig}", \\(\\) => \\{[\\s\\S]*?\\}\\);`);
    source = source.replace(re, () => {
      changed = true;
      return `(() => {
    try {
      const _SignalClass = process.binding("signal_wrap").Signal;
      const _wrap = new _SignalClass();
      _wrap.unref();
      _wrap.onsignal = () => { ${body} };
      const _err = _wrap.start(${num});
      if (_err) process.stderr.write("[dsh] ${sig} handler unavailable: uv_signal_start " + _err + "\\n");
    } catch (signalErr) {
      process.stderr.write("[dsh] ${sig} handler unavailable: " + (signalErr && signalErr.message ? signalErr.message : signalErr) + "\\n");
    }
  })();`;
    });
  }
  // sharp's musl/arm64 native module takes the whole Node process down on
  // iSH before JS can even throw. Keep the attachment service active (other
  // plugins depend on it) but replace sharp with a safe stub: attachment
  // admission calls throw INVALID_IMAGE instead of loading the native addon.
  const attachmentFile = path.join(dir, '..', '..', 'dsh-attachment-local', 'lib', 'index.js');
  const attachmentSource = fs.readFileSync(attachmentFile, 'utf8');
  const sharpImport = 'import sharp from "sharp";';
  if (attachmentSource.includes(sharpImport)) {
    fs.writeFileSync(
      attachmentFile,
      attachmentSource.replace(sharpImport, `// sharp-disabled-for-ish: its native loader exits the process\nconst sharp = (_data, _options) => { throw new AttachmentError("Image processing is unavailable on this device.", "INVALID_IMAGE"); };`)
    );
    changed = true;
    process.stderr.write('[dsh] sharp stubbed in attachment-local for iSH\n');
  } else {
    process.stderr.write('[dsh] WARNING: sharp import not found in attachment-local\n');
  }

  // Instrument the boot boundary so a silent exit-1 still tells us exactly
  // which stage failed.
  const bootOld = `\tconst ctx = await boot(NAME, rootConfig, structuredClone(allPatches(composed)), (hostCtx) => {
\t\tapp.current = hostCtx;
\t\thostCtx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, options.environment);
\t\tprovideCmdline(hostCtx, {
\t\t\targs: options.args,
\t\t\texit: (code) => void shutdown.shutdown(code)
\t\t});
\t});`;
  const bootNew = `\tprocess.stderr.write("[dsh] boot: before boot\\n");
\tlet ctx;
\ttry {
\t\tctx = await boot(NAME, rootConfig, structuredClone(allPatches(composed)), (hostCtx) => {
\t\t\tapp.current = hostCtx;
\t\t\thostCtx.provide(DSH_LAUNCH_ENVIRONMENT_KEY, options.environment);
\t\t\tprovideCmdline(hostCtx, {
\t\t\t\targs: options.args,
\t\t\t\texit: (code) => void shutdown.shutdown(code)
\t\t\t});
\t\t});
\t\tprocess.stderr.write("[dsh] boot: mounted, state=" + (ctx.fiber && ctx.fiber.state) + "\\n");
\t} catch (bootErr) {
\t\tprocess.stderr.write("[dsh] boot FAILED: " + (bootErr && bootErr.stack ? bootErr.stack : bootErr) + "\\n");
\t\tthrow bootErr;
\t}`;
  if (source.includes(bootOld)) {
    source = source.replace(bootOld, bootNew);
    changed = true;
  } else {
    process.stderr.write('[dsh] WARNING: boot boundary not found; continuing\n');
  }
  fs.writeFileSync(file, source);
}

// Node under iSH runs with --jitless, which removes WebAssembly. The
// dsh wrapper passes the bundled polyfills via --require, and this patch is
// a fallback for direct `node bin.js` runs: load the same polyfills as the
// first body statements so WebAssembly/fetch exist before the tree boots.
const binFile = path.join(dir, 'bin.js');
let binSource = fs.readFileSync(binFile, 'utf8');
if (!binSource.includes('dsh-polyfill-preload')) {
  binSource = binSource.replace(
    'import { readFileSync } from "node:fs";',
    `import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const dshPreloadRequire = createRequire(import.meta.url);
try { dshPreloadRequire("/opt/dsh/lib/wasm-polyfill.cjs"); } catch (dshPreloadErr) { process.stderr.write("[dsh] wasm-polyfill preload failed: " + dshPreloadErr.message + "\\n"); }
try { dshPreloadRequire("/opt/dsh/lib/fetch-polyfill.cjs"); } catch (dshPreloadErr) { process.stderr.write("[dsh] fetch-polyfill preload failed: " + dshPreloadErr.message + "\\n"); }
// dsh-polyfill-preload`
  );
  if (!binSource.includes('dsh-polyfill-preload')) {
    process.stderr.write('[dsh] ERROR: could not inject polyfill preload (import anchor not found)\n');
    process.exit(2);
  }
  fs.writeFileSync(binFile, binSource);
  changed = true;
  process.stderr.write('[dsh] bin.js polyfill preload injected\n');
} else {
  process.stderr.write('[dsh] bin.js polyfill preload already present\n');
}

if (!changed) {
  process.stderr.write('[dsh] WARNING: signal registration patch target not found\n');
  process.exit(2);
}
NODE

echo "==> packing $OUT_TGZ"
tar -czf "$OUT_TGZ" \
  -C "$BUNDLE_DIR" \
  node_modules package.json package-lock.json

echo "==> done: $OUT_TGZ ($(du -h "$OUT_TGZ" | cut -f1))"
