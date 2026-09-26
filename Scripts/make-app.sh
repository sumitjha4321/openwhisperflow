#!/usr/bin/env bash
# Builds OpenWhisperFlow.app.
#
# A real .app bundle is not optional here: macOS ties Accessibility and
# microphone grants to a bundle identifier and code signature, and a bare
# executable from .build has neither.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_ID="${BUNDLE_ID:-app.openwhisperflow}"
VERSION="${VERSION:-0.1.0}"
APP="$ROOT/dist/OpenWhisperFlow.app"

if [[ ! -f vendor/onnxruntime/lib/libonnxruntime.dylib ]]; then
  echo "onnxruntime is missing; running Scripts/fetch-onnxruntime.sh"
  ./Scripts/fetch-onnxruntime.sh
fi

echo "building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product OpenWhisperFlow

BINARY="$(swift build -c "$CONFIGURATION" --product OpenWhisperFlow --show-bin-path)/OpenWhisperFlow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/OpenWhisperFlow"

# The executable links @rpath/libonnxruntime.1.dylib and carries an
# @executable_path/../Frameworks rpath, so the dylib goes in under that name.
cp vendor/onnxruntime/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/libonnxruntime.1.dylib"

# The icon is generated rather than stored as a binary asset. Without one, the
# app appears as a blank generic icon in System Settings' privacy lists.
ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$ROOT/Scripts/GenerateIcon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>OpenWhisperFlow</string>
    <key>CFBundleDisplayName</key>
    <string>OpenWhisperFlow</string>
    <key>CFBundleExecutable</key>
    <string>OpenWhisperFlow</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, and the app never becomes frontmost. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>OpenWhisperFlow records your voice while you hold the dictation key and transcribes it on this Mac.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Dev builds carry an absolute rpath into vendor/onnxruntime so that binaries
# under .build can find the dylib. The bundle has its own copy in
# Contents/Frameworks, so that machine-specific path is removed here.
VENDOR_RPATH="$ROOT/vendor/onnxruntime/lib"
if otool -l "$APP/Contents/MacOS/OpenWhisperFlow" | grep -q "$VENDOR_RPATH"; then
  install_name_tool -delete_rpath "$VENDOR_RPATH" "$APP/Contents/MacOS/OpenWhisperFlow"
fi

# A secure timestamp is mandatory for notarisation and pointless (and slow,
# it contacts Apple) otherwise. Scripts/release.sh overrides this.
# A single token, so it stays a plain string: bash 3.2 (the /bin/bash macOS
# ships) cannot expand a default for an unset array under `set -u`.
TIMESTAMP_FLAG="${TIMESTAMP_FLAG:---timestamp=none}"

# Signing matters for more than Gatekeeper here: macOS keys the Accessibility
# grant to the code signature. A real certificate keeps that identity stable
# across rebuilds, so the permission survives; an ad-hoc signature changes every
# build and makes macOS forget. Prefer a certificate, fall back to ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="-"
  echo "signing ad-hoc (no certificate found)"
else
  echo "signing with: $SIGN_IDENTITY"
fi

# The hardened runtime is what notarisation requires, so release and dev builds
# are signed the same way — a permission problem it introduces then shows up
# here rather than only in a notarised build. Scripts/release.sh adds
# --timestamp, which needs the network and is not worth it for a local build.
HARDENED=(--options runtime --entitlements "$ROOT/Scripts/OpenWhisperFlow.entitlements")

codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    $TIMESTAMP_FLAG \
    "$APP/Contents/Frameworks/libonnxruntime.1.dylib" >/dev/null
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
    $TIMESTAMP_FLAG "${HARDENED[@]}" "$APP" >/dev/null

echo
echo "built $APP"
echo
echo "next steps:"
echo "  1. open dist/ and drag OpenWhisperFlow.app to /Applications (recommended)"
echo "  2. launch it, then grant Microphone and Accessibility access when asked"
echo "  3. download a model from the app's Settings > Model tab"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo
  echo "note: an ad-hoc signature changes on every rebuild, so macOS may ask for"
  echo "Accessibility again. If the toggle looks stuck, run:"
  echo "  tccutil reset Accessibility $BUNDLE_ID"
fi
