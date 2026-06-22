#!/usr/bin/env python3
"""
Generate the four built-in pet packs (base PNG + five GIFs + speech templates)
as self-contained JSON documents under Assets/Pets/.

The app ships pets as single JSON files with every sprite embedded as base64
so PetStore can load one with a single Codable decode and third-party packs
stay one-file-droppable. Nothing at runtime draws pixels or runs Python; this
script is the offline source of truth for the built-in four.

Design notes, so future edits don't regress the look or the contract:

- Frames are drawn at 24x24 and upscaled x4 with NEAREST. Drawing at the final
  96x96 invites anti-aliased "soft" edges; chunky low-res pixels are what keep
  a pet readable at menu-bar size.
- Everything is parametric pose math -- no wall clock, no unseeded random.
  Re-running must be byte-stable so asset churn shows up as a real diff.
- Pillow merges byte-identical consecutive GIF frames at save time (even with
  optimize=False), which would silently break the "8..14 frames" contract on
  hold poses. Every animation therefore alternates a 1px micro-detail (breath,
  twinkle, fur bristle) on odd frames, and build() asserts no two consecutive
  frames are identical before encoding.
- GIF transparency goes through the quantize/paste recipe in encode_gif().
  Letting PIL auto-convert RGBA->GIF flattens alpha onto black halos.

Usage:
  /tmp/petgen-venv/bin/python scripts/generate-pets.py

Optional: set PETGEN_PREVIEW=1 to also write per-pet contact sheets to
/tmp/petgen-preview/ for eyeballing frames (never part of the shipped output).
"""

from __future__ import annotations

import base64
import io
import json
import math
import os
import sys

from PIL import Image, ImageDraw

# ---------------------------------------------------------------------------
# Geometry constants
# ---------------------------------------------------------------------------

S = 24                      # master sprite canvas, before upscale
SCALE = 4                   # 24 * 4 = 96, the shipped size
OUT = S * SCALE
GROUND = 22.0               # baseline just under the feet; squash/scale anchor
                            # so landings compress *down onto* the ground
                            # instead of floating.

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PETS_DIR = os.path.join(ROOT, "Assets", "Pets")
# Raw per-frame inspection copies (base.png + gifs) live OUTSIDE Assets/Pets so
# they never ship in the app bundle — Assets/Pets is a folder reference that
# bundles wholesale into Resources/Pets. Keep only the pet JSONs in PETS_DIR.
SRC_DIR = os.path.join(ROOT, "Assets", "PetPreviews")

# Mirrors FilterCore's free clamp(_:_:_:) in TextMetrics.swift so the tooling
# and the app speak the same vocabulary when poking at pose math.
def clamp(value, low, high):
    return min(max(value, low), high)


def blank() -> Image.Image:
    return Image.new("RGBA", (S, S), (0, 0, 0, 0))


def upscale(img: Image.Image) -> Image.Image:
    return img.resize((OUT, OUT), Image.NEAREST)


# ---------------------------------------------------------------------------
# Pose composition
#
# A pose is a plain dict: pet-specific keys (eyes, tail, ...) plus a shared
# transform vocabulary applied here, in a fixed order chosen so each step
# stays crisp under NEAREST:
#   lean  -- shear the top toward +x, feet pinned (px at head height)
#   rot   -- whole-sprite rotation, used by Glitch's spin
#   sq    -- squash/stretch in px (+ = wider & shorter), bottom-anchored
#   scale -- uniform shrink for fly_out
#   dx/dy -- final offset; large dy slides the pet below the canvas
# ---------------------------------------------------------------------------

def compose(render, pose: dict) -> Image.Image:
    img = render(pose)

    lean = pose.get("lean", 0)
    if lean:
        # Inverse-mapped affine: x_src = x_dst + lean * (y - 21) / 16, which
        # shifts the head by `lean` px and leaves the feet planted.
        data = (1.0, lean / 16.0, -21.0 * lean / 16.0, 0.0, 1.0, 0.0)
        img = img.transform((S, S), Image.AFFINE, data,
                            resample=Image.NEAREST, fillcolor=(0, 0, 0, 0))

    rot = pose.get("rot", 0)
    if rot:
        img = img.rotate(rot, resample=Image.NEAREST, center=(12, 13),
                         fillcolor=(0, 0, 0, 0))

    sq = pose.get("sq", 0)
    sc = pose.get("scale", 1.0)
    dx = pose.get("dx", 0)
    dy = pose.get("dy", 0)
    if sq or sc != 1.0 or dx or dy:
        w = max(1, round((S + sq) * sc))
        h = max(1, round((S - sq) * sc))
        small = img.resize((w, h), Image.NEAREST)
        img = blank()
        px = round(S / 2 + dx - w / 2)
        py = round(GROUND + dy - h * GROUND / S)
        img.paste(small, (px, py), small)
    return img


# ---------------------------------------------------------------------------
# Pet renderers. Each takes a pose dict and returns a 24x24 RGBA frame.
# Coordinates are hand-placed; the named palette keys keep relayering sane.
# ---------------------------------------------------------------------------

SCOUT_PAL = {
    "outline": (30, 41, 47, 255),
    "body":    (84, 122, 122, 255),
    "belly":   (130, 161, 158, 255),
    "wing":    (62, 95, 98, 255),
    "frame":   (215, 222, 223, 255),
    "lens":    (236, 244, 244, 255),
    "eye":     (30, 41, 47, 255),
    "beak":    (199, 152, 84, 255),
    "mark":    (240, 196, 96, 255),
    "glint":   (255, 255, 255, 255),
}


def render_scout(p: dict) -> Image.Image:
    # The original upright, front-facing analyst owl. The same frame drives
    # base.png (the menu preview) and every animation; the GIFs just blink,
    # breathe, glint the lenses, and flare the wings on alarm.
    c = SCOUT_PAL
    img = blank()
    d = ImageDraw.Draw(img)
    o = c["outline"]
    cock = p.get("cock", 0)

    if p["wings"] == "up":
        d.ellipse((1, 8, 6, 15), fill=c["wing"], outline=o)
        d.ellipse((17, 8, 22, 15), fill=c["wing"], outline=o)

    d.ellipse((5, 4, 18, 20), fill=c["body"], outline=o)         # owl = ball
    d.polygon([(7, 2), (6, 6), (10, 5)], fill=c["body"], outline=o)
    d.polygon([(16, 2), (17, 6), (13, 5)], fill=c["body"], outline=o)
    d.ellipse((8, 13 - p["tick"], 15, 19), fill=c["belly"])

    if p["wings"] == "rest":
        d.ellipse((3, 11, 7, 18), fill=c["wing"], outline=o)
        d.ellipse((16, 11, 20, 18), fill=c["wing"], outline=o)

    d.rectangle((8, 21, 9, 21), fill=c["beak"])                   # toes
    d.rectangle((14, 21, 15, 21), fill=c["beak"])

    for i, cx in enumerate((9, 15)):                             # glasses
        ty = 7 - (cock if i == 1 else 0)                         # right lens lifts -> cocked
        box = (cx - 3, ty, cx + 3, ty + 6)
        if p["blink"]:
            d.ellipse(box, fill=c["body"], outline=c["frame"])
            d.line((cx - 2, ty + 3, cx + 2, ty + 3), fill=o)
        else:
            d.ellipse(box, fill=c["lens"], outline=c["frame"])
            ex = cx - 1 + p["pdx"]
            ey = ty + 2 + p["pdy"]
            d.rectangle((ex, ey, ex + 1, ey + 1), fill=c["eye"])
    d.point((5, 10), fill=c["frame"])                            # temples
    d.point((19, 10 - cock), fill=c["frame"])
    if p["glint"] and not p["blink"]:
        d.line((7, 8, 8, 7), fill=c["glint"])
        d.line((13, 8 - cock, 14, 7 - cock), fill=c["glint"])

    d.rectangle((11, 13, 12, 14), fill=c["beak"])

    if p["exclaim"]:
        d.rectangle((20, 1, 21, 5), fill=c["mark"], outline=o)
        d.rectangle((20, 7, 21, 8), fill=c["mark"], outline=o)

    return img


MOCHI_PAL = {
    "outline": (96, 64, 66, 255),
    "body":    (248, 233, 213, 255),
    "blush":   (244, 167, 173, 255),
    "eye":     (73, 49, 50, 255),
    "spark":   (255, 255, 255, 255),
    "heart":   (240, 110, 130, 255),
}


def render_mochi(p: dict) -> Image.Image:
    # The original upright, front-facing companion blob. The same frame drives
    # base.png and every animation; the GIFs just sparkle, blink, and bloom a
    # little heart while watching.
    c = MOCHI_PAL
    img = blank()
    d = ImageDraw.Draw(img)
    o = c["outline"]
    cock = p.get("cock", 0)

    d.ellipse((4, 7, 19, 21), fill=c["body"], outline=o)          # the blob

    by = 15 - (1 if (p["blush"] == "big" or p["tick"]) else 0)
    d.rectangle((5, by, 6, 15), fill=c["blush"])
    d.rectangle((17, by, 18, 15), fill=c["blush"])

    ex = p["edx"]
    if p["blink"]:
        d.line((8 + ex, 12, 9 + ex, 12), fill=c["eye"])
        d.line((14 + ex, 12 - cock, 15 + ex, 12 - cock), fill=c["eye"])
    else:
        d.rectangle((8 + ex, 11, 9 + ex, 12), fill=c["eye"])
        d.rectangle((14 + ex, 11 - cock, 15 + ex, 12 - cock), fill=c["eye"])
        if p["sparkle"]:
            d.point((8 + ex + p["tick"], 11), fill=c["spark"])
            d.point((15 + ex - p["tick"], 11 - cock), fill=c["spark"])

    if p["mouth"] == "smile":
        d.point((10, 15), fill=c["eye"])
        d.point((13, 15), fill=c["eye"])
        d.line((11, 16, 12, 16), fill=c["eye"])
    else:                                                          # worried o
        d.ellipse((11, 15, 13, 17), fill=c["eye"])

    if p["star"]:
        if p["tick"]:
            d.point((20, 4), fill=c["spark"])
        else:
            d.point((19, 3), fill=c["heart"])
            d.point((21, 5), fill=c["heart"])

    if p["heart"] == "big":
        d.point((17, 2), fill=c["heart"])
        d.point((19, 2), fill=c["heart"])
        d.rectangle((16, 3, 20, 3), fill=c["heart"])
        d.rectangle((17, 4, 19, 4), fill=c["heart"])
        d.point((18, 5), fill=c["heart"])
    elif p["heart"] == "small":
        d.point((17, 3), fill=c["heart"])
        d.point((19, 3), fill=c["heart"])
        d.rectangle((17, 4, 19, 4), fill=c["heart"])
        d.point((18, 5), fill=c["heart"])

    return img


BRILL_PAL = {
    "outline": (40, 33, 50, 255),
    "body":    (124, 113, 140, 255),
    "belly":   (158, 148, 173, 255),
    "inner":   (186, 132, 152, 255),
    "eye":     (198, 182, 95, 255),
}

# Tail chains, base to tip. Drawn as 3x3 outline blocks with a thin body-color
# core so the tail stays readable on both light and dark menu bars.
BRILL_TAILS = {
    0:    [(17, 20), (19, 19), (20, 18), (21, 16)],
    1:    [(17, 19), (19, 18), (20, 16), (21, 14)],
    2:    [(17, 19), (18, 17), (19, 15), (20, 13)],
    "up": [(18, 18), (19, 16), (19, 14), (20, 12)],
}

# Two interleaved fur-spike sets on the OUTER silhouette (sides + the gap
# between the ears); alternating per frame reads as bristling fur on alarm.
BRILL_SPIKES = [
    [(4, 10), (3, 11), (19, 10), (20, 11), (11, 2), (11, 3)],
    [(4, 13), (3, 14), (19, 13), (20, 14), (12, 2), (12, 3)],
]


def render_brill(p: dict) -> Image.Image:
    # The original upright, front-facing skeptical cat. The same frame drives
    # base.png and every animation; the GIFs just flick the tail, half-lid and
    # blink the eyes, and bristle on alarm.
    c = BRILL_PAL
    img = blank()
    d = ImageDraw.Draw(img)
    o = c["outline"]
    cock = p.get("cock", 0)
    look = p.get("look", 0)

    chain = BRILL_TAILS[p["tail"]]
    for (x, y) in chain:
        d.rectangle((x - 1, y - 1, x + 1, y + 1), fill=o)
    d.line(chain, fill=c["body"], width=1)

    arch = p["arch"]
    body_box = (5, 9, 18, 21) if arch else (5, 11, 18, 21)
    head_box = (6, 5, 17, 14) if arch else (6, 3, 17, 12)
    d.ellipse(body_box, fill=c["body"], outline=o)
    d.ellipse((9, body_box[1] + 5 - p["tick"], 14, 20), fill=c["belly"])

    d.ellipse(head_box, fill=c["body"], outline=o)
    hy = head_box[1]
    d.polygon([(7, hy - 2), (6, hy + 3), (11, hy + 2)], fill=c["body"], outline=o)
    if p["ears"] == "turn":
        d.polygon([(18, hy - 1), (17, hy + 4), (13, hy + 2)], fill=c["body"], outline=o)
        d.point((17, hy + 2), fill=c["inner"])
    else:
        d.polygon([(16, hy - 2), (17, hy + 3), (12, hy + 2)], fill=c["body"], outline=o)
        d.point((16, hy + 1), fill=c["inner"])
    d.point((7, hy + 1), fill=c["inner"])

    ey = hy + 5
    e1, e2 = 8 + look, 13 + look
    eyes = p["eyes"]
    if eyes == "closed":
        d.line((e1, ey, e1 + 2, ey), fill=o)
        d.line((e2, ey - cock, e2 + 2, ey - cock), fill=o)
    elif eyes == "squint":
        d.rectangle((e1, ey, e1 + 1, ey), fill=c["eye"])
        d.rectangle((e2 + 1, ey - cock, e2 + 2, ey - cock), fill=c["eye"])
        d.point((e1 + 1, ey), fill=o)
        d.point((e2 + 1, ey - cock), fill=o)
    else:                                       # half-lidded resting judgment
        d.rectangle((e1, ey, e1 + 2, ey), fill=c["eye"])
        d.rectangle((e2, ey - cock, e2 + 2, ey - cock), fill=c["eye"])
        d.point((e1 + 1, ey), fill=o)
        d.point((e2 + 1, ey - cock), fill=o)
        if eyes == "flat":
            d.line((e1, ey - 2, e1 + 2, ey - 2), fill=o)
            d.line((e2, ey - 2 - cock, e2 + 2, ey - 2 - cock), fill=o)

    ny = hy + 7
    d.rectangle((11, ny, 12, ny), fill=c["inner"])
    if p["mouth"] == "flat":
        d.line((10, ny + 1, 13, ny + 1), fill=o)
    else:
        d.line((11, ny + 1, 12, ny + 1), fill=o)
    d.point((4, ey + 1), fill=o)                # whisker hints
    d.point((19, ey + 1), fill=o)

    if p["spikes"] is not None:
        for (x, y) in BRILL_SPIKES[p["spikes"]]:
            d.point((x, y), fill=o)

    return img


GLITCH_PAL = {
    "outline": (24, 40, 18, 255),
    "body":    (148, 230, 58, 255),
    "dark":    (98, 170, 30, 255),
    "accent":  (235, 64, 190, 255),
    "white":   (255, 255, 255, 255),
    "mouth":   (40, 18, 36, 255),
}

GLITCH_SPIKE_ANGLES = [155, 120, 90, 60, 25]


def render_glitch(p: dict) -> Image.Image:
    # The original upright, front-facing chaotic spike-ball. The same frame
    # drives base.png and every animation; the GIFs just shimmer the spikes,
    # jitter, flash, and scatter pixels.
    c = GLITCH_PAL
    img = blank()
    d = ImageDraw.Draw(img)
    # Glitch's whole outline flips magenta on flash frames: cheap "corrupted
    # sprite" effect that doesn't disturb the silhouette.
    o = c["accent"] if p.get("flash") else c["outline"]
    cock = p.get("cock", 0)

    roll = p["spike_roll"] if "spike_roll" in p else p["tick"]
    cx, cy = 11.5, 14.5
    for k, ang in enumerate(GLITCH_SPIKE_ANGLES):
        a = math.radians(ang)
        rt = 10.0 if (k + roll) % 2 == 0 else 9.0
        tip = (cx + rt * math.cos(a), cy - rt * math.sin(a))
        b1 = (cx + 6 * math.cos(a - 0.35), cy - 6 * math.sin(a - 0.35))
        b2 = (cx + 6 * math.cos(a + 0.35), cy - 6 * math.sin(a + 0.35))
        col = c["body"] if (k + roll) % 2 == 0 else c["accent"]
        d.polygon([tip, b1, b2], fill=col, outline=o)

    d.ellipse((5, 8, 18, 21), fill=c["body"], outline=o)
    d.rectangle((7, 21, 8, 21), fill=c["dark"])
    d.rectangle((15, 21, 16, 21), fill=c["dark"])

    pdx = clamp(p["pdx"], -1, 1)
    if p["eyes"] == "huge":
        d.rectangle((6, 9, 9, 12), fill=c["white"])
        d.rectangle((13, 9 - cock, 16, 12 - cock), fill=c["white"])
        d.point((7 + pdx, 10), fill=c["mouth"])
        d.point((15 + pdx, 11 - cock), fill=c["mouth"])
    else:
        d.rectangle((7, 10, 9, 12), fill=c["white"])
        d.rectangle((13, 10 - cock, 14, 11 - cock), fill=c["white"])
        d.point((8 + pdx, 11), fill=c["mouth"])
        d.point((13 + clamp(pdx, 0, 1), 10 - cock), fill=c["mouth"])

    if p["mouth"] == "open":
        d.ellipse((9, 14, 14, 19), fill=c["mouth"], outline=o)
        d.point((10, 14), fill=c["white"])
        d.point((13, 14), fill=c["white"])
        d.rectangle((11, 17, 12, 17), fill=c["accent"])
    else:
        d.rectangle((8, 15, 15, 17), fill=c["mouth"], outline=o)
        for tx in (9, 11, 13):
            d.point((tx, 15), fill=c["white"])
        for tx in (10, 12, 14):
            d.point((tx, 17), fill=c["white"])

    if p["scatter"] is not None:
        ph = p["scatter"]
        for k in range(10):
            a = math.radians(k * 36 + ph * 12)
            rad = 7 + ((k * 3 + ph * 2) % 7)
            x = round(cx + rad * math.cos(a))
            y = round(cy - rad * math.sin(a))
            if 0 <= x < S and 0 <= y < S:
                d.point((x, y), fill=(c["accent"] if k % 2 else c["body"]))

    return img


# ---------------------------------------------------------------------------
# Animations. Each builder returns {anim_name: (list_of_poses, frame_ms)}.
# Frame counts stay in 8..14 and durations in 90..120 per the pet contract.
# ---------------------------------------------------------------------------

# The neutral, upright, front-facing portraits. base.png (the menu-dropdown
# preview) renders straight from these, and the animation builders below layer
# only in-place motion (blink, breathe, glint, tail-flick, scatter, ...) on top
# — the pets never attach to or lean against the bracket line.
SCOUT_NEUTRAL = {"wings": "rest", "pdx": 0, "pdy": 0, "blink": False,
                 "glint": False, "exclaim": False, "tick": 0}
MOCHI_NEUTRAL = {"mouth": "smile", "sparkle": True, "blink": False,
                 "heart": None, "star": False, "edx": 0, "blush": "norm", "tick": 0}
BRILL_NEUTRAL = {"tail": 0, "eyes": "half", "ears": "normal", "arch": False,
                 "spikes": None, "mouth": "short", "tick": 0}
# No spike_roll here on purpose: the renderer falls back to the per-frame
# tick, so spike colors shimmer during fly/track and hold frames stay unique.
GLITCH_NEUTRAL = {"eyes": "grin", "mouth": "grin", "pdx": 0,
                  "scatter": None, "flash": False, "tick": 0}


def _seq(neutral: dict, count: int, **channels) -> list:
    """Expand per-frame channel lists over a neutral pose; the odd/even tick
    is always injected so hold frames can never collapse (see docstring)."""
    poses = []
    for i in range(count):
        p = dict(neutral)
        p["tick"] = i % 2
        for key, values in channels.items():
            p[key] = values[i] if isinstance(values, (list, tuple)) else values
        poses.append(p)
    return poses


def fly_in_poses(neutral: dict) -> list:
    # Simple centred pop-in: scale up from small to full. (The live app drives
    # the real entrance; this preview GIF just needs to be a valid loop.)
    scales = [0.3, 0.45, 0.6, 0.72, 0.82, 0.9, 0.96, 1.0, 1.0, 1.0]
    return _seq(dict(neutral), len(scales), scale=scales)


def fly_out_poses(neutral: dict) -> list:
    # Simple centred pop-out: scale down to a sliver. Every scale differs so no
    # two frames are byte-identical (the build() guard rejects that).
    scales = [1.0, 0.92, 0.82, 0.72, 0.6, 0.5, 0.4, 0.32]
    return _seq(dict(neutral), len(scales), scale=scales)


def scout_anims() -> dict:
    # Analyst: a calm upright owl that blinks, breathes, and glints its lenses;
    # wings flare on alarm.
    p = SCOUT_NEUTRAL
    idle = _seq(p, 12,
                blink=[False] * 9 + [True, True, False],
                glint=[False, False, False, True, True, False] * 2)
    track = _seq(p, 10,
                 glint=[False, False, True, True, False, False, True, True, False, False])
    alert = _seq(p, 12, wings="up",
                 dy=[-(i % 2) for i in range(12)],
                 exclaim=[(i % 6) < 4 for i in range(12)],
                 glint=[(i % 6) >= 4 for i in range(12)])
    return {"idle": (idle, 110), "track": (track, 100), "alert": (alert, 90),
            "fly_in": (fly_in_poses(SCOUT_NEUTRAL), 90),
            "fly_out": (fly_out_poses(SCOUT_NEUTRAL), 90)}


def mochi_anims() -> dict:
    # Companion: a warm upright blob that sparkles and blinks, sends a little
    # heart while watching, and bounces with delight on alarm.
    p = MOCHI_NEUTRAL
    idle = _seq(p, 12, star=True,
                blink=[False] * 9 + [True, True, False])
    track = _seq(p, 10, star=True,
                 heart=[None, None, "small", "small", "small", "small", "small", "small", None, None])
    # blush="big" pins the breathing tick, so the bounce keeps every consecutive
    # frame distinct via dy, which never repeats back-to-back.
    alert = _seq(p, 12, mouth="o", blush="big", sparkle=False,
                 dy=[0, -2, -3, -2, -3, -1, 0, -2, -1, 0, -1, 0],
                 heart=[("big" if i % 4 < 2 else "small") for i in range(12)])
    return {"idle": (idle, 110), "track": (track, 100), "alert": (alert, 90),
            "fly_in": (fly_in_poses(MOCHI_NEUTRAL), 90),
            "fly_out": (fly_out_poses(MOCHI_NEUTRAL), 90)}


def brill_anims() -> dict:
    # Skeptical: an upright cat that flicks its tail and half-lids its eyes,
    # squints while watching, and arches/bristles on alarm.
    p = BRILL_NEUTRAL
    idle = _seq(p, 12,
                tail=[0, 0, 0, 1, 1, 2, 2, 2, 1, 0, 0, 0],
                eyes=["half"] * 8 + ["closed", "closed", "half", "half"])
    track = _seq(p, 10, eyes="squint", ears="turn",
                 tail=[1, 1, 1, 2, 2, 2, 1, 1, 1, 1])
    alert = _seq(p, 12, arch=True, tail="up", mouth="flat",
                 spikes=[i % 2 for i in range(12)],
                 eyes=["flat"] * 10 + ["closed", "closed"])
    return {"idle": (idle, 110), "track": (track, 100), "alert": (alert, 90),
            "fly_in": (fly_in_poses(BRILL_NEUTRAL), 90),
            "fly_out": (fly_out_poses(BRILL_NEUTRAL), 90)}


def glitch_anims() -> dict:
    # Chaotic: an upright spike-ball that never holds still -- spikes shimmer,
    # it jitters, flashes, and scatters pixels.
    p = GLITCH_NEUTRAL
    idle = _seq(p, 10,
                dy=[-(i % 2) for i in range(10)],
                pdx=[i % 2 for i in range(10)],
                spike_roll=[i % 2 for i in range(10)])
    track = _seq(p, 12,
                 dy=[-(i % 2) for i in range(12)],
                 pdx=[(-1) ** i for i in range(12)],
                 scatter=list(range(12)),
                 spike_roll=[i % 2 for i in range(12)],
                 flash=[(i % 5 == 0) for i in range(12)])
    alert = _seq(p, 12, eyes="huge", mouth="open",
                 dy=[-(i % 2) for i in range(12)],
                 scatter=list(range(12)),
                 spike_roll=[i % 2 for i in range(12)],
                 flash=[(i % 4 == 0) for i in range(12)])
    return {"idle": (idle, 100), "track": (track, 100), "alert": (alert, 90),
            "fly_in": (fly_in_poses(GLITCH_NEUTRAL), 90),
            "fly_out": (fly_out_poses(GLITCH_NEUTRAL), 90)}


# ---------------------------------------------------------------------------
# Speech templates. Shown verbatim in a small bubble; the hard rules are
# <= 90 chars, no placeholders, and "uncertain" must hedge, never alarm.
# ---------------------------------------------------------------------------

TEMPLATES = {
    "builtin.analyst": {
        "safe": [
            "Rhythm and word choice vary naturally. This reads human.",
            "Burstiness is healthy. No machine fingerprints found.",
            "Sentence lengths swing like a person wrote them. Clear.",
            "Vocabulary is irregular in the good way. Human signal.",
            "No template structures detected. Looks organic.",
            "Typos, tangents, texture. People write like this.",
        ],
        "uncertain": [
            "Mixed signals. I would not call this either way.",
            "Some even pacing, but plenty of human noise. Inconclusive.",
            "The data is ambiguous. Withholding judgment.",
            "Short sample, weak signal. Treat any score as a guess.",
            "Could be edited prose, could be a model. Not enough evidence.",
            "I see overlap with both styles. No verdict from me.",
        ],
        "suspicious": [
            "Sentence rhythm is unusually even here.",
            "Low burstiness and tidy transitions. Worth a closer look.",
            "Hedged claims, balanced clauses. A familiar pattern.",
            "Word variety is flatter than typical human prose.",
            "Every paragraph lands at the same length. Notable.",
            "Connective phrasing looks templated. Keep that in mind.",
        ],
        "high": [
            "Multiple stylometric markers align with AI generation.",
            "Uniform cadence, stock phrasing, zero typos. Strong signal.",
            "This matches model output on most of my checks.",
            "Statistically, humans rarely write this evenly.",
            "High confidence: the structure here is machine-typical.",
            "The fingerprint is consistent across the whole passage.",
        ],
        "very_high": [
            "Provenance markers indicate machine generation. Near certain.",
            "Every check I ran agrees: this is model output.",
            "Confidence is at the top of my scale. AI-written.",
            "This is as close to certain as my analysis gets.",
            "Signal saturation. I would file this as AI text.",
            "Generated text, with metadata to match. Case closed.",
        ],
    },
    "builtin.companion": {
        "safe": [
            "This feels warm and human to me. Yay!",
            "Aww, real person words! My heart is happy.",
            "It reads like someone's true voice. Lovely!",
            "All cozy and human here. No worries at all!",
            "I can feel a person behind this one. So nice.",
            "Sweet, messy, human writing. The best kind!",
        ],
        "uncertain": [
            "Hmm, I honestly can't tell, friend. Let's not assume, okay?",
            "It's a little mixed... no jumping to conclusions!",
            "I'm not sure on this one. Maybe read it gently yourself?",
            "My senses are fuzzy here. Could be either, truly.",
            "No alarms from me! Just a tiny shrug. Sorry!",
            "It's okay to not know. And I really don't know!",
        ],
        "suspicious": [
            "Oh! It's a bit too tidy in places. Just a little.",
            "Some parts feel rehearsed... gently keep an eye out?",
            "The rhythm is very smooth. Maybe too smooth, hon.",
            "I sense a few robot-y habits. Only a sprinkle!",
            "It might have had machine help. No panic, just care.",
            "Something feels practiced here. Stay curious, okay?",
        ],
        "high": [
            "Oh no, this really does look AI-written, friend.",
            "My tummy says a machine wrote most of this one.",
            "Lots of robot patterns... I'm fairly sure, sadly.",
            "I wish I had better news. This looks generated.",
            "It's very likely AI. Sending you a hug anyway!",
            "Strong robot vibes. Please double-check the source.",
        ],
        "very_high": [
            "I'm so sure it's AI that my cheeks went pale!",
            "This one is machine-made, sweetie. Almost certain.",
            "Every sign points to AI. I'm sorry, friend!",
            "It's generated text, through and through. Big hugs.",
            "No doubt left in my squishy heart: AI wrote this.",
            "Confirmed robot writing! Stay kind to yourself, okay?",
        ],
    },
    "builtin.skeptical": {
        "safe": [
            "Congratulations. A human typed this. Probably even sober.",
            "Messy, inconsistent, alive. Humans. It's real.",
            "No robot would write this badly. That's a compliment.",
            "Genuine human rambling detected. How quaint.",
            "It's human. The typos were the giveaway, genius.",
            "Real person, real words. Try to contain your excitement.",
        ],
        "uncertain": [
            "Could be a bot. Could be a dull human. I refuse to guess.",
            "Fifty-fifty. Flip a coin, I'm busy napping.",
            "Ambiguous. Much like my respect for this text.",
            "I have eight lives left and I'm wagering none on this.",
            "Inconclusive. Don't make it my problem.",
            "The evidence shrugged. So did I.",
        ],
        "suspicious": [
            "Ah, 'delve'. The official verb of robots everywhere.",
            "Suspiciously tidy. Like a crime scene that's been vacuumed.",
            "Every sentence the same length. How industrial.",
            "Smells faintly of silicon in here.",
            "This prose has the spontaneity of a tax form.",
            "Polished. Too polished. Nobody is this boring on purpose.",
        ],
        "high": [
            "This text has the pulse of a toaster.",
            "Strong AI odor. I'd know that beige voice anywhere.",
            "A machine wrote this, and it didn't even try to hide it.",
            "Generated. The em-dash budget alone gives it away.",
            "Humans blink. This text never blinks.",
            "I've coughed up hairballs with more personality. It's AI.",
        ],
        "very_high": [
            "Written by a machine. I'd bet eight of my nine lives.",
            "Certified robot. Frame it if you like.",
            "It's AI. Even the metadata confessed.",
            "Beyond doubt. The toaster has a byline now.",
            "One hundred percent synthetic. Like cheap catnip.",
            "Machine-made, provenance and all. Shocking. Truly.",
        ],
    },
    "builtin.chaotic": {
        "safe": [
            "HUMAN ALERT!! wait no, that's good. carry on, flesh author!!",
            "100% organic word soup!! certified MESSY!! i love it",
            "real human chaos detected. respect. RESPECT!!",
            "no robots here!! just vibes and typos. BEAUTIFUL.",
            "my sensors found NOTHING. a human did this. probably with elbows.",
            "this text smells like SNACKS and FREE WILL. human!!",
        ],
        "uncertain": [
            "uhhh my circuits say MAYBE?? do not panic. i said DO NOT.",
            "results unclear!! shaking the magic 8-ball again!!",
            "50/50!! could be bot, could be sleepy human. NO ALARMS YET.",
            "i ran the scan twice and got two shrugs. TWO.",
            "verdict machine broke. check back later. stay calm!!!",
            "is it AI?? is it not?? the mystery SUSTAINS me. no panic.",
        ],
        "suspicious": [
            "hmmMMM. these sentences are marching in FORMATION.",
            "tidy little paragraphs... TOO tidy... i'm watching you, text.",
            "robot crumbs detected!! tiny ones!! sniff sniff!!",
            "this prose did its homework. NOBODY does their homework.",
            "pattern alert!! the words are wearing UNIFORMS.",
            "something synthetic this way comes. probably. ish.",
        ],
        "high": [
            "BEEP BEEP!! this was built in a ROBOT WORD FACTORY!!",
            "AI DETECTED!! my spikes are VIBRATING!!",
            "this text never blinks. NEVER. machines, man.",
            "sirens!! confetti!! a model wrote this, i'm 90% unhinged about it!!",
            "the vibes are SYNTHETIC. evacuate the paragraph!!",
            "big robot energy. HUGE. colossal, even!!",
        ],
        "very_high": [
            "IT'S AI!! IT'S SO AI!! THE METADATA SCREAMED IT AT ME!!",
            "maximum robot!! my detector exploded into glitter!!",
            "certainty: YES. a machine wrote this. i ate the proof.",
            "100%!! not even a HINT of human. astonishing. ALARMING.",
            "provenance confirmed!! the robots didn't even hide it!!",
            "all sensors screaming AI!! i have never been so sure of ANYTHING.",
        ],
    },
}

STATES = ["safe", "uncertain", "suspicious", "high", "very_high"]

PETS = [
    {"id": "builtin.analyst", "name": "Scout", "base": "analyst",
     "tone": {"seriousness": 0.9, "verbosity": 0.4, "sarcasm": 0.1, "emotion": 0.2},
     "render": render_scout, "neutral": SCOUT_NEUTRAL, "anims": scout_anims},
    {"id": "builtin.companion", "name": "Mochi", "base": "companion",
     "tone": {"seriousness": 0.3, "verbosity": 0.6, "sarcasm": 0.0, "emotion": 0.9},
     "render": render_mochi, "neutral": MOCHI_NEUTRAL, "anims": mochi_anims},
    {"id": "builtin.skeptical", "name": "Brill", "base": "skeptical",
     "tone": {"seriousness": 0.7, "verbosity": 0.3, "sarcasm": 0.9, "emotion": 0.3},
     "render": render_brill, "neutral": BRILL_NEUTRAL, "anims": brill_anims},
    {"id": "builtin.chaotic", "name": "Glitch", "base": "chaotic",
     "tone": {"seriousness": 0.05, "verbosity": 0.8, "sarcasm": 0.6, "emotion": 1.0},
     "render": render_glitch, "neutral": GLITCH_NEUTRAL, "anims": glitch_anims},
]

GIF_ORDER = ["idle", "track", "alert", "fly_in", "fly_out"]


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

def encode_png(frame: Image.Image) -> bytes:
    buf = io.BytesIO()
    frame.save(buf, format="PNG")
    return buf.getvalue()


def encode_gif(frames: list, ms: int) -> bytes:
    # The exact RGBA->P recipe that survives PIL's GIF writer: quantize to 255
    # colors, reserve palette index 255, and paste it under a hard alpha mask.
    pal_frames = []
    for frame in frames:
        alpha = frame.getchannel("A")
        p = frame.convert("RGB").quantize(colors=255, method=Image.FASTOCTREE)
        mask = alpha.point(lambda a: 255 if a <= 128 else 0)
        p.paste(255, mask)
        pal_frames.append(p)
    buf = io.BytesIO()
    pal_frames[0].save(buf, format="GIF", save_all=True,
                       append_images=pal_frames[1:], duration=ms, loop=0,
                       transparency=255, disposal=2, optimize=False)
    return buf.getvalue()


def build_pet(spec: dict) -> dict:
    """Render every frame, encode assets, write src files + the pet JSON.
    Returns {asset_name: (bytes, n_frames)} for the summary table."""
    pet_id = spec["id"]
    src_dir = os.path.join(SRC_DIR, pet_id)
    os.makedirs(src_dir, exist_ok=True)

    produced = {}

    base_frame = upscale(compose(spec["render"], dict(spec["neutral"])))
    png = encode_png(base_frame)
    with open(os.path.join(src_dir, "base.png"), "wb") as f:
        f.write(png)
    produced["base.png"] = (png, 1)

    gif_b64 = {}
    for name, (poses, ms) in spec["anims"]().items():
        frames = [upscale(compose(spec["render"], p)) for p in poses]
        if not (8 <= len(frames) <= 14):
            raise AssertionError(f"{pet_id}/{name}: {len(frames)} frames out of 8..14")
        # Guard against Pillow's identical-consecutive-frame merging, which
        # would shrink n_frames behind our back (see module docstring).
        for i in range(len(frames) - 1):
            if frames[i].tobytes() == frames[i + 1].tobytes():
                raise AssertionError(f"{pet_id}/{name}: frames {i} and {i+1} identical")
        gif = encode_gif(frames, ms)
        with open(os.path.join(src_dir, f"{name}.gif"), "wb") as f:
            f.write(gif)
        produced[f"{name}.gif"] = (gif, len(frames))
        gif_b64[name] = base64.b64encode(gif).decode("ascii")

    # Key order below is the Codable contract; do not reorder.
    doc = {
        "id": pet_id,
        "name": spec["name"],
        "personality_base": spec["base"],
        "tone": spec["tone"],
        "speech_templates": {state: TEMPLATES[pet_id][state] for state in STATES},
        "animation_profile": {"idle": "idle", "track": "track", "alert": "alert"},
        "assets": {
            "base_png": base64.b64encode(png).decode("ascii"),
            "gifs": {name: gif_b64[name] for name in GIF_ORDER},
        },
    }
    json_path = os.path.join(PETS_DIR, f"{pet_id}.json")
    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=True, indent=2)
        f.write("\n")
    return produced


# ---------------------------------------------------------------------------
# Verification: re-read everything from disk and re-assert the contract.
# This intentionally goes through the JSON (the surface Swift consumes), not
# the in-memory objects, so an encoding bug can't hide.
# ---------------------------------------------------------------------------

def verify() -> None:
    rows = []
    for spec in PETS:
        pet_id = spec["id"]
        json_path = os.path.join(PETS_DIR, f"{pet_id}.json")
        raw = open(json_path, "rb").read()
        assert len(raw) < 1_200_000, f"{pet_id}: JSON {len(raw)} bytes >= 1.2 MB"
        doc = json.loads(raw)

        assert list(doc) == ["id", "name", "personality_base", "tone",
                             "speech_templates", "animation_profile", "assets"]
        assert doc["id"] == pet_id and doc["personality_base"] == spec["base"]
        assert list(doc["tone"]) == ["seriousness", "verbosity", "sarcasm", "emotion"]
        assert all(0.0 <= v <= 1.0 for v in doc["tone"].values())
        assert doc["animation_profile"] == {"idle": "idle", "track": "track",
                                            "alert": "alert"}
        assert list(doc["speech_templates"]) == STATES
        for state, lines in doc["speech_templates"].items():
            assert len(lines) >= 6, f"{pet_id}/{state}: needs >= 6 lines"
            for line in lines:
                assert line and len(line) <= 90, f"{pet_id}/{state}: bad length: {line!r}"
                assert line == line.strip(), f"{pet_id}/{state}: stray whitespace: {line!r}"
                assert line.isascii() and "{" not in line and "}" not in line

        png = base64.b64decode(doc["assets"]["base_png"])
        img = Image.open(io.BytesIO(png))
        assert img.format == "PNG" and img.size == (OUT, OUT) and img.mode == "RGBA"
        src = open(os.path.join(SRC_DIR, pet_id, "base.png"), "rb").read()
        assert src == png, f"{pet_id}: base.png differs between src and JSON"
        rows.append((pet_id, "base.png", 1, len(png)))

        assert list(doc["assets"]["gifs"]) == GIF_ORDER
        for name in GIF_ORDER:
            data = base64.b64decode(doc["assets"]["gifs"][name])
            gif = Image.open(io.BytesIO(data))
            assert gif.format == "GIF" and gif.is_animated, f"{pet_id}/{name}: not animated"
            assert 8 <= gif.n_frames <= 14, f"{pet_id}/{name}: {gif.n_frames} frames"
            assert gif.size == (OUT, OUT), f"{pet_id}/{name}: size {gif.size}"
            assert "transparency" in gif.info, f"{pet_id}/{name}: no transparency"
            assert gif.info.get("loop") == 0, f"{pet_id}/{name}: loop != 0"
            for fi in range(gif.n_frames):
                gif.seek(fi)
                # A duration outside 90..120 means Pillow merged frames.
                assert 90 <= gif.info["duration"] <= 120, \
                    f"{pet_id}/{name}[{fi}]: duration {gif.info['duration']}"
            src = open(os.path.join(SRC_DIR, pet_id, f"{name}.gif"), "rb").read()
            assert src == data, f"{pet_id}/{name}: gif differs between src and JSON"
            rows.append((pet_id, f"{name}.gif", gif.n_frames, len(data)))
        rows.append((pet_id, "<pet json>", "-", len(raw)))

    print(f"{'pet':<20} {'asset':<12} {'frames':>6} {'KB':>8}")
    print("-" * 50)
    for pet, asset, frames, size in rows:
        print(f"{pet:<20} {asset:<12} {frames!s:>6} {size / 1024:>8.1f}")
    print("\nAll checks passed.")


# ---------------------------------------------------------------------------
# Optional contact sheets for human eyeballs (PETGEN_PREVIEW=1). Mid-grey
# backing because the menu bar is never pure white or pure black.
# ---------------------------------------------------------------------------

def write_previews() -> None:
    out_dir = "/tmp/petgen-preview"
    os.makedirs(out_dir, exist_ok=True)
    for spec in PETS:
        anims = spec["anims"]()
        max_frames = max(len(poses) for poses, _ in anims.values())
        sheet = Image.new("RGBA", (max_frames * OUT, len(anims) * OUT),
                          (128, 128, 128, 255))
        draw = ImageDraw.Draw(sheet)
        for row, name in enumerate(GIF_ORDER):
            poses, _ = anims[name]
            for col, pose in enumerate(poses):
                frame = upscale(compose(spec["render"], pose))
                sheet.paste(frame, (col * OUT, row * OUT), frame)
                # Faux pole at each cell's right edge — where the live pet
                # panel meets the bracket bar — so the grips can be eyeballed
                # against the thing they're supposed to be clinging to. Drawn
                # ON TOP, matching the floating pet sitting above the bar.
                bx = col * OUT + OUT - SCALE * 2
                draw.rectangle((bx, row * OUT, bx + SCALE - 1, row * OUT + OUT - 1),
                               fill=(240, 196, 96, 235))
        sheet.save(os.path.join(out_dir, f"{spec['id']}.png"))
    print(f"previews -> {out_dir}")


def main() -> int:
    os.makedirs(PETS_DIR, exist_ok=True)
    for spec in PETS:
        build_pet(spec)
    verify()
    if os.environ.get("PETGEN_PREVIEW"):
        write_previews()
    return 0


if __name__ == "__main__":
    sys.exit(main())
