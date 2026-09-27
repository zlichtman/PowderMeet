#!/usr/bin/env python3
"""
Distinct bespoke artwork for the two icon themes that aren't simple
mountain recolors: Retro and Aurora. Both REUSE the real Avalanche
mountain silhouette (the launch art everyone likes) and restyle it.
(Diamond and Matrix/Beacon were both killed entirely.)

  • Retro  — the real mountains in a synthwave magenta→gold
             gradient with CRT scan-lines across the whole tile.
  • Aurora — the real mountains as a dark ridge under a polished
             multi-stop aurora gradient + soft curtain glows (no
             star dots — they read cheap at icon scale).

Each writes light / dark / tinted 1024 + 60@2x/3x + Contents.json into
AppIcon-<Name>.appiconset and a matching IconPreview imageset. Pure
PIL; deterministic; idempotent.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Tuple

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "PowderMeet" / "Assets.xcassets"
TEMPLATE = ASSETS / "AppIcon-Avalanche.appiconset"
S = 1024

RGBA = Tuple[int, int, int, int]


def hx(h: str, a: int = 255) -> RGBA:
    h = h.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)


LIGHT_BG = hx("FFFFFF")
DARK_BG = hx("0E0E12")
TINT_BG = hx("000000", 0)


def _template_arrays():
    """Return (mountain_mask, wave_mask) from the Avalanche template.

    mountain = red-ish foreground; wave = the interior white notch
    (non-foreground enclosed by the silhouette).
    """
    arr = np.array(Image.open(TEMPLATE / "icon-light-1024.png").convert("RGBA"))
    r = arr[..., 0].astype(np.int32)
    g = arr[..., 1].astype(np.int32)
    b = arr[..., 2].astype(np.int32)
    mountain = (r > 110) & (r - g > 35) & (r - b > 35)
    from scipy import ndimage
    not_fg = ~mountain
    seed = np.zeros_like(not_fg)
    seed[0, :] = not_fg[0, :]
    seed[-1, :] = not_fg[-1, :]
    seed[:, 0] = not_fg[:, 0]
    seed[:, -1] = not_fg[:, -1]
    exterior = ndimage.binary_propagation(seed, mask=not_fg)
    wave = not_fg & ~exterior
    return mountain, wave


_MOUNTAIN, _WAVE = _template_arrays()
_ROWS = np.arange(S)[:, None]
_MTN_ROWMAX = _MOUNTAIN.shape[0]


def _vertical_gradient(stops) -> np.ndarray:
    """stops: list of (t in 0..1, '#hex'). Returns (S,S,4) uint8."""
    cols = np.zeros((S, 4), dtype=np.float64)
    pts = [(t, np.array(hx(c), dtype=np.float64)) for t, c in stops]
    for y in range(S):
        t = y / (S - 1)
        for i in range(len(pts) - 1):
            t0, c0 = pts[i]
            t1, c1 = pts[i + 1]
            if t0 <= t <= t1:
                f = 0 if t1 == t0 else (t - t0) / (t1 - t0)
                cols[y] = c0 + (c1 - c0) * f
                break
        else:
            cols[y] = pts[-1][1]
    return np.repeat(cols[:, None, :], S, axis=1).astype(np.uint8)


# ── Retro: real mountains, synthwave gradient + scan-lines ────────

def _retro(bg: RGBA, stops: list) -> Image.Image:
    """Synthwave mountains: the real silhouette filled with a vertical
    `stops` gradient + CRT scan-lines. `stops` is [(t, '#hex'), …]."""
    grad = _vertical_gradient(stops)
    out = np.zeros((S, S, 4), dtype=np.uint8)
    out[..., :] = bg
    # Paint the mountain pixels with the gradient; keep the wave notch
    # as the background colour so the snow line still reads.
    out[_MOUNTAIN] = grad[_MOUNTAIN]
    img = Image.fromarray(out, "RGBA")

    # CRT scan-lines across the whole tile.
    d = ImageDraw.Draw(img, "RGBA")
    line_c = (0, 0, 0, 46) if bg == LIGHT_BG else (255, 255, 255, 32)
    step = int(S * 0.045)
    for y in range(0, S, step):
        d.rectangle([0, y, S, y + max(2, step // 6)], fill=line_c)
    return img


# ── Aurora: real ridge, polished aurora sky (parameterised) ───────

def _aurora(bg: RGBA, sky_stops: list, glow_hexes: tuple) -> Image.Image:
    """Real mountain ridge under a multi-stop aurora sky. `sky_stops`
    is [(t,'#hex'),…] for the vertical gradient; `glow_hexes` is three
    hex strings for the soft vertical curtain glows (no star dots —
    they read cheap at icon scale)."""
    sky = _vertical_gradient(sky_stops)
    base = Image.fromarray(sky, "RGBA")

    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    for cx, h in ((S * 0.30, glow_hexes[0]),
                  (S * 0.56, glow_hexes[1]),
                  (S * 0.78, glow_hexes[2])):
        w = int(S * 0.12)
        gd.ellipse([cx - w, S * 0.18, cx + w, S * 0.72],
                   fill=hx(h, 115))
    glow = glow.filter(ImageFilter.GaussianBlur(70))
    base.alpha_composite(glow)

    # Real mountain silhouette as a dark ridge in front.
    arr = np.array(base)
    ridge = hx("070B16")
    arr[_MOUNTAIN] = ridge
    arr[_WAVE] = ridge  # fill the snow notch so the ridge reads solid
    out = Image.fromarray(arr, "RGBA")

    if bg == TINT_BG:
        # Tinted icons must be a single-channel mask; collapse to the
        # ridge silhouette only so iOS can retint it.
        mask = np.zeros((S, S, 4), dtype=np.uint8)
        mask[_MOUNTAIN | _WAVE] = hx("FFFFFF")
        return Image.fromarray(mask, "RGBA")
    return out


# ── Asset writing ─────────────────────────────────────────────────

def _write(name: str, light: Image.Image, dark: Image.Image, tinted: Image.Image) -> None:
    icon_dir = ASSETS / f"AppIcon-{name}.appiconset"
    icon_dir.mkdir(parents=True, exist_ok=True)
    light.save(icon_dir / "icon-light-1024.png", optimize=True)
    dark.save(icon_dir / "icon-dark-1024.png", optimize=True)
    tinted.save(icon_dir / "icon-tinted-1024.png", optimize=True)
    for scale in (2, 3):
        sz = 60 * scale
        light.resize((sz, sz), Image.Resampling.LANCZOS).save(
            icon_dir / f"icon-60@{scale}x.png", optimize=True)
    (icon_dir / "Contents.json").write_text(json.dumps({
        "images": [
            {"idiom": "iphone", "size": "60x60", "scale": "2x", "filename": "icon-60@2x.png"},
            {"idiom": "iphone", "size": "60x60", "scale": "3x", "filename": "icon-60@3x.png"},
            {"idiom": "universal", "platform": "ios", "size": "1024x1024",
             "filename": "icon-light-1024.png"},
            {"idiom": "universal", "platform": "ios", "size": "1024x1024",
             "appearances": [{"appearance": "luminosity", "value": "dark"}],
             "filename": "icon-dark-1024.png"},
            {"idiom": "universal", "platform": "ios", "size": "1024x1024",
             "appearances": [{"appearance": "luminosity", "value": "tinted"}],
             "filename": "icon-tinted-1024.png"},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))

    # Preview imageset carries BOTH appearances so the theme picker
    # can resolve the cell against the user's *system* Light/Dark
    # setting (matching how the home-screen icon actually renders).
    prev = ASSETS / f"IconPreview{name}.imageset"
    prev.mkdir(parents=True, exist_ok=True)
    light.save(prev / "icon-1024.png", optimize=True)
    dark.save(prev / "icon-1024-dark.png", optimize=True)
    (prev / "Contents.json").write_text(json.dumps({
        "images": [
            {"idiom": "universal", "filename": "icon-1024.png", "scale": "1x"},
            {"idiom": "universal", "filename": "icon-1024-dark.png", "scale": "1x",
             "appearances": [{"appearance": "luminosity", "value": "dark"}]},
        ],
        "info": {"author": "xcode", "version": 1},
    }, indent=2))


# Retro colorways (synthwave mountain gradients).
RETRO_STOPS = {
    "Retro":    [(0.30, "#FF3D81"), (0.62, "#FF6B4A"), (1.0, "#FFC24B")],
    "RetroIce": [(0.30, "#22D3EE"), (0.62, "#3B82F6"), (1.0, "#A855F7")],
}

# Aurora colorways: (sky gradient stops, 3 curtain-glow hexes).
AURORA_VARIANTS = {
    "Aurora": ([(0.0, "#0A0A24"), (0.30, "#3B1E6E"), (0.52, "#B83C9A"),
                (0.72, "#2FA8C9"), (1.0, "#28C46B")],
               ("F472B6", "38BDF8", "A855F7")),
    "AuroraDawn": ([(0.0, "#0A0A24"), (0.34, "#6B21A8"), (0.60, "#D9468C"),
                    (0.80, "#F97316"), (1.0, "#FBBF24")],
                   ("F472B6", "FB923C", "FBBF24")),
    "AuroraEmber": ([(0.0, "#0A0A14"), (0.32, "#7F1D1D"), (0.58, "#C2410C"),
                     (0.80, "#EA580C"), (1.0, "#FBBF24")],
                    ("EA580C", "F59E0B", "9F1239")),
    "AuroraIce": ([(0.0, "#06121A"), (0.30, "#1E3A8A"), (0.58, "#0EA5C4"),
                   (0.80, "#22D3EE"), (1.0, "#5EEAD4")],
                  ("38BDF8", "5EEAD4", "22D3EE")),
    "AuroraRose": ([(0.0, "#1A0A24"), (0.32, "#7C3AED"), (0.58, "#B83C9A"),
                    (0.80, "#D9468C"), (1.0, "#F472B6")],
                   ("F472B6", "A855F7", "D9468C")),
}


def main() -> None:
    for name, stops in RETRO_STOPS.items():
        print(f"{name}…")
        _write(name,
               _retro(LIGHT_BG, stops),
               _retro(DARK_BG, stops),
               _retro(TINT_BG, stops))
    for name, (sky, glows) in AURORA_VARIANTS.items():
        print(f"{name}…")
        _write(name,
               _aurora(LIGHT_BG, sky, glows),
               _aurora(DARK_BG, sky, glows),
               _aurora(TINT_BG, sky, glows))
    print("Done.")


if __name__ == "__main__":
    main()
