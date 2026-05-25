#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MeetRec"
BUNDLE_ID="com.local.meetrec"
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "→ Quitting any running MeetRec instance..."
osascript -e 'tell application "MeetRec" to quit' >/dev/null 2>&1 || true
# Give it a moment to flush and exit before we overwrite the binary.
sleep 1
pkill -x MeetRec 2>/dev/null || true

echo "→ Building release binary..."
swift build -c release

echo "→ Creating ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
    echo "→ Bundled AppIcon.icns"
else
    echo "⚠ Resources/AppIcon.icns not found — generate it with ./make-icon.sh"
fi

cat > "${CONTENTS}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>MeetRec needs the microphone to record your voice into the right channel.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>MeetRec captures system audio output so you can archive meetings and livestreams.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MeetRec uses ScreenCaptureKit to record system audio. No video is saved.</string>
</dict>
</plist>
EOF

echo "→ Ad-hoc signing..."
codesign --force --deep --sign - "${APP_DIR}"

# Ad-hoc signing produces a fresh code identity on every rebuild, so macOS TCC
# treats the new binary as a different app from whatever it authorized before.
# Reset the relevant TCC entries so the next launch shows the permission prompts
# cleanly instead of silently failing with -3801 ("user declined TCCs").
echo "→ Resetting TCC for ${BUNDLE_ID} (Screen Recording + Microphone)..."
tccutil reset ScreenCapture "${BUNDLE_ID}" >/dev/null 2>&1 || true
tccutil reset Microphone     "${BUNDLE_ID}" >/dev/null 2>&1 || true

echo ""
echo "✅ Done: ${APP_DIR}"
echo ""
echo "Next steps:"
echo "  1. Launch ${APP_DIR} (or drag it to /Applications and launch from there)."
echo "  2. Click record once — macOS will prompt for Microphone and Screen Recording."
echo "  3. Approve both in System Settings → Privacy & Security."
echo "  4. IMPORTANT: fully quit MeetRec (menu bar → Quit) and relaunch — screen"
echo "     recording permission only takes effect on the next launch."
