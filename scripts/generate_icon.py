#!/usr/bin/env python3
"""Generate Havm Connect app icon (.icns) using external USB trident SVG.

Requires: ImageMagick (`magick`) for SVG rasterization, Python Pillow for compositing.
"""

import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = PROJECT_ROOT / "resources" / "usb-symbol.svg"
ICNS_OUT = PROJECT_ROOT / "havm-connect" / "havm-connect" / "AppIcon.icns"
ASSETS_DIR = PROJECT_ROOT / "havm-connect" / "havm-connect" / "Assets.xcassets"
ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Colors
BG_TOP = (30, 95, 200)
BG_BOTTOM = (8, 48, 125)
RING_COLOR = (180, 210, 255, 100)


def squircle_background(size: int) -> Image.Image:
    """Draw the blue squircle with gradient and inner ring."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    margin = int(size * 0.04)
    r = int(size * 0.222)

    # Gradient fill inside the rounded rect
    for y in range(size):
        t = y / size
        red = int(BG_TOP[0] + (BG_BOTTOM[0] - BG_TOP[0]) * t)
        green = int(BG_TOP[1] + (BG_BOTTOM[1] - BG_TOP[1]) * t)
        blue = int(BG_TOP[2] + (BG_BOTTOM[2] - BG_TOP[2]) * t)
        for x in range(size):
            if _in_rounded_rect(x, y, margin, margin,
                                size - margin - 1, size - margin - 1, r):
                img.putpixel((x, y), (red, green, blue, 255))

    # Inner ring
    draw = ImageDraw.Draw(img)
    ring_r = int(size * 0.222) - margin
    inner_margin = margin + int(size * 0.02)
    draw.rounded_rectangle(
        [inner_margin, inner_margin,
         size - inner_margin - 1, size - inner_margin - 1],
        ring_r,
        outline=RING_COLOR,
        width=max(1, int(size * 0.012)),
    )
    return img


def _in_rounded_rect(x: float, y: float,
                     left: float, top: float, right: float, bottom: float,
                     r: float) -> bool:
    if left <= x <= right and top + r <= y <= bottom - r:
        return True
    if top <= y <= bottom and left + r <= x <= right - r:
        return True
    for cx, cy in [(left + r, top + r), (right - r, top + r),
                   (left + r, bottom - r), (right - r, bottom - r)]:
        if (x - cx) ** 2 + (y - cy) ** 2 <= r ** 2:
            return True
    return False


def rasterize_svg(size: int, tmpdir: Path) -> Image.Image:
    """Rasterize the USB SVG to white-on-transparent PNG at the given size.

    The logo is sized to occupy ~55% of the icon area, same as the previous
    hand-drawn USB symbol.
    """
    logo_px = int(size * 0.55)
    png_path = tmpdir / f"usb_{size}.png"

    subprocess.run([
        "magick", "-background", "none",
        "-density", "300",
        str(SVG_PATH),
        "-fuzz", "100%", "-fill", "white", "-opaque", "black",
        "-resize", f"{logo_px}x{logo_px}",
        str(png_path),
    ], check=True)

    return Image.open(png_path)


def composite_icon(size: int, tmpdir: Path) -> Image.Image:
    """Layer the USB logo centered onto the squircle background."""
    bg = squircle_background(size)
    logo = rasterize_svg(size, tmpdir)

    # Center the logo on the background
    offset_x = (size - logo.width) // 2
    offset_y = (size - logo.height) // 2 + int(size * 0.01)  # slight nudge down

    bg.paste(logo, (offset_x, offset_y), logo)
    return bg


def generate_iconset(pngs: dict[int, Path], out_dir: Path) -> Path:
    """Create .iconset directory from size→PNG mapping."""
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
    ASSETS_DIR.mkdir(parents=True, exist_ok=True)

    if not SVG_PATH.exists():
        print(f"Error: {SVG_PATH} not found")
        return

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        pngs: dict[int, Path] = {}

        for size in ICON_SIZES:
            img = composite_icon(size, tmpdir)
            png_path = tmpdir / f"icon_{size}.png"
            img.save(png_path, "PNG")
            pngs[size] = png_path
            print(f"  Generated {size}x{size}")

        iconset = generate_iconset(pngs, tmpdir)
        subprocess.run(
            ["iconutil", "-c", "icns", "-o", str(ICNS_OUT), str(iconset)],
            check=True,
        )
        print(f"\nCreated {ICNS_OUT} ({ICNS_OUT.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
