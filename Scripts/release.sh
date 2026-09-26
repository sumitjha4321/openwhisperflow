#!/usr/bin/env bash
# Builds, notarises and packages a release, then writes the Homebrew cask that
# points at it.
#
#   ./Scripts/release.sh 0.2.0
#
# What comes out, in dist/:
#   OpenWhisperFlow-<version>-arm64.zip   the artefact a cask downloads
#   openwhisperflow.rb                    the cask, with url and sha256 filled in
#
# Notarisation is what makes `brew install --cask` work for anyone else:
# Homebrew quarantines what it downloads, so Gatekeeper refuses to open an app
# that Apple has not notarised. It needs a paid Apple Developer account, a
# "Developer ID Application" certificate, and these in the environment:
#
#   NOTARY_PROFILE   a keychain profile name, stored once with
#                    xcrun notarytool store-credentials
#
# or, instead of a profile:
#
#   NOTARY_APPLE_ID  the Apple ID that owns the certificate
#   NOTARY_TEAM_ID   its team ID (Developer ID Application: Name (TEAMID))
#   NOTARY_PASSWORD  an app-specific password from appleid.apple.com
#
# Without any of those the script still produces a zip and a cask, but says so
# loudly: that build is for people who will clone the repo, not for a tap.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   e.g. $0 0.2.0" >&2
  exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must look like 1.2.3, got: $VERSION" >&2
  exit 64
fi

BUNDLE_ID="${BUNDLE_ID:-app.openwhisperflow}"
# The repo the cask downloads from. Override if you fork or rename.
GH_REPO="${GH_REPO:-sumitjha4321/openwhisperflow}"

ARCH="$(uname -m)"
APP="$ROOT/dist/OpenWhisperFlow.app"
ZIP="$ROOT/dist/OpenWhisperFlow-${VERSION}-${ARCH}.zip"
CASK="$ROOT/dist/openwhisperflow.rb"

# A release has to be signed with a Developer ID; an "Apple Development"
# certificate only satisfies Gatekeeper on machines enrolled for development,
# and cannot be notarised at all.
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi

NOTARISE=1
if [[ -z "$SIGN_IDENTITY" ]]; then
  NOTARISE=0
  echo "!! no 'Developer ID Application' certificate in the keychain."
elif [[ -z "${NOTARY_PROFILE:-}" && -z "${NOTARY_APPLE_ID:-}" ]]; then
  NOTARISE=0
  echo "!! no notarisation credentials (NOTARY_PROFILE or NOTARY_APPLE_ID)."
fi

# ---------------------------------------------------------------- build

# --timestamp asks Apple's timestamp server to countersign. Notarisation
# rejects a signature without it.
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$SIGN_IDENTITY" TIMESTAMP_FLAG="--timestamp" VERSION="$VERSION" \
    BUNDLE_ID="$BUNDLE_ID" ./Scripts/make-app.sh
else
  VERSION="$VERSION" BUNDLE_ID="$BUNDLE_ID" ./Scripts/make-app.sh
fi

# ---------------------------------------------------------------- notarise

# ditto, not zip: it preserves the symlinks and extended attributes inside a
# bundle, and a zip(1) archive of an .app can arrive with a broken signature.
package() {
  rm -f "$ZIP"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
}

if (( NOTARISE )); then
  package
  echo
  echo "submitting to Apple for notarisation (this takes a few minutes)…"
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
  fi

  # Stapling writes Apple's ticket into the bundle so it opens offline, which
  # means the submitted zip is now stale and has to be rebuilt around the
  # stapled .app.
  xcrun stapler staple "$APP"
  package

  echo
  echo "verifying as Gatekeeper will see it:"
  spctl --assess --type execute --verbose=2 "$APP"
else
  package
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{ print $1 }')"

# ---------------------------------------------------------------- cask

# Written here rather than kept as a checked-in file with placeholders, so the
# url, version and checksum cannot drift apart from the artefact.
cat > "$CASK" <<CASKFILE
cask "openwhisperflow" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/${GH_REPO}/releases/download/v#{version}/OpenWhisperFlow-#{version}-${ARCH}.zip"
  name "OpenWhisperFlow"
  desc "Menu bar app for push-to-talk dictation, transcribed on-device"
  homepage "https://github.com/${GH_REPO}"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The shipped binary and the bundled ONNX Runtime dylib are both ${ARCH}.
  depends_on arch: :${ARCH}
  # Homebrew reads a bare symbol as "this version or newer".
  depends_on macos: :sonoma

  app "OpenWhisperFlow.app"

  uninstall quit: "${BUNDLE_ID}"

  # Preferences, and any downloaded speech model, live in one directory.
  # The Microphone and Accessibility grants are held by macOS and cannot be
  # removed from here; "tccutil reset Accessibility ${BUNDLE_ID}" does that.
  zap trash: [
    "~/Library/Application Support/OpenWhisperFlow",
    "~/Library/Saved Application State/${BUNDLE_ID}.savedState",
  ]
end
CASKFILE

echo
echo "version  $VERSION"
echo "zip      $ZIP"
echo "sha256   $SHA"
echo "cask     $CASK"
echo

if (( ! NOTARISE )); then
  cat <<'WARN'
!! NOT NOTARISED.

Homebrew quarantines every file it downloads, and Gatekeeper refuses to open a
quarantined app that Apple has not notarised — so this zip will not install
cleanly through a cask on anyone else's Mac. They would see "OpenWhisperFlow is
damaged and can't be opened" and need --no-quarantine to get past it.

To fix it properly: join the Apple Developer Program, create a "Developer ID
Application" certificate, run

  xcrun notarytool store-credentials openwhisperflow \
      --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

and then re-run this script with NOTARY_PROFILE=openwhisperflow.

WARN
fi

cat <<NEXT
next steps:

  1. commit and tag this version
       git tag -a v${VERSION} -m "v${VERSION}" && git push origin v${VERSION}

  2. publish the release the cask's url points at
       gh release create v${VERSION} "${ZIP}" \\
           --repo ${GH_REPO} --title "v${VERSION}" --generate-notes

  3. copy the cask into your tap and push it
       cp "${CASK}" ../homebrew-tap/Casks/o/openwhisperflow.rb

  4. check it end to end
       brew install --cask ${GH_REPO%%/*}/tap/openwhisperflow
NEXT
