#!/usr/bin/env python3
"""Render the social-share (Open Graph) card for the Veritas website.

A 1200x630 paper card that mirrors the site masthead: double rule, the name,
the tagline, a hairline, the dateline, double rule. Ink on warm paper, matching
web/styles.css exactly. Re-run after a brand or tagline change:

    python3 scripts/make-og-image.py

Output:
  web/assets/og.png
"""
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "web", "assets", "og.png")

W, H = 1200, 630
PAPER = (243, 239, 228)   # --paper
INK = (33, 30, 24)        # --ink
FAINT = (108, 101, 87)    # --faint

NAME = "Veritas"
TAGLINE = "A quiet instrument for honest reading."
DATELINE = "On your own Mac  ·  macOS 14  ·  Apple Silicon"

SERIF = ["/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
         "/System/Library/Fonts/Supplemental/Georgia.ttf"]
SERIF_REG = ["/System/Library/Fonts/Supplemental/Georgia.ttf"]
MONO = ["/System/Library/Fonts/Supplemental/Courier New.ttf"]


def font(paths, size):
    for p in paths:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def double_rule(d, y):
    d.line([(140, y), (W - 140, y)], fill=INK, width=2)
    d.line([(140, y + 6), (W - 140, y + 6)], fill=INK, width=2)


def main():
    img = Image.new("RGB", (W, H), PAPER)
    d = ImageDraw.Draw(img)

    double_rule(d, 150)
    d.text((W / 2, 290), NAME, font=font(SERIF, 168), fill=INK, anchor="mm")
    d.text((W / 2, 392), TAGLINE, font=font(SERIF_REG, 40), fill=FAINT, anchor="mm")
    d.line([(140, 452), (W - 140, 452)], fill=INK, width=1)
    d.text((W / 2, 495), DATELINE, font=font(MONO, 26), fill=FAINT, anchor="mm")
    double_rule(d, 540)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT)
    print(f"og image: {OUT} ({W}x{H})")


if __name__ == "__main__":
    main()
