#!/usr/bin/env bash
# Runs the unit tests.
#
# swift-testing and XCTest live inside Xcode, so `swift test` needs the active
# developer directory to point at Xcode rather than at the Command Line Tools.
# This picks Xcode up automatically instead of requiring `sudo xcode-select -s`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ ! -d "$(xcode-select -p)/Platforms" ]]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [[ -d "$candidate/Contents/Developer" ]]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      echo "using $DEVELOPER_DIR"
      break
    fi
  done
fi

exec swift test "$@"
