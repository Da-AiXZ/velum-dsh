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

# iSH's rt_sigaction is incomplete enough that libuv's uv_signal_start can
# fail with EINVAL. dsh's SIGTERM/SIGINT handlers are only used for graceful
# shutdown, so wrap their registration in try/catch — the agent still works,
# and the window-close path kills the process anyway.
echo "==> patching dsh signal registration for iSH compatibility"
node - "$BUNDLE_DIR/node_modules/@deepseek-ai/dsh/lib" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
let changed = false;
for (const name of fs.readdirSync(dir)) {
  if (!name.startsWith('profile-boot-') || !name.endsWith('.js')) continue;
  const file = path.join(dir, name);
  let source = fs.readFileSync(file, 'utf8');
  for (const sig of ['SIGTERM', 'SIGINT']) {
    const re = new RegExp(`process\\.on\\("${sig}", \\(\\) => \\{[\\s\\S]*?\\}\\);`);
    source = source.replace(re, (match) => {
      changed = true;
      return `try { ${match} } catch (signalErr) { process.stderr.write("[dsh] ${sig} handler unavailable: " + signalErr.message + "\\n"); }`;
    });
  }
  if (changed) fs.writeFileSync(file, source);
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
