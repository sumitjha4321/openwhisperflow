#!/usr/bin/env bash
# Downloads the ONNX Runtime macOS arm64 C/C++ release into vendor/onnxruntime.
# The dylib is ~44MB and is intentionally not committed to git.
set -euo pipefail

ORT_VERSION="${ORT_VERSION:-1.30.0}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/vendor/onnxruntime"

if [[ -f "$DEST/lib/libonnxruntime.dylib" ]]; then
  echo "onnxruntime already present at $DEST"
  exit 0
fi

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PKG="onnxruntime-osx-arm64-${ORT_VERSION}" ;;
  x86_64) PKG="onnxruntime-osx-x86_64-${ORT_VERSION}" ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

URL="https://github.com/microsoft/onnxruntime/releases/download/v${ORT_VERSION}/${PKG}.tgz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "downloading $PKG ..."
curl -fL --progress-bar -o "$TMP/ort.tgz" "$URL"
tar xzf "$TMP/ort.tgz" -C "$TMP"

mkdir -p "$DEST"
rm -rf "$DEST/include" "$DEST/lib"
cp -R "$TMP/$PKG/include" "$DEST/include"
cp -R "$TMP/$PKG/lib" "$DEST/lib"
rm -rf "$DEST/lib"/*.dSYM

echo "onnxruntime ${ORT_VERSION} installed to $DEST"
