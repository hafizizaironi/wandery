#!/usr/bin/env python3
"""Wandery App Store screenshot compositor (v2 — feature tour).

Per frame: abstract map-motif background (cover-crop) + cream top-scrim +
three-tier caption (mono kicker / Instrument Serif headline / sans subline) +
the real UI screenshot inside an iPhone frame WITH a Dynamic Island.
Output: 1320x2868.

Missing screenshot -> labelled placeholder, so layout previews before capture.

Usage:  python3 compose_screenshots.py [--manifest manifest.json] [--out ../out]
Requires: Pillow  (pip install pillow)
"""
import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_DIR = os.path.join(HERE, "fonts")

# ---- Brand ----------------------------------------------------------------
INK = (40, 37, 32)            # #282520
INK_MUTED = (74, 67, 60)
TERRACOTTA = (181, 82, 58)    # #B5523A
CREAM = (247, 245, 242)       # #F7F5F2
BEZEL = (18, 16, 14)          # near-black device body / Dynamic Island

SERIF = os.path.join(FONT_DIR, "InstrumentSerif-Regular.ttf")   # headline
MONO = os.path.join(FONT_DIR, "SpaceMono-Bold.ttf")             # kicker
FONTS_SANS = [                                                  # subline fallback
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/Helvetica.ttc",
]


def font(path_or_list, size):
    paths = path_or_list if isinstance(path_or_list, list) else [path_or_list]
    for p in paths:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


def cover_crop(img, w, h):
    img = img.convert("RGB")
    src, dst = img.width / img.height, w / h
    if src > dst:
        nw, nh = int(round(h * src)), h
    else:
        nw, nh = w, int(round(w / src))
    img = img.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - w) // 2, (nh - h) // 2
    return img.crop((left, top, left + w, top + h))


def rounded_mask(w, h, radius):
    m = Image.new("L", (w, h), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, h - 1], radius=radius, fill=255)
    return m


def top_scrim(canvas):
    """Cream gradient over the top third so the 3-tier caption reads on any bg."""
    h = int(canvas.height * 0.36)
    scrim = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(scrim)
    for y in range(h):
        a = int(235 * (1 - y / h) ** 1.5)
        sd.line([(0, y), (canvas.width, y)], fill=CREAM + (a,))
    return Image.alpha_composite(canvas.convert("RGBA"), scrim).convert("RGB")


def draw_tracked(draw, xy, text, fnt, fill, tracking):
    """Left-aligned text with extra per-glyph letter-spacing (PIL has none)."""
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=fnt, fill=fill)
        x += draw.textlength(ch, font=fnt) + tracking


def wrap(draw, text, fnt, max_w):
    lines, cur = [], ""
    for word in text.split():
        test = (cur + " " + word).strip()
        if draw.textlength(test, font=fnt) <= max_w:
            cur = test
        else:
            if cur:
                lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def draw_caption(canvas, eyebrow, headline, sub):
    draw = ImageDraw.Draw(canvas)
    margin = 112
    max_w = canvas.width - 2 * margin
    f_eye = font(MONO, 40)
    f_head = font(SERIF, 132)      # Instrument Serif runs small; size up
    f_sub = font(FONTS_SANS, 50)

    y = 150
    if eyebrow:
        draw_tracked(draw, (margin, y), eyebrow.upper(), f_eye, TERRACOTTA, 6)
        y += 86
    for line in wrap(draw, headline, f_head, max_w):
        draw.text((margin, y), line, font=f_head, fill=INK)
        y += 118
    y += 18
    for line in wrap(draw, sub, f_sub, max_w):
        draw.text((margin, y), line, font=f_sub, fill=INK_MUTED)
        y += 64


def build_device(screenshot_path, dev_w, label=""):
    bezel, radius = 18, 92
    inner_w = dev_w - 2 * bezel
    inner_h = int(round(inner_w * (19.5 / 9.0)))
    if screenshot_path and os.path.exists(screenshot_path):
        shot = cover_crop(Image.open(screenshot_path), inner_w, inner_h)
    else:
        shot = Image.new("RGB", (inner_w, inner_h), (237, 235, 230))
        d = ImageDraw.Draw(shot)
        d.multiline_text((inner_w / 2, inner_h / 2), f"[ {label} ]\nscreenshot\npending",
                         font=font(FONTS_SANS, 44), fill=(150, 144, 136),
                         anchor="mm", align="center", spacing=18)
    shot = shot.convert("RGBA")
    shot.putalpha(rounded_mask(inner_w, inner_h, radius - bezel))

    dev_h = inner_h + 2 * bezel
    device = Image.new("RGBA", (dev_w, dev_h), (0, 0, 0, 0))
    body = Image.new("RGBA", (dev_w, dev_h), BEZEL + (255,))
    body.putalpha(rounded_mask(dev_w, dev_h, radius))
    device.alpha_composite(body)
    device.alpha_composite(shot, (bezel, bezel))

    # Dynamic Island — black pill centered near the top of the screen
    isl_w = int(inner_w * 0.33)
    isl_h = int(isl_w * 0.30)
    isl_x = bezel + (inner_w - isl_w) // 2
    isl_y = bezel + int(inner_h * 0.018)
    di = Image.new("RGBA", (isl_w, isl_h), (0, 0, 0, 0))
    ImageDraw.Draw(di).rounded_rectangle([0, 0, isl_w - 1, isl_h - 1],
                                         radius=isl_h // 2, fill=BEZEL + (255,))
    device.alpha_composite(di, (isl_x, isl_y))
    return device


def compose(frame, cw, ch, base_dir, out_dir):
    canvas = Image.new("RGB", (cw, ch), CREAM)
    bg = os.path.join(base_dir, frame["background"])
    if os.path.exists(bg):
        canvas.paste(cover_crop(Image.open(bg), cw, ch), (0, 0))

    canvas = top_scrim(canvas)
    draw_caption(canvas, frame.get("eyebrow", ""), frame["headline"], frame.get("sub", ""))

    dev_w = int(cw * 0.66)
    device = build_device(os.path.join(base_dir, frame["screenshot"]), dev_w, frame["id"])
    dx = (cw - device.width) // 2
    dy = int(ch * 0.235)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sh = Image.new("RGBA", device.size, (0, 0, 0, 0))
    sh.paste((0, 0, 0, 120), (0, 0), device.split()[-1])
    shadow.alpha_composite(sh, (dx, dy + 28))
    shadow = shadow.filter(ImageFilter.GaussianBlur(36))
    canvas = Image.alpha_composite(canvas.convert("RGBA"), shadow).convert("RGB")
    canvas.paste(device, (dx, dy), device)

    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, frame["id"] + ".png")
    canvas.save(out)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default=os.path.join(HERE, "manifest.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "out"))
    args = ap.parse_args()
    with open(args.manifest) as f:
        man = json.load(f)
    base = os.path.dirname(os.path.abspath(args.manifest))
    cw, ch = man["canvas"]["width"], man["canvas"]["height"]
    for frame in man["frames"]:
        print("wrote", compose(frame, cw, ch, base, args.out))


if __name__ == "__main__":
    main()
