#!/usr/bin/env python3
"""Generate Havm Connect app icon (.icns) with USB trident logo."""

import math
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Color palette
BG_TOP = (30, 95, 200)
BG_BOTTOM = (8, 48, 125)
ICON_WHITE = (255, 255, 255)
RING_COLOR = (180, 210, 255, 100)


def draw_usb_trident(draw: ImageDraw.ImageDraw, cx: float, cy: float, scale: float):
    """Draw the classic USB trident symbol centered at (cx, cy).

    Layout (all dimensions multiplied by `scale`):

              ○ (circle, r=28)
              |
              | (stem, w=14)
       ○──────┼──────○  (side circles, r=20; horizontal bar w=10)
              |
              ▷ (triangle, base=28, h=22)

    Total height ≈ 220, width ≈ 180 at scale=1.
    """

    stem_w = max(2, int(18 * scale))
    top_r = max(2, int(36 * scale))
    side_r = max(2, int(26 * scale))
    tri_base = max(2, int(36 * scale))
    tri_h = max(2, int(28 * scale))
    bar_w = max(1, int(13 * scale))
    bar_half = int(90 * scale)  # half-length of the horizontal bar
    gap = int(5 * scale)  # gap between shape elements

    # Vertical stem: from bottom of top circle to top of triangle
    stem_top = cy - top_r - int(48 * scale)  # top of stem (below top circle)
    stem_bot = cy + tri_h + int(20 * scale)  # bottom of stem (above triangle)

    # --- Stem ---
    draw.rectangle(
        [cx - stem_w // 2, stem_top, cx + stem_w // 2, stem_bot],
        fill=ICON_WHITE,
    )

    # --- Top circle ---
    top_cy = stem_top - top_r - gap
    draw.ellipse(
        [cx - top_r, top_cy - top_r, cx + top_r, top_cy + top_r],
        fill=ICON_WHITE,
    )

    # --- Horizontal bar ---
    bar_y = cy - int(10 * scale)
    draw.rectangle(
        [cx - bar_half, bar_y - bar_w // 2, cx + bar_half, bar_y + bar_w // 2],
        fill=ICON_WHITE,
    )

    # --- Left side circle ---
    lx = cx - bar_half - side_r - gap
    draw.ellipse(
        [lx - side_r, bar_y - side_r, lx + side_r, bar_y + side_r],
        fill=ICON_WHITE,
    )

    # --- Right side circle ---
    rx = cx + bar_half + side_r + gap
    draw.ellipse(
        [rx - side_r, bar_y - side_r, rx + side_r, bar_y + side_r],
        fill=ICON_WHITE,
    )

    # --- Bottom triangle (arrow) ---
    tri_top = stem_bot + gap
    tri_bot = tri_top + tri_h
    triangle = [
        (cx, tri_bot),                          # tip
        (cx - tri_base // 2, tri_top),          # top-left
        (cx + tri_base // 2, tri_top),          # top-right
    ]
    draw.polygon(triangle, fill=ICON_WHITE)


def draw_icon(size: int) -> Image.Image:
    """Draw the Havm Connect icon at the given size with sharp anti-aliased shapes."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # --- Background squircle ---
    margin = int(size * 0.04)
    r = int(size * 0.222)  # macOS squircle corner radius
    draw.rounded_rectangle(
        [margin, margin, size - margin - 1, size - margin - 1],
        r,
        fill=None,
    )

    # Draw the rounded rect with a gradient
    for y in range(size):
        t = y / size
        red = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        green = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        blue = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(size):
            # Check if pixel is inside the squircle
            # Use a simple distance check from the rounded rect
            px, py = x, y
            inside = _in_rounded_rect(px, py, margin, margin,
                                      size - margin - 1, size - margin - 1, r)
            if inside:
                img.putpixel((x, y), (red, green, blue, 255))

    # --- Subtle inner ring ---
    ring_r = int(size * 0.222) - margin
    inner_margin = margin + int(size * 0.02)
    draw.rounded_rectangle(
        [inner_margin, inner_margin,
         size - inner_margin - 1, size - inner_margin - 1],
        ring_r,
        outline=RING_COLOR,
        width=max(1, int(size * 0.012)),
    )

    # --- USB trident logo ---
    # Scale factor: 1.0 at 1024px — make the symbol fill ~55% of the icon height
    scale = size / 700.0
    cx = size // 2
    cy = size // 2 + int(12 * scale)
    draw_usb_trident(draw, cx, cy, scale)

    return img


def _in_rounded_rect(x: float, y: float,
                     left: float, top: float, right: float, bottom: float,
                     r: float) -> bool:
    """Check if point (x, y) is inside the rounded rectangle."""
    if left <= x <= right and top + r <= y <= bottom - r:
        return True
    if top <= y <= bottom and left + r <= x <= right - r:
        return True
    # Check the four corner circles
    corners = [
        (left + r, top + r),
        (right - r, top + r),
        (left + r, bottom - r),
        (right - r, bottom - r),
    ]
    for cx, cy in corners:
        if (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2:
            return True
    return False


def generate_iconset(pngs: dict[int, Path], out_dir: Path) -> Path:
    """Create a .iconset directory structure from size→PNG mapping."""
    iconset = out_dir / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)

    name_map = {
        (16, 1): "icon_16x16.png",
        (16, 2): "icon_16x16@2x.png",
        (32, 1): "icon_32x32.png",
        (32, 2): "icon_32x32@2x.png",
        (128, 1): "icon_128x128.png",
        (128, 2): "icon_128x128@2x.png",
        (256, 1): "icon_256x256.png",
        (256, 2): "icon_256x256@2x.png",
        (512, 1): "icon_512x512.png",
        (512, 2): "icon_512x512@2x.png",
    }

    for px_size, png_path in pngs.items():
        for (base, scale), name in name_map.items():
            if base * scale == px_size:
                dest = iconset / name
                if png_path != dest:
                    dest.write_bytes(png_path.read_bytes())
                break

    return iconset


def main():
    project_root = Path(__file__).resolve().parent.parent
    # Still writing to the old path before the rename
    helper_dir = project_root / "havm-connect" / "havm-connect"
    assets_dir = helper_dir / "Assets.xcassets"
    assets_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        pngs: dict[int, Path] = {}

        for size in SIZES:
            img = draw_icon(size)
            png_path = tmpdir / f"icon_{size}.png"
            img.save(png_path, "PNG")
            pngs[size] = png_path
            print(f"  Generated {size}x{size}")

        # Create .iconset and generate .icns
        iconset = generate_iconset(pngs, tmpdir)
        icns_path = helper_dir / "AppIcon.icns"

        subprocess.run(
            ["iconutil", "-c", "icns", "-o", str(icns_path), str(iconset)],
            check=True,
        )
        print(f"\nCreated {icns_path} ({icns_path.stat().st_size:,} bytes)")

        # Save a preview PNG
        preview = project_root / "scripts" / "icon_preview.png"
        preview.write_bytes(pngs[1024].read_bytes())
        print(f"Preview: {preview}")


if __name__ == "__main__":
    main()
