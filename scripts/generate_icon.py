#!/usr/bin/env python3
"""Generate Havm Connect app icon PNGs into the asset catalog.

Requires: ImageMagick (`magick`) for SVG rasterization + compositing.

Produces a standard macOS AppIcon.appiconset with PNG files at all required
sizes. Xcode reads this directly — no .icns or CFBundleIconFile needed.
"""

import json
import shutil
import subprocess
import tempfile
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SVG_PATH = PROJECT_ROOT / "resources" / "usb-symbol.svg"
APPICONSET = (
    PROJECT_ROOT
    / "havm-connect" / "havm-connect"
    / "Assets.xcassets" / "AppIcon.appiconset"
)

# Standard macOS app icon sizes. Each filename is a (pixel_size, output_name) pair.
# When the same pixel count serves multiple logical sizes (e.g. 32px is both
# 16x16@2x and 32x32@1x), we generate once and hard-link.
RENDER = [
    (16,   ["icon_16x16.png"]),
    (32,   ["icon_16x16@2x.png", "icon_32x32.png"]),
    (64,   ["icon_32x32@2x.png"]),
    (128,  ["icon_128x128.png"]),
    (256,  ["icon_128x128@2x.png", "icon_256x256.png"]),
    (512,  ["icon_256x256@2x.png", "icon_512x512.png"]),
    (1024, ["icon_512x512@2x.png"]),
]

# Contents.json — mirrors the naming map above.
ENTRIES = [
    {"filename": "icon_16x16.png",      "idiom": "mac", "scale": "1x", "size": "16x16"},
    {"filename": "icon_16x16@2x.png",   "idiom": "mac", "scale": "2x", "size": "16x16"},
    {"filename": "icon_32x32.png",      "idiom": "mac", "scale": "1x", "size": "32x32"},
    {"filename": "icon_32x32@2x.png",   "idiom": "mac", "scale": "2x", "size": "32x32"},
    {"filename": "icon_128x128.png",    "idiom": "mac", "scale": "1x", "size": "128x128"},
    {"filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
    {"filename": "icon_256x256.png",    "idiom": "mac", "scale": "1x", "size": "256x256"},
    {"filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
    {"filename": "icon_512x512.png",    "idiom": "mac", "scale": "1x", "size": "512x512"},
    {"filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
]

BG_TOP = (30, 95, 200)
BG_BOTTOM = (8, 48, 125)


def render_icon(size: int, out_path: Path) -> None:
    """Render one icon PNG at the given pixel size using ImageMagick."""
    r = int(size * 0.185)
    logo_px = int(size * 0.55)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        bg = tmpdir / "bg.png"
        logo = tmpdir / "logo.png"

        # Blue rounded-rect background
        subprocess.run([
            "magick", "-size", f"{size}x{size}", "xc:transparent",
            "-fill", f"rgb({BG_TOP[0]},{BG_TOP[1]},{BG_TOP[2]})",
            "-draw", f"roundrectangle 0,0,{size-1},{size-1},{r},{r}",
            str(bg),
        ], check=True)

        # SVG logo, white
        subprocess.run([
            "magick", "-background", "none", "-density", "400",
            str(SVG_PATH),
            "-fill", "white", "-colorize", "100",
            "-resize", f"{logo_px}x{logo_px}",
            str(logo),
        ], check=True)

        # Composite
        subprocess.run([
            "magick", str(bg), str(logo),
            "-gravity", "center", "-composite",
            str(out_path),
        ], check=True)


def main():
    if not SVG_PATH.exists():
        print(f"Error: {SVG_PATH} not found")
        return

    if APPICONSET.exists():
        shutil.rmtree(APPICONSET)
    APPICONSET.mkdir(parents=True)

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)

        for pixel_size, names in RENDER:
            master = tmpdir / f"icon_{pixel_size}.png"
            render_icon(pixel_size, master)

            for name in names:
                dest = APPICONSET / name
                shutil.copy(master, dest)
            print(f"  {pixel_size}px → {' '.join(names)}")

    # Contents.json
    contents = {"images": ENTRIES, "info": {"author": "xcode", "version": 1}}
    (APPICONSET / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")
    print(f"\nCreated {APPICONSET}")


if __name__ == "__main__":
    main()
