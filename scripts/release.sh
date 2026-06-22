#!/bin/zsh
# Build, sign, notarize, staple, and package Veritas into a distributable DMG.
#
# This is the direct-distribution release pipeline. Veritas is sold as a
# notarized download (no App Store), so this needs a paid Apple Developer
# account. Until you have one, the script stops at the first missing piece and
# prints exactly what to set up. scripts/install.sh stays the local-dev path.
#
# One-time setup (after enrolling at https://developer.apple.com, $99/yr):
#   1. Create a "Developer ID Application" certificate (Xcode > Settings >
#      Accounts, or the developer portal) and note its full name with:
#        security find-identity -v -p codesigning
#   2. Store notary credentials in a keychain profile:
#        xcrun notarytool store-credentials veritas-notary \
#          --apple-id you@example.com --team-id TEAMID \
#          --password <app-specific-password>
#   3. Run:
#        export DEVELOPER_ID="Developer ID Application: Jackson Adams (TEAMID)"
#        export NOTARY_PROFILE="veritas-notary"
#        scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Veritas"
SCHEME="AIContentFilter"
DERIVED=".build/DerivedData"
DIST="dist"
APP="$DIST/$APP_NAME.app"
ICNS="Assets/Veritas.icns"
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | sed -E 's/.*"([^"]+)".*/\1/')
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"

note() { print -P "%F{cyan}==>%f $*"; }
warn() { print -P "%F{yellow}warning:%f $*"; }
die()  { print -P "%F{red}error:%f $*"; exit 1; }

# --- preflight: Developer ID signing identity -------------------------------
: ${DEVELOPER_ID:=""}
if [[ -z "$DEVELOPER_ID" ]]; then
  cat <<'EOF'
No Developer ID set. A distributable build needs a Developer ID Application
certificate, which requires a paid Apple Developer account. To proceed:

  export DEVELOPER_ID="Developer ID Application: Jackson Adams (TEAMID)"
  export NOTARY_PROFILE="veritas-notary"   # see the header for store-credentials
  scripts/release.sh

See the header of this script and docs/RELEASE.md for the full one-time setup.
EOF
  die "DEVELOPER_ID not set."
fi
security find-identity -v -p codesigning | grep -q "$DEVELOPER_ID" \
  || die "signing identity '$DEVELOPER_ID' not found in the keychain."
command -v xcodegen >/dev/null || die "XcodeGen required: brew install xcodegen"

# --- build ------------------------------------------------------------------
note "Generating project and building Release ($APP_NAME $VERSION)…"
xcodegen generate >/dev/null
xcodebuild -project AIContentFilter.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" CODE_SIGN_STYLE=Manual build >/dev/null

rm -rf "$DIST"; mkdir -p "$DIST"
cp -R "$DERIVED/Build/Products/Release/$APP_NAME.app" "$APP"

# --- sign (hardened runtime + secure timestamp) -----------------------------
note "Signing with Developer ID…"
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# --- package DMG (native hdiutil; no extra deps) ----------------------------
note "Building DMG…"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[[ -f "$ICNS" ]] && cp "$ICNS" "$STAGE/.VolumeIcon.icns"
RW="$DIST/.rw.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ \
  -format UDRW -ov "$RW" >/dev/null
if [[ -f "$ICNS" ]]; then
  MNT=$(hdiutil attach -nobrowse -readwrite "$RW" | tail -1 | awk '{print $NF}')
  SetFile -a C "$MNT" 2>/dev/null || warn "SetFile unavailable; volume icon flag not set"
  hdiutil detach "$MNT" >/dev/null
fi
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG" >/dev/null
rm -f "$RW"; rm -rf "$STAGE"
codesign --force --sign "$DEVELOPER_ID" "$DMG"

# --- notarize + staple ------------------------------------------------------
: ${NOTARY_PROFILE:=""}
if [[ -z "$NOTARY_PROFILE" ]]; then
  warn "NOTARY_PROFILE not set — skipping notarization."
  warn "The DMG is signed but NOT notarized; Gatekeeper will block it on other Macs."
else
  note "Submitting to Apple notary service (a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  note "Stapling ticket…"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

note "Gatekeeper assessment:"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true
note "Done: $DMG"
