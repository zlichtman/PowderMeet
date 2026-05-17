#!/usr/bin/env python3
"""
Generate the PowderMeet house default ski topsheet.

When a user (or friend) hasn't picked a ski, SkiPairView showed a
flat dark capsule — reads as "broken / empty". This produces a real
branded topsheet so the empty state looks like a product: a long
ski-shaped band in the BrandStyle.powderMeet palette (navy→charcoal
body, brand-red speed stripe, gold tip) with the PowderMeet mountain
mark embossed mid-ski.

Output: PowderMeet/Resources/SkisTopsheets.xcassets/
        powdermeet-default.imageset/{powdermeet-default.png,Contents.json}
Spec: 1280×200 RGBA, transparent outside the ski silhouette
(SkiPairView trims by alpha), sRGB, 1× — matching every other
topsheet asset.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "PowderMeet" / "Resources" / "SkisTopsheets.xcassets"
LOGO = ROOT / "PowderMeet" / "Assets.xcassets" / "AppIcon.appiconset" / "icon-light-1024.png"
W, H = 1280, 200
SS = 3  # supersample


def hx(h, a=255):
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


# BrandStyle.powderMeet palette (mirrors Models/BrandStyle.swift)
BODY_TOP = hx("182A4D")   # deep navy
BODY_BOT = hx("0B1018")   # charcoal
STRIPE = hx("F23339")     # brand red
TIP = hx("FFD133")        # gold


def ski_mask(w: int, h: int) -> Image.Image:
    """A long, gently-tapered ski silhouette (rounded tip+tail)."""
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    midy = h / 2
    waist = h * 0.30          # half-height at the narrow waist
    tip = h * 0.42            # half-height at the ends
    pts_top, pts_bot = [], []
    n = 200
    for i in range(n + 1):
        t = i / n
        x = t * w
        # Slight hourglass: fuller at the ends, pinched mid-body.
        hh = waist + (tip - waist) * (abs(t - 0.5) * 2) ** 1.4
        pts_top.append((x, midy - hh))
        pts_bot.append((x, midy + hh))
    d.polygon(pts_top + pts_bot[::-1], fill=255)
    # Round the very ends.
    return m


def main() -> None:
    bw, bh = W * SS, H * SS
    canvas = Image.new("RGBA", (bw, bh), (0, 0, 0, 0))

    # Vertical body gradient.
    grad = Image.new("RGBA", (1, bh), (0, 0, 0, 0))
    for y in range(bh):
        t = y / (bh - 1)
        grad.putpixel((0, y), tuple(
            int(BODY_TOP[j] + (BODY_BOT[j] - BODY_TOP[j]) * t) for j in range(4)))
    body = grad.resize((bw, bh))

    d = ImageDraw.Draw(body)
    # Brand-red speed stripe down the centerline.
    sh = bh * 0.085
    d.rectangle([0, bh / 2 - sh, bw, bh / 2 + sh], fill=STRIPE)
    # Thin gold pinlines bracketing the stripe.
    pin = max(2, int(bh * 0.012))
    for yy in (bh / 2 - sh - pin * 2, bh / 2 + sh + pin):
        d.rectangle([0, yy, bw, yy + pin], fill=TIP)
    # Gold tip + tail caps.
    cap = int(bw * 0.05)
    d.rectangle([0, 0, cap, bh], fill=TIP)
    d.rectangle([bw - cap, 0, bw, bh], fill=TIP)

    # PowderMeet mountain mark embossed mid-ski (subtle, low alpha).
    if LOGO.exists():
        logo = Image.open(LOGO).convert("RGBA")
        lh = int(bh * 0.62)
        logo = logo.resize((lh, lh), Image.Resampling.LANCZOS)
        # Tint the mark to soft white + knock back alpha so it reads
        # as an emboss, not a sticker.
        arr = np.array(logo)
        mask = arr[..., 3] > 10
        arr[mask, 0:3] = (235, 238, 245)
        arr[..., 3] = (arr[..., 3].astype(np.float32) * 0.22).astype(np.uint8)
        logo = Image.fromarray(arr, "RGBA")
        body.alpha_composite(logo, (bw // 2 - lh // 2, bh // 2 - lh // 2))

    # Clip to the ski silhouette.
    mask = ski_mask(bw, bh).filter(ImageFilter.GaussianBlur(SS))
    canvas.paste(body, (0, 0), mask)

    out = canvas.resize((W, H), Image.Resampling.LANCZOS)
    set_dir = ASSETS / "powdermeet-default.imageset"
    set_dir.mkdir(parents=True, exist_ok=True)
    out.save(set_dir / "powdermeet-default.png", optimize=True)
    (set_dir / "Contents.json").write_text(json.dumps({
        "images": [
            {"idiom": "universal", "filename": "powdermeet-default.png",
             "scale": "1x"},
            {"idiom": "universal", "scale": "2x"},
            {"idiom": "universal", "scale": "3x"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))
    print(f"Wrote {set_dir/'powdermeet-default.png'}")


if __name__ == "__main__":
    main()
