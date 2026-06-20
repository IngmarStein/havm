#!/usr/bin/env python3
"""Generate Havm Connect app icon (.icns) using external USB trident SVG.

Requires: ImageMagick (`magick`) for SVG rasterization + compositing.
No Python dependencies beyond stdlib.
"""

import subprocess
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = PROJECT_ROOT / "resources" / "usb-symbol.svg"
ICNS_OUT = PROJECT_ROOT / "havm-connect" / "havm-connect" / "AppIcon.icns"
ASSETS_DIR = PROJECT_ROOT / "havm-connect" / "havm-connect" / "Assets.xcassets"
ICON_SIZES = [16, 32, 64, 128, 256, 512, 1024]

# Colors
BG_TOP = (30, 95, 200)
BG_BOTTOM = (8, 48, 125)


def make_icon(size: int, tmpdir: Path) -> Path:
    """Generate one icon PNG using ImageMagick.

    Steps:
      1. Create blue rounded-rect background (macOS applies squircle mask at runtime)
      2. Rasterize SVG to black-on-transparent, then recolor black → white
      3. Composite logo centered onto background
    """
    bg_path = tmpdir / f"bg_{size}.png"
    logo_path = tmpdir / f"logo_{size}.png"
    out_path = tmpdir / f"icon_{size}.png"

    r = int(size * 0.185)  # corner radius

    # 1. Background: blue gradient rounded rectangle
    subprocess.run([
        "magick", "-size", f"{size}x{size}",
        "xc:transparent",
        "-fill", f"rgb({BG_TOP[0]},{BG_TOP[1]},{BG_TOP[2]})",
        "-draw", f"roundrectangle 0,0,{size-1},{size-1},{r},{r}",
        str(bg_path),
    ], check=True)

    # 2. Logo: rasterize SVG, recolor black → white, size to 55% of icon
    logo_px = int(size * 0.55)
    subprocess.run([
        "magick", "-background", "none", "-density", "400",
        str(SVG_PATH),
        "-fill", "white", "-colorize", "100",
        "-resize", f"{logo_px}x{logo_px}",
        str(logo_path),
    ], check=True)

    # 3. Composite logo centered on background
    subprocess.run([
        "magick", str(bg_path), str(logo_path),
        "-gravity", "center",
        "-composite",
        str(out_path),
    ], check=True)

    return out_path


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
            out = make_icon(size, tmpdir)
            pngs[size] = out
            print(f"  Generated {size}x{size}")

        iconset = generate_iconset(pngs, tmpdir)
        subprocess.run(
            ["iconutil", "-c", "icns", "-o", str(ICNS_OUT), str(iconset)],
            check=True,
        )
        print(f"\nCreated {ICNS_OUT} ({ICNS_OUT.stat().st_size:,} bytes)")

        # Preview
        preview = PROJECT_ROOT / "scripts" / "icon_preview.png"
        preview.write_bytes(pngs[1024].read_bytes())
        print(f"Preview: {preview}")


if __name__ == "__main__":
    main()
