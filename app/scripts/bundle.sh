#!/bin/zsh
# Build AudiobookStudio.app from the Swift package.
# The engine location is written into Info.plist (AudiobookEnginePath) and can be changed in Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="$PWD"
REPO_DIR="$(cd .. && pwd)"
ENGINE="${AUDIOBOOK_ENGINE:-$REPO_DIR/engine/.venv/bin/audiobook-engine}"
OUT="$APP_DIR/build/AudiobookStudio.app"
VERSION="${VERSION:-0.3.0}"
# CFBundleVersion must increase with every release (Sparkle compares it): the commit count does.
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

swift build -c release --product AudiobookStudio
BIN="$(swift build -c release --show-bin-path)/AudiobookStudio"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/AudiobookStudio"
# Sparkle (in-app updates) is linked dynamically: ship it next to the executable's @rpath (Contents/Frameworks).
mkdir -p "$OUT/Contents/Frameworks"
ditto "$(swift build -c release --show-bin-path)/Sparkle.framework" "$OUT/Contents/Frameworks/Sparkle.framework"
# SwiftPM resource bundle(s) must sit next to the executable's expected location.
for b in "$(swift build -c release --show-bin-path)"/*.bundle(N); do cp -R "$b" "$OUT/Contents/Resources/"; done
if [[ -f "$APP_DIR/Sources/AudiobookStudio/Resources/AppIcon.icns" ]]; then
  cp "$APP_DIR/Sources/AudiobookStudio/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
# The app's accent colour (indigo, used when the system accent is set to Multicolor): Assets.car + NSAccentColorName.
xcrun actool "$APP_DIR/Assets/Assets.xcassets" --compile "$OUT/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist "$APP_DIR/build/assets-partial.plist" --output-format human-readable-text >/dev/null

# RELEASE=1 (used by scripts/release.sh) leaves the engine path out: the app then looks where
# scripts/install-engine.sh installs it. Local builds point at this checkout's engine.
# Updates are only wired up in release builds (RELEASE=1). AUDIOBOOK_FEED overrides the appcast URL (testing
# against a local server; it also allows plain-HTTP loads from the local network).
SPARKLE_KEYS=""
if [[ "${RELEASE:-}" == "1" ]]; then
  FEED="${AUDIOBOOK_FEED:-https://github.com/antoine-debroye/audiobook-converter/releases/latest/download/appcast.xml}"
  SPARKLE_KEYS="  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>Kf1o7p4lWeAt2unbslMM1r3hoD3eeE6EPKzuojQLW0w=</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>"
  if [[ -n "${AUDIOBOOK_FEED:-}" ]]; then
    SPARKLE_KEYS="$SPARKLE_KEYS
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>"
  fi
fi
if [[ "${RELEASE:-}" == "1" ]]; then ENGINE_KEY=""; else ENGINE_KEY="  <key>AudiobookEnginePath</key><string>$ENGINE</string>"; fi

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Audiobook Studio</string>
  <key>CFBundleDisplayName</key><string>Audiobook Studio</string>
  <key>CFBundleIdentifier</key><string>local.audiobookstudio</string>
  <key>CFBundleExecutable</key><string>AudiobookStudio</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
$ENGINE_KEY
$SPARKLE_KEYS
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>EPUB book</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>PDF document</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict>
  </array>
</dict></plist>
PLIST

# Ad-hoc signature (local use). Set AUDIOBOOK_SIGN_ID to sign with your own identity instead.
if [[ -n "${AUDIOBOOK_SIGN_ID:-}" && "$AUDIOBOOK_SIGN_ID" != "-" ]]; then
  # A real identity: hardened runtime + secure timestamp, as notarization requires.
  # Inside-out, so every nested piece of Sparkle carries the hardened runtime and a secure timestamp.
  SP="$OUT/Contents/Frameworks/Sparkle.framework/Versions/B"
  for part in "$SP"/XPCServices/*.xpc "$SP/Autoupdate" "$SP/Updater.app" "$OUT/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$part" ]] && codesign --force --options runtime --timestamp --sign "$AUDIOBOOK_SIGN_ID" "$part"
  done
  codesign --force --options runtime --timestamp --sign "$AUDIOBOOK_SIGN_ID" "$OUT"
else
  codesign --force --deep --sign - "$OUT"
fi
echo "Built $OUT (engine: $ENGINE)"
