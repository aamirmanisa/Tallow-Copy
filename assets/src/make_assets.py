#!/usr/bin/env python3
"""Render the tallowx README assets.

    python3 make_assets.py

Writes the SVG next to this file and a PNG one directory up. Every label is
converted to outlines, so no viewer font can shift a layout.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from brand import *  # noqa: F401,F403

HERE = os.path.dirname(os.path.abspath(__file__))
PARENT = os.path.dirname(HERE)


def motif(c):
    """The same bytes on both sides of the arrow, and the proof that they match."""
    b = []
    x0, y0 = 1050, 118
    for row in range(2):
        y = y0 + row * 76
        b.append(mono(x0, y - 16, "SRC", 12, c["faint"], spacing="2"))
        b.append(mono(x0 + 262, y - 16, "DST", 12, c["faint"], spacing="2"))
        for k in range(6):
            b.append(f'<rect x="{x0 + k*32}" y="{y}" width="22" height="6" fill="{c["rule"]}"/>')
        for k in range(6):
            b.append(f'<rect x="{x0 + 268 + k*32}" y="{y}" width="22" height="6" '
                     f'fill="{c["accent"] if row == 0 else c["rule"]}"/>')
        b.append(arrow(x0 + 204, y + 3, x0 + 254, y + 3,
                       c["accent"] if row == 0 else c["rule"], head=6))
    b.append(mono(x0, y0 + 2 * 76 + 8, "blake3 src == dst", 13, c["faint"], spacing="1"))
    return "".join(b)


def verification(c):
    W, H = 1500, 400
    b = [grain(W, H, c, 50)]
    b.append(mono(64, 58, "WHAT THE RUN PROVES", 16, c["faint"], spacing="3"))

    b.append(box(64, 104, 230, 90, c, fill=c["panel"]))
    b.append(mono(86, 138, "source", 17, c["text"]))
    b.append(mono(86, 166, "read-only", 13, c["muted"]))
    b.append(arrow(294, 149, 330, 149, c["rule"]))
    b.append(box(338, 104, 230, 90, c, fill=c["panel"]))
    b.append(mono(360, 138, "kernel copy", 17, c["text"]))
    b.append(mono(360, 166, "copy_file_range", 13, c["muted"]))
    b.append(arrow(568, 149, 604, 149, c["rule"]))
    b.append(box(612, 104, 230, 90, c, fill=c["panel"]))
    b.append(mono(634, 138, "destination", 17, c["text"]))
    b.append(mono(634, 166, "mode + mtime kept", 13, c["muted"]))
    b.append(arrow(842, 149, 878, 149, c["accent"]))

    b.append(f'<rect x="886" y="92" width="550" height="118" rx="6" fill="{c["panel2"]}" '
             f'stroke="{c["accent"]}" stroke-width="1.5"/>')
    b.append(mono(908, 124, "BLAKE3, read back from both files", 15, c["accent"]))
    b.append(mono(908, 158, "match    ->  exit 0   verified: N", 15, c["text"]))
    b.append(mono(908, 188, "mismatch ->  exit 1   failed: N", 15, c["muted"]))

    b.append(mono(64, 268, "and what it does not prove", 15, c["faint"], spacing="2"))
    b.append(box(64, 290, 430, 66, c, fill=c["panel"]))
    b.append(mono(84, 318, "a skip is size + mtime", 15, c["text"]))
    b.append(mono(84, 340, "--checksum hashes both sides first", 13, c["muted"]))
    b.append(box(514, 290, 430, 66, c, fill=c["panel"]))
    b.append(mono(534, 318, "no symlinks, xattrs or uid/gid", 15, c["text"]))
    b.append(mono(534, 340, "links are dereferenced into copies", 13, c["muted"]))
    b.append(box(964, 290, 472, 66, c, fill=c["panel"]))
    b.append(mono(984, 318, "--no-verify is faster and proves nothing", 15, c["text"]))
    b.append(mono(984, 340, "the flag exists to be measured against", 13, c["muted"]))
    return svg(W, H, "".join(b), c["bg"])


RECIPES = [
    ("tallowx-hero", lambda c: hero(1600, 420, "TALLOW / COPY TOOL", "tallowx",
                                    "Copy, then prove it arrived.",
                                    "COPY   ·   MOVE   ·   VERIFY   ·   PLAN",
                                    c, motif(c))),
    ("tallowx-verify", verification),
]

for name, render in RECIPES:
    for theme, c in THEMES.items():
        svg_text = render(c)
        src = os.path.join(HERE, f"{name}-{theme}.svg")
        open(src, "w").write(svg_text)
        head = svg_text.split(">", 1)[0]
        w = int(head.split('width="')[1].split('"')[0])
        h = int(head.split('height="')[1].split('"')[0])
        png = os.path.join(PARENT, f"{name}-{theme}.png")
        subprocess.run(["chromium", "--headless", "--no-sandbox", "--disable-gpu",
                        "--hide-scrollbars", f"--window-size={w},{h}",
                        f"--screenshot={png}", src], check=False, capture_output=True)
        print(f"{name}-{theme}.svg {w}x{h} -> {os.path.basename(png)}")
