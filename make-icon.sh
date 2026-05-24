#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

ICONSET="build/AppIcon.iconset"
SRC_PNG="build/AppIcon-1024.png"
OUT_DIR="Resources"
OUT_ICNS="${OUT_DIR}/AppIcon.icns"

echo "→ Rendering 1024px master with Pillow..."
python3 make-icon.py

echo "→ Generating iconset at all required sizes..."
rm -rf "${ICONSET}"
mkdir -p "${ICONSET}"
mkdir -p "${OUT_DIR}"

# (logical_pt, scale, filename)
declare -a SIZES=(
  "16   1 icon_16x16.png"
  "16   2 icon_16x16@2x.png"
  "32   1 icon_32x32.png"
  "32   2 icon_32x32@2x.png"
  "128  1 icon_128x128.png"
  "128  2 icon_128x128@2x.png"
  "256  1 icon_256x256.png"
  "256  2 icon_256x256@2x.png"
  "512  1 icon_512x512.png"
  "512  2 icon_512x512@2x.png"
)

for entry in "${SIZES[@]}"; do
  read -r pt scale name <<<"$entry"
  px=$((pt * scale))
  sips -z "${px}" "${px}" "${SRC_PNG}" --out "${ICONSET}/${name}" > /dev/null
done

echo "→ Building ${OUT_ICNS}..."
iconutil -c icns "${ICONSET}" -o "${OUT_ICNS}"

echo ""
echo "✅ Done: ${OUT_ICNS}"
echo "Rebuild with ./make-app.sh to apply."
