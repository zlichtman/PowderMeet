#!/usr/bin/env python3
"""
Generate a topographic-contour-lines PNG for the auth landing texture.

Produces `topo-lines.imageset/topo-lines.png` as a 2048×2048 RGBA
image with anti-aliased white strokes on a transparent background.
The PNG is bundled as a TEMPLATE image so SwiftUI re-tints the
strokes through `.foregroundColor(...)` — the active theme's accent
color flows through automatically.

Approach:
  1. Build a smooth 2D heightfield by Gaussian-blurring random noise.
  2. Run marching squares (`skimage.measure.find_contours`) at 28
     evenly-spaced elevations.
  3. Stroke each contour at 2px with PIL.ImageDraw, antialias via
     supersample-then-downsample.

Deterministic seed → same output every run, so re-running doesn't
flake the asset's visual.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter
from skimage import measure


SEED = 7
GRID = 256                   # height-field resolution
SS = 2                       # supersample factor for anti-aliasing
TARGET = 2048                # final PNG side
LEVELS = 28                  # contour rings
SIGMA = 14                   # smoothing for the heightfield
STROKE = 2                   # px at final target size
OUT = Path(__file__).resolve().parents[1] / "PowderMeet" / "Assets.xcassets" / "TopoLines.imageset"


def make_heightfield(grid: int, sigma: float, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    raw = rng.standard_normal((grid, grid))
    smooth = gaussian_filter(raw, sigma=sigma)
    # Stretch to [0, 1] for stable contour levels.
    lo, hi = smooth.min(), smooth.max()
    return (smooth - lo) / (hi - lo)


def render_contours(field: np.ndarray, target: int, levels: int, stroke: int, ss: int) -> Image.Image:
    big = target * ss
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    grid = field.shape[0]
    scale = big / grid

    level_values = np.linspace(0.04, 0.96, levels)
    for level in level_values:
        for contour in measure.find_contours(field, level):
            # contour: array of (row, col) — scale to image coords.
            pts = [(c * scale, r * scale) for r, c in contour]
            if len(pts) < 2:
                continue
            draw.line(pts, fill=(255, 255, 255, 255), width=stroke * ss, joint="curve")

    return img.resize((target, target), Image.Resampling.LANCZOS)


def write_imageset(img: Image.Image) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    img.save(OUT / "topo-lines.png", optimize=True)
    contents = """{
  "images" : [
    {
      "idiom" : "universal",
      "filename" : "topo-lines.png",
      "scale" : "1x"
    },
    {
      "idiom" : "universal",
      "scale" : "2x"
    },
    {
      "idiom" : "universal",
      "scale" : "3x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "template-rendering-intent" : "template"
  }
}
"""
    (OUT / "Contents.json").write_text(contents)


def main() -> None:
    field = make_heightfield(GRID, SIGMA, SEED)
    img = render_contours(field, TARGET, LEVELS, STROKE, SS)
    write_imageset(img)
    print(f"Wrote {OUT/'topo-lines.png'}")


if __name__ == "__main__":
    main()
