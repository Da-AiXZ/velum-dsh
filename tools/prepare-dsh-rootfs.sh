#!/usr/bin/env bash
#
# prepare-dsh-rootfs.sh — build a Velum/iSH ARM64 rootfs with Node.js + dsh
# preinstalled, then repack it as root.tar.gz for the Xcode "Download Root"
# build phase.
#
# Inputs (environment variables):
#   DSH_BUNDLE_TGZ      path to the packed dsh node_modules bundle
#                       (default: <repo>/packaging/dsh-bundle.tgz)
#   OUT_ROOTFS          output path (default: <repo>/root.tar.gz)
#   ALPINE_ROOTFS_URL   Alpine minirootfs tarball (default v3.21 aarch64)
#   NODE_DIST_URL       Node.js linux-arm64-musl tarball
#   NODE_DIST_SHA256    optional sha256 of the Node tarball
#   BUILD_NODE_PTY      compile node-pty for linux-arm64 with Docker/qemu
#                       (default: 1 when docker is available)
#
# The script runs on Linux or macOS with bash, curl, and tar. The optional
# node-pty compile step runs an arm64 Alpine container under qemu-user, so a
# plain `docker run --platform linux/arm64` must work (Docker Desktop on macOS,
# or docker/setup-qemu-action on GitHub Actions).
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DSH_BUNDLE_TGZ="${DSH_BUNDLE_TGZ:-$REPO_ROOT/packaging/dsh-bundle.tgz}"
OUT_ROOTFS="${OUT_ROOTFS:-$REPO_ROOT/root.tar.gz}"
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
trap 'rm -rf "$WORK"' EXIT
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"

echo "==> 1/6 downloading Alpine minirootfs"
curl -fL --retry 5 --retry-delay 2 -o "$WORK/alpine.tar.gz" "$ALPINE_ROOTFS_URL"
tar -xzf "$WORK/alpine.tar.gz" -C "$ROOTFS"

echo "==> 2/6 installing Node.js (linux-arm64-musl) to /opt/node"
curl -fL --retry 5 --retry-delay 2 -o "$WORK/node.tar.xz" "$NODE_DIST_URL"
if [[ -n "$NODE_DIST_SHA256" ]]; then
  echo "$NODE_DIST_SHA256  $WORK/node.tar.xz" | sha256sum -c -
fi
mkdir -p "$ROOTFS/opt"
tar -xJf "$WORK/node.tar.xz" -C "$ROOTFS/opt" --strip-components=1
test -x "$ROOTFS/opt/bin/node"

echo "==> 3/6 unpacking dsh bundle into /opt/dsh"
if [[ ! -f "$DSH_BUNDLE_TGZ" ]]; then
  echo "dsh bundle not found: $DSH_BUNDLE_TGZ" >&2
  echo "Build it with: tools/pack-dsh-bundle.sh" >&2
  exit 1
fi
mkdir -p "$ROOTFS/opt/dsh"
tar -xzf "$DSH_BUNDLE_TGZ" -C "$ROOTFS/opt/dsh"
if [[ ! -f "$ROOTFS/opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" ]]; then
  echo "dsh bin.js missing after unpacking bundle" >&2
  exit 1
fi

echo "==> 4/6 installing libgcc into rootfs (Node musl build needs libgcc_s.so.1)"
if command -v docker >/dev/null 2>&1; then
  docker run --rm --platform linux/arm64 \
    -v "$ROOTFS:/mnt" \
    alpine:3.21 \
    apk add --root /mnt --arch aarch64 --no-cache libgcc
elif command -v apk >/dev/null 2>&1; then
  apk add --root "$ROOTFS" --arch aarch64 --initdb --no-cache libgcc
else
  echo "WARNING: neither docker nor apk is available; libgcc not installed" >&2
fi

echo "==> 5/6 building node-pty for linux-arm64 (needed by dsh subprocess runtime)"
if [[ "$BUILD_NODE_PTY" == "1" && ! -f "$ROOTFS/opt/dsh/node_modules/node-pty/build/Release/pty.node" ]]; then
  if command -v docker >/dev/null 2>&1; then
    docker run --rm --platform linux/arm64 \
      -v "$ROOTFS/opt/dsh/node_modules:/work/node_modules" \
      -w /work/node_modules/node-pty \
      alpine:3.21 \
      sh -lc '
        set -e
        apk add --no-cache nodejs npm build-base python3 musl-dev linux-headers libgcc
        npm_config_build_from_source=true npm rebuild --build-from-source
      '
    if [[ ! -f "$ROOTFS/opt/dsh/node_modules/node-pty/build/Release/pty.node" ]]; then
      echo "node-pty build did not produce build/Release/pty.node" >&2
      exit 1
    fi
    # The compiled artifacts are now authoritative; drop foreign prebuilds.
    rm -rf "$ROOTFS/opt/dsh/node_modules/node-pty/prebuilds"
  else
    echo "ERROR: node-pty linux-arm64 build is missing and docker is unavailable" >&2
    exit 1
  fi
fi

echo "==> 6/6 writing launcher and packing root.tar.gz"
mkdir -p "$ROOTFS/opt/dsh/bin" "$ROOTFS/usr/local/bin"
cat > "$ROOTFS/opt/dsh/bin/dsh" <<'EOF'
#!/bin/sh
# dsh launcher for Velum. DSH_HOME lives in the fakefs, so sessions and
# credentials survive app restarts.
export DSH_HOME="${DSH_HOME:-/root/.dsh}"
exec /opt/node/bin/node /opt/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"
EOF
chmod 0755 "$ROOTFS/opt/dsh/bin/dsh"
ln -sfn /opt/dsh/bin/dsh "$ROOTFS/usr/local/bin/dsh"

tar -czf "$OUT_ROOTFS" -C "$ROOTFS" .
echo "==> done: $OUT_ROOTFS ($(du -h "$OUT_ROOTFS" | cut -f1))"
