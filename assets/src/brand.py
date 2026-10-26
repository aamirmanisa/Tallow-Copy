"""Shared brand tokens and SVG helpers for the Tallow repo assets."""
from fontTools.ttLib import TTFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen

LATO = "/usr/share/fonts/truetype/lato/Lato-Black.ttf"
LATO_BOLD = "/usr/share/fonts/truetype/lato/Lato-Bold.ttf"
MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

THEMES = {
    "dark": {
        "bg": "#0D0C0B",
        "bg2": "#131110",
        "panel": "#171513",
        "panel2": "#1D1A17",
        "rule": "#2E2924",
        "text": "#F4EFE6",
        "muted": "#A79E8F",
        "faint": "#6E675D",
        "accent": "#E39B3E",
        "accent_soft": "#8A5A1E",
        "ok": "#6FAF8A",
        "warn": "#D2705C",
        "grid": "#1A1715",
    },
    "light": {
        "bg": "#FBF8F2",
        "bg2": "#F5F0E6",
        "panel": "#FFFFFF",
        "panel2": "#F7F2E8",
        "rule": "#E0D6C4",
        "text": "#17150F",
        "muted": "#6B6459",
        "faint": "#9A9184",
        "accent": "#A35C05",
        "accent_soft": "#D9A96A",
        "ok": "#2F7A53",
        "warn": "#A8402C",
        "grid": "#EDE5D7",
    },
}

_cache = {}


def face(path):
    if path not in _cache:
        f = TTFont(path)
        _cache[path] = (f, f.getGlyphSet(), f["head"].unitsPerEm)
    return _cache[path]


def text_width(path, text, size, tracking=0.0):
    tracking = float(tracking or 0.0)
    _, gs, upem = face(path)
    cmap = _cache[path][0].getBestCmap()
    scale = size / upem
    w = 0.0
    for ch in text:
        gname = cmap.get(ord(ch))
        if gname is None:
            gname = ".notdef"
        w += gs[gname].width * scale + tracking
    return w - (tracking if text else 0)


def text_path(x, y, text, size, path=LATO, tracking=0.0, anchor="start"):
    """Return an SVG path `d` for text, baseline at y, left edge at x."""
    tracking = float(tracking or 0.0)
    font, gs, upem = face(path)
    cmap = font.getBestCmap()
    scale = size / upem
    total = text_width(path, text, size, tracking)
    if anchor == "middle":
        x -= total / 2
    elif anchor == "end":
        x -= total
    d = []
    for ch in text:
        gname = cmap.get(ord(ch)) or ".notdef"
        g = gs[gname]
        pen = SVGPathPen(gs)
        tp = TransformPen(pen, (scale, 0, 0, -scale, x, y))
        g.draw(tp)
        d.append(pen.getCommands())
        x += g.width * scale + tracking
    return " ".join(part for part in d if part)


def T(x, y, text, size, fill, path=LATO, tracking=0.0, anchor="start", opacity=None):
    o = f' opacity="{opacity}"' if opacity is not None else ""
    if path == MONO:
        anchor_attr = f' text-anchor="{anchor}"' if anchor != "start" else ""
        return (f'<text x="{x}" y="{y}" font-family="DejaVu Sans Mono, ui-monospace, Menlo, monospace" '
                f'font-size="{size}" fill="{fill}"{anchor_attr}{o}>{esc(text)}</text>')
    d = text_path(x, y, text, size, path, tracking, anchor)
    return f'<path d="{d}" fill="{fill}"{o}/>'


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def mono(x, y, text, size, fill, anchor="start", opacity=None, spacing=None):
    """Monospace label rendered as outlines, so no viewer font can shift it."""
    o = f' opacity="{opacity}"' if opacity is not None else ""
    d = text_path(x, y, text, size, MONO, tracking=float(spacing or 0.0), anchor=anchor)
    return f'<path d="{d}" fill="{fill}"{o}/>' 


def box(x, y, w, h, c, fill="none", r=6, stroke=1, opacity=1.0):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" '
            f'stroke="{c["rule"] if stroke else "none"}" stroke-width="{stroke}" opacity="{opacity}"/>')


def arrow(x1, y1, x2, y2, color, width=1.4, head=7, dash=None):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    ang = __import__("math").atan2(y2 - y1, x2 - x1)
    import math
    hx1 = x2 - head * math.cos(ang - 0.45)
    hy1 = y2 - head * math.sin(ang - 0.45)
    hx2 = x2 - head * math.cos(ang + 0.45)
    hy2 = y2 - head * math.sin(ang + 0.45)
    return (f'<path d="M {x1} {y1} L {x2 - head*math.cos(ang)*0.4} {y2 - head*math.sin(ang)*0.4}" '
            f'stroke="{color}" stroke-width="{width}" fill="none"{d} stroke-linecap="round"/>'
            f'<path d="M {x2} {y2} L {hx1} {hy1} L {hx2} {hy2} Z" fill="{color}"/>')


def svg(w, h, body, bg):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
            f'role="img">\n<rect width="{w}" height="{h}" fill="{bg}"/>\n{body}\n</svg>\n')


def grain(w, h, c, step=40, opacity=0.5):
    """Barely-there grid: verticals and horizontals at low contrast."""
    out = [f'<g stroke="{c["grid"]}" stroke-width="1" stroke-opacity="0.55">']
    for x in range(step, w, step):
        out.append(f'<line x1="{x}" y1="0" x2="{x}" y2="{h}"/>')
    for y in range(step, h, step):
        out.append(f'<line x1="0" y1="{y}" x2="{w}" y2="{y}"/>')
    out.append("</g>")
    return "".join(out)


def hero(w, h, eyebrow, words, tagline, footer, c, motif=""):
    b = []
    b.append(f'<defs><radialGradient id="g" cx="18%" cy="30%" r="75%">'
             f'<stop offset="0%" stop-color="{c["accent"]}" stop-opacity="0.13"/>'
             f'<stop offset="55%" stop-color="{c["accent"]}" stop-opacity="0.02"/>'
             f'<stop offset="100%" stop-color="{c["accent"]}" stop-opacity="0"/>'
             f'</radialGradient></defs>')
    b.append(f'<rect width="{w}" height="{h}" fill="{c["bg"]}"/>')
    b.append(grain(w, h, c, 36))
    b.append(f'<rect width="{w}" height="{h}" fill="url(#g)"/>')
    # accent marker + eyebrow
    b.append(f'<rect x="96" y="86" width="10" height="10" fill="{c["accent"]}"/>')
    b.append(mono(120, 96, eyebrow, 17, c["muted"], spacing="3.4"))
    # wordmark
    b.append(T(92, 236, words, 128, c["text"], LATO, tracking=4))
    # tagline
    b.append(T(96, 300, tagline, 33, c["muted"], LATO_BOLD))
    # footer rule + labels
    b.append(f'<line x1="96" y1="{h - 52}" x2="{w - 96}" y2="{h - 52}" stroke="{c["rule"]}"/>')
    b.append(mono(96, h - 26, footer, 15, c["faint"], spacing="1.6"))
    b.append(motif)
    return svg(w, h, "".join(b), c["bg"])
