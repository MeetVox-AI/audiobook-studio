#!/bin/zsh
# Build AudiobookStudio.app from the Swift package.
# The engine location is written into Info.plist (AudiobookEnginePath) and can be changed in Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
APP_DIR="$PWD"
REPO_DIR="$(cd .. && pwd)"
ENGINE="${AUDIOBOOK_ENGINE:-$REPO_DIR/engine/.venv/bin/audiobook-engine}"
OUT="$APP_DIR/build/AudiobookStudio.app"
VERSION="0.1.0"

swift build -c release --product AudiobookStudio
BIN="$(swift build -c release --show-bin-path)/AudiobookStudio"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/AudiobookStudio"
# SwiftPM resource bundle(s) must sit next to the executable's expected location.
for b in "$(swift build -c release --show-bin-path)"/*.bundle(N); do cp -R "$b" "$OUT/Contents/Resources/"; done
if [[ -f "$APP_DIR/Sources/AudiobookStudio/Resources/AppIcon.icns" ]]; then
  cp "$APP_DIR/Sources/AudiobookStudio/Resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
fi
# The app's accent colour (indigo, used when the system accent is set to Multicolor): Assets.car + NSAccentColorName.
xcrun actool "$APP_DIR/Assets/Assets.xcassets" --compile "$OUT/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --accent-color AccentColor \
  --output-partial-info-plist "$APP_DIR/build/assets-partial.plist" --output-format human-readable-text >/dev/null

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
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAccentColorName</key><string>AccentColor</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>AudiobookEnginePath</key><string>$ENGINE</string>
  <key>CFBundleDocumentTypes</key><array>
    <dict><key>CFBundleTypeName</key><string>EPUB book</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>PDF document</string><key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array></dict>
  </array>
</dict></plist>
PLIST

# Ad-hoc signature (local use). Set AUDIOBOOK_SIGN_ID to sign with your own identity instead.
codesign --force --deep --sign "${AUDIOBOOK_SIGN_ID:--}" "$OUT"
echo "Built $OUT (engine: $ENGINE)"
