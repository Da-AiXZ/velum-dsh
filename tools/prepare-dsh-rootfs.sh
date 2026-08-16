#!/usr/bin/env bash
#
# prepare-dsh-rootfs.sh — prepare two artifacts for the Xcode build phase:
#
#   1. root.tar.gz        small Alpine 3.21 aarch64 rootfs (+ libgcc only).
#                         This keeps first-launch fakefs_import fast enough for
#                         the iOS scene-create watchdog.
#   2. dsh-runtime.tgz    Node.js (linux-arm64-musl) + @deepseek-ai/dsh and
#                         its full node_modules tree. Xcode copies it into the
#                         app bundle and AppDelegate bind-mounts it read-only
#                         into the guest at /opt/dsh.
#
# Inputs (environment variables):
#   DSH_BUNDLE_TGZ      path to the packed dsh node_modules bundle
#                       (default: <repo>/packaging/dsh-bundle.tgz)
#   OUT_ROOTFS          output rootfs archive (default: <repo>/root.tar.gz)
#   OUT_DSH_RUNTIME     output dsh runtime archive (default: <repo>/dsh-runtime.tgz)
#   ALPINE_ROOTFS_URL   Alpine minirootfs tarball (default v3.21 aarch64)
#   NODE_DIST_URL       Node.js linux-arm64-musl tarball
#   NODE_DIST_SHA256    sha256 of the Node tarball
#   BUILD_NODE_PTY      compile node-pty for linux-arm64 with Docker/qemu
#                       (default: 1 when docker is available)
#
# Docker with `--platform linux/arm64` (qemu-user) is used for apk and for
# building node-pty. Use docker/setup-qemu-action on GitHub Actions or Docker
# Desktop with Rosetta/qemu on macOS.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_BUNDLE_TGZ="${DSH_BUNDLE_TGZ:-$REPO_ROOT/packaging/dsh-bundle.tgz}"
OUT_ROOTFS="${OUT_ROOTFS:-$REPO_ROOT/root.tar.gz}"
OUT_DSH_RUNTIME="${OUT_DSH_RUNTIME:-$REPO_ROOT/dsh-runtime.tgz}"
ALPINE_ROOTFS_URL="${ALPINE_ROOTFS_URL:-https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz}"
NODE_DIST_URL="${NODE_DIST_URL:-https://unofficial-builds.nodejs.org/download/release/v22.22.0/node-v22.22.0-linux-arm64-musl.tar.xz}"
NODE_DIST_SHA256="${NODE_DIST_SHA256:-8f9ba5ec433d56909af00e3d6084c3aec96f1382934f5bc1a4763cbc0282bd43}"
BUILD_NODE_PTY="${BUILD_NODE_PTY:-1}"

for tool in curl tar sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

WORK="$(mktemp -d)"
cleanup() {
  rm -rf "$WORK" 2>/dev/null || true
  if [[ -d "$WORK" ]]; then
    chmod -R u+w "$WORK" 2>/dev/null || sudo chmod -R u+w "$WORK" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || sudo rm -rf "$WORK" 2>/dev/null || true
  fi
}
trap cleanup EXIT
ROOTFS="$WORK/rootfs"
RUNTIME="$WORK/runtime"
mkdir -p "$ROOTFS" "$RUNTIME/bin" "$RUNTIME/lib"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

echo "==> 1/6 preparing small Alpine rootfs"
curl -fL --retry 5 --retry-delay 2 -o "$WORK/alpine.tar.gz" "$ALPINE_ROOTFS_URL"
tar -xzf "$WORK/alpine.tar.gz" -C "$ROOTFS"

echo "==> 2/6 installing libgcc into rootfs"
if command -v docker >/dev/null 2>&1; then
  docker run --rm --platform linux/arm64 \
    -v "$ROOTFS:/mnt" \
    alpine:3.21 \
    apk add --root /mnt --arch aarch64 --no-cache libgcc
  # Files written by the container are root-owned; give them back to the host
  # user so the temporary tree can be cleaned up without sudo.
  docker run --rm --platform linux/arm64 \
    -v "$ROOTFS:/mnt" \
    alpine:3.21 \
    sh -c "chown -R '$HOST_UID:$HOST_GID' /mnt/lib /mnt/var/lib/apk 2>/dev/null || true"
elif command -v apk >/dev/null 2>&1; then
  apk add --root "$ROOTFS" --arch aarch64 --initdb --no-cache libgcc
else
  echo "WARNING: neither docker nor apk is available; libgcc not installed" >&2
fi

# dsh is reached through the bind mount at /opt/dsh.
mkdir -p "$ROOTFS/usr/local/bin"
ln -sfn /opt/dsh/bin/dsh "$ROOTFS/usr/local/bin/dsh"

# Pack the small rootfs now — the runtime copy below is only for the smoke
# test and must not end up inside root.tar.gz.
tar -czf "$OUT_ROOTFS" -C "$ROOTFS" .
echo "==> rootfs: $OUT_ROOTFS ($(du -h "$OUT_ROOTFS" | cut -f1))"

echo "==> 3/6 downloading Node.js (linux-arm64-musl)"
curl -fL --retry 5 --retry-delay 2 -o "$WORK/node.tar.xz" "$NODE_DIST_URL"
if [[ -n "$NODE_DIST_SHA256" ]]; then
  echo "$NODE_DIST_SHA256  $WORK/node.tar.xz" | sha256sum -c -
fi
tar -xJf "$WORK/node.tar.xz" -C "$WORK" node-v22.22.0-linux-arm64-musl/bin/node
cp "$WORK/node-v22.22.0-linux-arm64-musl/bin/node" "$RUNTIME/bin/node"
chmod 0755 "$RUNTIME/bin/node"

echo "==> 4/6 unpacking dsh bundle"
if [[ ! -f "$DSH_BUNDLE_TGZ" ]]; then
  echo "dsh bundle not found: $DSH_BUNDLE_TGZ" >&2
  echo "Build it with: tools/pack-dsh-bundle.sh" >&2
  exit 1
fi
tar -xzf "$DSH_BUNDLE_TGZ" -C "$RUNTIME"
if [[ ! -f "$RUNTIME/node_modules/@deepseek-ai/dsh/lib/bin.js" ]]; then
  echo "dsh bin.js missing after unpacking bundle" >&2
  exit 1
fi

echo "==> 5/6 building node-pty for linux-arm64"
if [[ "$BUILD_NODE_PTY" == "1" && ! -f "$RUNTIME/node_modules/node-pty/build/Release/pty.node" ]]; then
  if command -v docker >/dev/null 2>&1; then
    docker run --rm --platform linux/arm64 \
      -v "$RUNTIME/node_modules:/work/node_modules" \
      -w /work/node_modules/node-pty \
      alpine:3.21 \
      sh -lc '
        set -e
        apk add --no-cache nodejs npm build-base python3 musl-dev linux-headers libgcc
        npm_config_build_from_source=true npm rebuild --build-from-source
      '
    if [[ ! -f "$RUNTIME/node_modules/node-pty/build/Release/pty.node" ]]; then
      echo "node-pty build did not produce build/Release/pty.node" >&2
      exit 1
    fi
    # Hand root-owned build outputs back to the host user for cleanup.
    docker run --rm --platform linux/arm64 \
      -v "$RUNTIME/node_modules:/work/node_modules" \
      alpine:3.21 \
      sh -c "chown -R '$HOST_UID:$HOST_GID' /work/node_modules/node-pty 2>/dev/null || true"
    # The compiled artifacts are now authoritative; drop foreign prebuilds.
    rm -rf "$RUNTIME/node_modules/node-pty/prebuilds"
  else
    echo "ERROR: node-pty linux-arm64 build is missing and docker is unavailable" >&2
    exit 1
  fi
fi

# Node's musl build needs libgcc_s.so.1; bundle it as a fallback even though
# the rootfs now carries libgcc as well.
cp "$ROOTFS/usr/lib/libgcc_s.so.1" "$RUNTIME/lib/libgcc_s.so.1" 2>/dev/null || true

cat > "$RUNTIME/bin/dsh" <<'EOF'
#!/bin/sh
# dsh launcher for Velum. This directory is bind-mounted read-only at
# /opt/dsh; DSH_HOME stays in the writable fakefs.
case "$0" in
  */*) SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd) ;;
  *)   SCRIPT_DIR=$(cd "$(dirname "$(command -v "$0")")" && pwd) ;;
esac
ROOT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
export DSH_HOME="${DSH_HOME:-/root/.dsh}"
export LD_LIBRARY_PATH="$ROOT_DIR/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$ROOT_DIR/bin/node" "$ROOT_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@"
EOF
chmod 0755 "$RUNTIME/bin/dsh"

echo "==> 6/6 packing and smoke-testing the runtime"
tar -czf "$OUT_DSH_RUNTIME" -C "$RUNTIME" .
echo "==> dsh runtime: $OUT_DSH_RUNTIME ($(du -h "$OUT_DSH_RUNTIME" | cut -f1))"

if [[ "${SMOKE_TEST:-1}" == "1" && "$(command -v docker)" != "" ]]; then
  echo "==> smoke test: Node and dsh inside the ARM64 rootfs"
  mkdir -p "$ROOTFS/opt"
  cp -a "$RUNTIME" "$ROOTFS/opt/dsh"
  docker run --rm --platform linux/arm64 \
    -v "$ROOTFS:/mnt" \
    alpine:3.21 \
    sh -lc '
      set -e
      echo "node: $(chroot /mnt /opt/dsh/bin/node --version)"
      echo "dsh:  $(chroot /mnt /opt/dsh/bin/dsh --version)"
    '
fi

echo "==> done"
