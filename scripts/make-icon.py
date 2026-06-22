#!/usr/bin/env python3
"""Render the Veritas app icon and build the macOS asset catalog + .icns.

Single source of truth for the app icon. The mark is a camera-style viewfinder
frame around three text lines, the bottom one flagged amber: the app watches
on-screen text and flags the AI-looking parts. Re-run after editing the design:

    python3 scripts/make-icon.py

Outputs:
  Assets/icon-master.png
  Assets/Assets.xcassets/Contents.json
  Assets/Assets.xcassets/AppIcon.appiconset/  (10 sized PNGs + Contents.json)
  Assets/Veritas.icns                          (Finder / DMG volume icon)
"""
import json
import os
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "Assets")
S = 1024

TOP = (66, 86, 224)       # indigo
BOTTOM = (26, 33, 96)      # deep blue
WHITE = (255, 255, 255, 240)
AMBER = (255, 193, 76, 255)


def _lerp(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _squircle_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def _bracket(d, cx, cy, sx, sy, arm, thick):
    """One viewfinder corner at (cx,cy); sx/sy in {-1,1} point the arms inward."""
    r = thick // 2
    x2 = cx + sx * arm
    y2 = cy + sy * arm
    d.rounded_rectangle([min(cx, x2), min(cy, cy + sy * thick),
                         max(cx, x2), max(cy, cy + sy * thick)], radius=r, fill=WHITE)
    d.rounded_rectangle([min(cx, cx + sx * thick), min(cy, y2),
                         max(cx, cx + sx * thick), max(cy, y2)], radius=r, fill=WHITE)


def render_master():
    bg = Image.new("RGB", (S, S), BOTTOM)
    bd = ImageDraw.Draw(bg)
    for y in range(S):
        bd.line([(0, y), (S, y)], fill=_lerp(TOP, BOTTOM, y / (S - 1)))

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), _squircle_mask(S, int(S * 0.225)))
    d = ImageDraw.Draw(icon)

    # viewfinder frame corners
    lo, hi, arm, thick = 250, 774, 150, 46
    _bracket(d, lo, lo, 1, 1, arm, thick)
    _bracket(d, hi, lo, -1, 1, arm, thick)
    _bracket(d, lo, hi, 1, -1, arm, thick)
    _bracket(d, hi, hi, -1, -1, arm, thick)

    # three text lines, bottom one flagged amber
    cx = S // 2
    for y, w, color in [(424, 300, WHITE), (512, 360, WHITE), (600, 250, AMBER)]:
        d.rounded_rectangle([cx - w // 2, y - 19, cx + w // 2, y + 19], radius=19, fill=color)

    os.makedirs(ASSETS, exist_ok=True)
    master = os.path.join(ASSETS, "icon-master.png")
    icon.save(master)
    return icon


# (size_px, filename) for a macOS AppIcon set
ICONSET = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]


def build_appiconset(master):
    out = os.path.join(ASSETS, "Assets.xcassets", "AppIcon.appiconset")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out, exist_ok=True)
    for px, name in ICONSET:
        master.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))
    images = []
    for (px, name) in ICONSET:
        base = int(name.split("_")[1].split("@")[0].split("x")[0])
        scale = "2x" if "@2x" in name else "1x"
        images.append({"size": f"{base}x{base}", "idiom": "mac", "filename": name, "scale": scale})
    with open(os.path.join(out, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"version": 1, "author": "veritas"}}, f, indent=2)
    with open(os.path.join(ASSETS, "Assets.xcassets", "Contents.json"), "w") as f:
        json.dump({"info": {"version": 1, "author": "veritas"}}, f, indent=2)
    return out


def build_icns(master):
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "Veritas.iconset")
        os.makedirs(iconset)
        for px, name in ICONSET:
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
        icns = os.path.join(ASSETS, "Veritas.icns")
        try:
            subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
            return icns
        except (FileNotFoundError, subprocess.CalledProcessError):
            return None


if __name__ == "__main__":
    m = render_master()
    appiconset = build_appiconset(m)
    icns = build_icns(m)
    print(f"master:      {os.path.join(ASSETS, 'icon-master.png')}")
    print(f"appiconset:  {appiconset} ({len(ICONSET)} sizes)")
    print(f"icns:        {icns or '(iconutil unavailable; .icns skipped)'}")
