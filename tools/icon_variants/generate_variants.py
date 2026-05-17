"""Generate color-swapped AppIcon variants for PowderMeet.

Reads the base AppIcon.appiconset (light / dark / tinted) and produces
three alternate appiconsets: Alpenglow, Glacier, Verdant.

Per the existing icon's pixel layout:
  light:  bg=white, mtn1=red, mtn2=black, snowcap-cut=white
  dark:   bg=dark,  mtn1=red, mtn2=white, snowcap-cut=dark
  tinted: bg=blue,  mtn1=red, mtn2=white, snowcap-cut=blue

User direction: both mountains become the theme color; the snowcap line
(which is bg-colored cutout) and the bg itself are preserved. So:

  - red pixels      → theme
  - "second mtn"    → theme
                       (light: black; dark+tinted: white)
  - bg + snowcap    → unchanged
  - antialias edges → blended toward theme proportionally

We do this with two binary masks (red-channel-dominant for the red
mountain; per-mode for the second mountain), feathered slightly so
edge anti-aliasing matches the original. Each mountain's mask is
multiplied by a per-pixel "ink amount" so semi-transparent edge
pixels get partial recolor and avoid halos.
"""

from __future__ import annotations
import json
from pathlib import Path
import numpy as np
from PIL import Image

REPO = Path("/Users/zachlichtman/Desktop/LIFE/PROJECT/PowderMeet-Dev")
SRC = REPO / "PowderMeet/Assets.xcassets/AppIcon.appiconset"
ASSETS = REPO / "PowderMeet/Assets.xcassets"

THEMES = {
    "Avalanche": (0.92, 0.20, 0.20),  # default red — both mountains red
    "Alpenglow": (1.00, 0.55, 0.20),  # warm orange
    "Glacier":   (0.45, 0.84, 1.00),  # cool cyan
    "Verdant":   (0.42, 0.88, 0.72),  # mint green
}


def to_u8(rgb_float):
    return np.array([round(c * 255) for c in rgb_float], dtype=np.float32)


def recolor(arr: np.ndarray, mode: str, theme_rgb_u8: np.ndarray) -> np.ndarray:
    """Return a recolored copy of arr (HxWx4 uint8) for the given mode.

    Strategy:
      - Build a soft mask M_red in [0,1] of "red mountain" intensity.
      - Build a soft mask M_mtn2 in [0,1] of "second mountain" intensity.
      - Where the mask is high, replace the pixel's color with the theme color
        but PRESERVE the original luminance (so anti-alias darkening at edges
        carries over). For solid interior pixels, this gives the flat theme
        color; for AA-edge pixels, it gives a smoothly darker theme color.
      - Pixels masked by neither stay untouched.
      - Where both masks are nonzero (rare; occurs only at touching edges),
        we average proportionally.
    """
    a = arr.astype(np.float32)
    R, G, B, A = a[..., 0], a[..., 1], a[..., 2], a[..., 3]

    # --- Red mountain mask ---
    # Red mountain interior is ~ (230, 56, 54). Edges fade to bg (white/dark/blue).
    # We use "redness" = max(0, R - max(G,B)) / 255, which is high for red and
    # near 0 for white/dark/blue background AND for black/white pixels.
    redness = np.clip(R - np.maximum(G, B), 0, 255) / 255.0
    # Saturate the mask quickly so AA-edge half-red pixels are still strongly
    # masked (otherwise we get a thin pink/red halo at the edge).
    M_red = np.clip(redness * 4.0, 0.0, 1.0)

    if mode == "light":
        # Second mtn is black against white bg. "blackness" = 1 - max(R,G,B)/255.
        blackness = 1.0 - np.maximum(np.maximum(R, G), B) / 255.0
        # Boost so AA edge (gray) pixels still get masked.
        M_mtn2 = np.clip(blackness * 1.6, 0.0, 1.0)
    elif mode == "dark":
        # Second mtn is bright white-ish (~235,237,245); bg is dark (~23,24,29);
        # snowcap line is also dark. Mask = whiteness (low for everything dark).
        whiteness = (R + G + B) / (3.0 * 255.0)
        # Threshold-shift so dark-bg pixels (whiteness ~ 0.1) read as 0 and
        # the white mtn fill (whiteness ~ 0.93) reads as ~1.
        M_mtn2 = np.clip((whiteness - 0.5) * 2.5, 0.0, 1.0)
    elif mode == "tinted":
        # Second mtn is white (~255,255,255); bg is blue (~57,127,217 to a
        # lighter top); snowcap line is bg blue. Mask = "non-blue brightness":
        # white has high R, blue has lower R relative to G/B. Use distance
        # from blue (B-dominant) instead.
        # Pure white: R=G=B=255. Blue bg: R<G<B, dist_to_white is large.
        # We want white pixels (mtn2) → 1, blue bg → 0, red pixels → 0 too.
        # "white-ness" works for both: average channel high AND channels equal.
        avg = (R + G + B) / 3.0
        # equality measure: 1 - normalized stdev across channels
        max_c = np.maximum(np.maximum(R, G), B)
        min_c = np.minimum(np.minimum(R, G), B)
        equality = 1.0 - (max_c - min_c) / 255.0
        M_mtn2 = np.clip((avg / 255.0) * equality, 0.0, 1.0)
        # Threshold-shift so blue bg (avg ~ 130, equality ~ 0.36) → ~0,
        # white mtn (avg=255, equality=1) → 1.
        M_mtn2 = np.clip((M_mtn2 - 0.55) * 4.0, 0.0, 1.0)
    else:
        raise ValueError(mode)

    # Red mtn mask should beat mtn2 mask wherever both apply (the red mtn
    # is in front of the black/white mtn).
    M_mtn2 = M_mtn2 * (1.0 - M_red)

    # Combined "mountain ink" mask
    M = np.clip(M_red + M_mtn2, 0.0, 1.0)

    # --- Compute target color per pixel ---
    # We want to preserve per-pixel luminance for AA edges. For interior
    # pixels (M=1, original is solid red or solid mtn2), output should be
    # the flat theme color. For AA edge pixels (M < 1), we blend.
    #
    # Trick: the existing AA pixel = blend(ink_color, bg_color, alpha_ink)
    # where alpha_ink ~ M. The "bg_color" beneath the ink varies (white/
    # dark/blue/etc.). We want the new pixel = blend(theme, bg_color, M).
    # We don't know bg_color directly, but original = M*ink + (1-M)*bg ⇒
    # bg = (original - M*ink) / (1-M). That's noisy when M→1.
    # Cleaner: replace the "ink" component with theme color directly.
    # new = M*theme + (1-M)*bg = original - M*ink + M*theme = original + M*(theme - ink).
    # The "ink" was red (230,56,54) for the red mtn and black/white/white for
    # mtn2. We use M_red and M_mtn2 separately so we subtract the right ink.

    RED_INK = np.array([230.0, 56.0, 54.0], dtype=np.float32)
    if mode == "light":
        MTN2_INK = np.array([0.0, 0.0, 0.0], dtype=np.float32)
    else:
        MTN2_INK = np.array([255.0, 255.0, 255.0], dtype=np.float32)

    theme = theme_rgb_u8.astype(np.float32)

    delta_red = (theme - RED_INK)[None, None, :]
    delta_mtn2 = (theme - MTN2_INK)[None, None, :]

    rgb = np.stack([R, G, B], axis=-1)
    rgb_new = rgb + M_red[..., None] * delta_red + M_mtn2[..., None] * delta_mtn2
    rgb_new = np.clip(rgb_new, 0.0, 255.0)

    out = np.empty_like(a)
    out[..., 0:3] = rgb_new
    out[..., 3] = A
    return np.clip(out, 0, 255).astype(np.uint8)


def main():
    src_files = {
        "light":  SRC / "icon-light-1024.png",
        "dark":   SRC / "icon-dark-1024.png",
        "tinted": SRC / "icon-tinted-1024.png",
    }
    base_arrays = {
        mode: np.array(Image.open(p).convert("RGBA"))
        for mode, p in src_files.items()
    }

    contents = json.loads((SRC / "Contents.json").read_text())

    for theme_name, theme_rgb in THEMES.items():
        theme_u8 = to_u8(theme_rgb)
        out_dir = ASSETS / f"AppIcon-{theme_name}.appiconset"
        out_dir.mkdir(parents=True, exist_ok=True)
        for mode, arr in base_arrays.items():
            new_arr = recolor(arr, mode, theme_u8)
            out_path = out_dir / f"icon-{mode}-1024.png"
            Image.fromarray(new_arr, "RGBA").save(out_path, "PNG")
            print(f"wrote {out_path}")
        # Contents.json — same shape as base (filenames identical).
        (out_dir / "Contents.json").write_text(json.dumps(contents, indent=2))
        print(f"wrote {out_dir / 'Contents.json'}")


if __name__ == "__main__":
    main()
