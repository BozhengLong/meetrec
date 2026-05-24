#!/usr/bin/env python3
"""
Generate MeetRec's app icon: a 1024x1024 white squircle with a red
record dot in the center (mimicking the SF Symbol `record.circle.fill`).

Output: build/AppIcon-1024.png (which make-icon.sh then turns into AppIcon.icns).
"""
import os
from PIL import Image, ImageDraw

SIZE = 1024
CORNER_RADIUS = int(SIZE * 0.2237)        # macOS Big Sur+ squircle ~22.4%
BACKGROUND = (255, 255, 255, 255)         # white
RED_INK    = (228, 38, 38, 255)           # vivid red, slightly muted
OUTER_DIAMETER_PCT = 0.74                 # outer ring outer-diameter
RING_STROKE_PCT    = 0.045                # ring thickness
INNER_DIAMETER_PCT = 0.50                 # filled inner dot diameter


def main():
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # 1. White squircle background
    draw.rounded_rectangle(
        [(0, 0), (SIZE - 1, SIZE - 1)],
        radius=CORNER_RADIUS,
        fill=BACKGROUND,
    )

    # 2. Outer thin red ring
    outer_d = int(SIZE * OUTER_DIAMETER_PCT)
    stroke  = int(SIZE * RING_STROKE_PCT)
    ox = (SIZE - outer_d) // 2
    draw.ellipse(
        [(ox, ox), (ox + outer_d, ox + outer_d)],
        outline=RED_INK,
        width=stroke,
    )

    # 3. Inner filled red dot
    inner_d = int(SIZE * INNER_DIAMETER_PCT)
    ix = (SIZE - inner_d) // 2
    draw.ellipse(
        [(ix, ix), (ix + inner_d, ix + inner_d)],
        fill=RED_INK,
    )

    out_dir = "build"
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "AppIcon-1024.png")
    img.save(out_path, "PNG")
    print(f"wrote {out_path} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
