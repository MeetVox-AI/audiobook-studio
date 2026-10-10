#!/bin/zsh
# Builds a signed, notarized AudiobookStudio-<version>.dmg.
#
# One-time setup (see README "Releasing"): a "Developer ID Application" certificate in the login keychain, and
# notarization credentials stored as a keychain profile:
#   xcrun notarytool store-credentials AC_NOTARY --apple-id <id> --team-id <TEAMID> --password <app-specific password>
#
#   scripts/release.sh                 build, sign, make the DMG, notarize, staple, verify
#   NOTARIZE=0 scripts/release.sh      same without notarizing (a DMG that is signed only: do not publish it)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION="$(sed -n 's/^VERSION="\(.*\)"/\1/p' app/scripts/bundle.sh)"
IDENTITY="${AUDIOBOOK_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
PROFILE="${NOTARY_PROFILE:-AC_NOTARY}"
OUT="$ROOT/app/build/release"
APP="$ROOT/app/build/AudiobookStudio.app"
DMG="$OUT/AudiobookStudio-$VERSION.dmg"

[[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' certificate found in the keychain."; exit 1; }
echo "Signing as: $IDENTITY"

RELEASE=1 AUDIOBOOK_SIGN_ID="$IDENTITY" app/scripts/bundle.sh
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E "flags|Authority|Timestamp|TeamIdentifier"

rm -rf "$OUT"; mkdir -p "$OUT/stage"

# Notarize and staple the app itself first, so it carries its own ticket and passes Gatekeeper offline
# after it is dragged out of the DMG (the DMG's ticket alone is not enough on a Mac without internet).
if [[ "${NOTARIZE:-1}" == "1" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  echo "Submitting the app to Apple for notarization..."
  xcrun notarytool submit "$OUT/app.zip" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$OUT/app.zip"
fi
cp -R "$APP" "$OUT/stage/"
create-dmg --volname "Audiobook Studio" --window-size 560 360 --icon-size 100 \
  --icon "AudiobookStudio.app" 150 170 --app-drop-link 410 170 --hide-extension "AudiobookStudio.app" \
  "$DMG" "$OUT/stage"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
rm -rf "$OUT/stage"

if [[ "${NOTARIZE:-1}" == "1" ]]; then
  echo "Submitting to Apple for notarization (usually a few minutes)..."
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  # The app inside the DMG must carry its own stapled ticket.
  MNT="$(mktemp -d)"; hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
  xcrun stapler validate "$MNT/AudiobookStudio.app"; spctl --assess --type execute -v "$MNT/AudiobookStudio.app"
  hdiutil detach "$MNT" >/dev/null; rmdir "$MNT"
  echo "Notarized and stapled: $DMG"
else
  echo "Built (signed, NOT notarized): $DMG"
fi
shasum -a 256 "$DMG" | tee "$DMG.sha256"
