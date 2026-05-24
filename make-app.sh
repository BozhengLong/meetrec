#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MeetRec"
BUNDLE_ID="com.local.meetrec"
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

echo "→ Building release binary..."
swift build -c release

echo "→ Creating ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"

cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

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

echo ""
echo "✅ Done: ${APP_DIR}"
echo ""
echo "Double-click ${APP_DIR} to launch, or drag it to /Applications."
