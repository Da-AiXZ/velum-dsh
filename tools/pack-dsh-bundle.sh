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

# iSH's Node (unofficial linux-arm64-musl build) exposes corrupt non-integer
# values for some entries in process.binding('constants').os.signals
# (observed: SIGTERM = 0.9375 instead of 15). libuv truncates that to signum
# 0 and uv_signal_start fails with EINVAL. Fix the standard signal table
# before dsh's SIGTERM/SIGINT handlers are registered.
echo "==> patching dsh signal registration for iSH compatibility"
node --input-type=commonjs - "$BUNDLE_DIR/node_modules/@deepseek-ai/dsh/lib" <<'NODE'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const signalFix = `try {
  const _signals = process.binding("constants").os.signals;
  const _std = {SIGHUP:1,SIGINT:2,SIGQUIT:3,SIGILL:4,SIGTRAP:5,SIGABRT:6,
    SIGBUS:7,SIGFPE:8,SIGKILL:9,SIGUSR1:10,SIGSEGV:11,SIGUSR2:12,
    SIGPIPE:13,SIGALRM:14,SIGTERM:15,SIGCHLD:17,SIGCONT:18,SIGSTOP:19,
    SIGTSTP:20,SIGTTIN:21,SIGTTOU:22,SIGURG:23,SIGXCPU:24,SIGXFSZ:25,
    SIGVTALRM:26,SIGPROF:27,SIGWINCH:28,SIGIO:29,SIGPWR:30,SIGSYS:31};
  for (const [_name, _num] of Object.entries(_std)) {
    if (typeof _signals[_name] === "number" && !Number.isInteger(_signals[_name]))
      _signals[_name] = _num;
  }
} catch (_signalFixErr) {
  process.stderr.write("[dsh] signal constants fix failed: " + _signalFixErr.message + "\\n");
}`;
let changed = false;
for (const name of fs.readdirSync(dir)) {
  if (!name.startsWith('profile-boot-') || !name.endsWith('.js')) continue;
  const file = path.join(dir, name);
  let source = fs.readFileSync(file, 'utf8');
  if (!source.includes(signalFix.trim())) {
    source = source.replace('process.on("SIGTERM"', `${signalFix}\n\tprocess.on("SIGTERM"`);
    changed = true;
  }
  for (const sig of ['SIGTERM', 'SIGINT']) {
    const re = new RegExp(`process\\.on\\("${sig}", \\(\\) => \\{[\\s\\S]*?\\}\\);`);
    source = source.replace(re, (match) => {
      changed = true;
      return `try { ${match} } catch (signalErr) { process.stderr.write("[dsh] ${sig} handler unavailable: " + signalErr.message + "\\n"); }`;
    });
  }
  fs.writeFileSync(file, source);
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
