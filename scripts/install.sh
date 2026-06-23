#!/bin/zsh
# Build, install to /Applications, and sign with the stable local identity.
#
# Why this exists: macOS ties Accessibility and Screen Recording grants to the
# app's code signature AND its location. Running from the build folder churns
# both on every rebuild, so the system shows a checked permission box that no
# longer matches the running binary. Installing to a fixed /Applications path
# and signing with one stable certificate means a grant, once given, persists
# across every future rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="AICF Local Dev Signing"
APP="/Applications/Pilcrow.app"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "Signing identity '$IDENTITY' not found in the keychain."
  echo "Create it once with scripts/make-signing-cert.sh, then re-run this."
  exit 1
fi

echo "Building (Release, owner build — licensing bypassed)…"
xcodegen generate >/dev/null
# OWNER_BUILD flips LicenseManager.ownerOverride on, so a local install never
# hits the license gate. The distribution build (scripts/release.sh) omits it
# and enforces the key.
xcodebuild -project AIContentFilter.xcodeproj -scheme AIContentFilter \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OWNER_BUILD' build >/dev/null

echo "Installing to ${APP}…"
pkill -x Pilcrow 2>/dev/null || true
pkill -x AIContentFilter 2>/dev/null || true   # stop any pre-rename build
sleep 1
rm -rf "$APP" /Applications/AIContentFilter.app
cp -R .build/DerivedData/Build/Products/Release/Pilcrow.app "$APP"

echo "Signing in place…"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "signature OK"

echo "Launching…"
open "$APP"
echo "Done. Grant Accessibility once if asked — it will persist from now on."
