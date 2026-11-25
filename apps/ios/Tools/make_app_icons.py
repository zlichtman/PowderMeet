"""The PowderMeet icon maker: one family of alternate Home Screen icons.

Every icon is the PowderMeet mark, taken from the primary icon's master art
(`AppIcon.appiconset/icon-dark-1024.png`, never changed by this tool), with
its own palette and finish. The mark is separated into two coverage masks,
the small (red) peak and the big (white) peak; everything else, the snow-line
cuts included, is background. Each icon repaints the background, then lays
the two peaks over it in its own colours, so the outline is the original's to
the pixel.

    UV_PROJECT_ENVIRONMENT=~/Library/Caches/PowderMeet/tools-venv uv run make_app_icons.py

writes, from one painting of each icon in FAMILY, its `AppIcon-<Name>.appiconset`
(one 1024 px image) and the picker's `IconThumb-<Name>.imageset` (108 px, the
36 pt row at 3x; `IconThumb-Original` comes from the master, and each KEPT
icon's thumbnail from its own hand-kept icon set). The thumbnail
is needed because an alternate icon set compiles into Assets.car as an app
icon only: the build writes no loose `AppIcon-<Name>60x60` file, and
`UIImage(named:)` is not documented to load an app icon rendition. It then removes
every other `AppIcon-*`, `IconThumb-*` and stray `IconPreview*` set and saves
the contact sheet to `docs/screenshots/icons/contact-sheet.png`.

The names and order here are the ones `Theme/AppIcon.swift` and
`project.yml` (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`) list. No
finish adds noise: grain does not compress, and one grained icon was 1.2 MB.
"""

from __future__ import annotations

import argparse
import json
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

TOOLS = Path(__file__).resolve().parent
APP = TOOLS.parent / "PowderMeet"
ASSETS = APP / "Assets.xcassets"
MASTER = ASSETS / "AppIcon.appiconset" / "icon-dark-1024.png"
REPO = TOOLS.parents[2]
SHEET = REPO / "docs" / "screenshots" / "icons" / "contact-sheet.png"
SIZE = 1024

# The mark's own colours in the master, for separating its two peaks.
MASTER_RED = np.array([230.0, 56.0, 54.0])
MASTER_WHITE = np.array([235.0, 237.0, 245.0])


@dataclass(frozen=True)
class Icon:
    case: str  # the Swift case in AppIcon
    name: str  # what the picker shows; the asset is AppIcon-<name without spaces or accents>
    background: tuple[str, ...]  # top-to-bottom gradient stops
    small_peak: tuple[str, str]  # top, bottom
    big_peak: tuple[str, str]
    finish: tuple[str, ...] = field(default_factory=tuple)

    @property
    def asset(self) -> str:
        plain = self.name.replace("è", "e").replace(" ", "")
        return f"AppIcon-{plain}"


# The painted icons. `paint` keeps finishes no icon here uses (stars, snow,
# aurora bands, shadow, vignette, metal) for new ones.
FAMILY: list[Icon] = [
    Icon("alpenglow", "Alpenglow", ("#FFB15C", "#FF7A59", "#C7417A"),
         ("#5C1E4E", "#3C1238"), ("#3A1236", "#24081F"), ("sun",)),
]

# Icon sets kept as drawn, not painted here: the tool only writes their
# thumbnails from them: the two-tones, the two Retros and the Auroras. A kept
# set with dark art shows it everywhere, like PowderMeet: Retro is black with its stripes.
KEPT: list[tuple[str, str]] = [
    ("powder", "Powder"),
    ("carbon", "Carbon"),
    ("whiteout", "Whiteout"),
    ("retro", "Retro"),
    ("retroIce", "RetroIce"),
    ("aurora", "Aurora"),
    ("auroraDawn", "AuroraDawn"),
    ("auroraEmber", "AuroraEmber"),
    ("auroraIce", "AuroraIce"),
    ("auroraRose", "AuroraRose"),
]


# MARK: The mark


def rgb(hex_value: str) -> np.ndarray:
    value = hex_value.lstrip("#")
    return np.array([int(value[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def load_masks() -> tuple[np.ndarray, np.ndarray]:
    """Coverage of the small and big peaks, 0...1, by unmixing each pixel
    into the row's background plus some red and some white."""
    art = np.asarray(Image.open(MASTER).convert("RGB"), dtype=np.float64)
    assert art.shape[:2] == (SIZE, SIZE), "the master art is 1024 px"
    # The mark never reaches the left edge, so each row's background is there.
    background = np.median(art[:, :48, :], axis=1)[:, None, :]
    diff = art - background
    red = MASTER_RED[None, None, :] - background
    white = MASTER_WHITE[None, None, :] - background
    # Least squares for diff = r * red + w * white, per pixel.
    rr = (red * red).sum(-1)
    ww = (white * white).sum(-1)
    rw = (red * white).sum(-1)
    dr = (diff * red).sum(-1)
    dw = (diff * white).sum(-1)
    det = rr * ww - rw * rw
    r = (dr * ww - dw * rw) / det
    w = (dw * rr - dr * rw) / det
    r = np.clip(r, 0, 1)
    w = np.clip(w, 0, 1)
    total = r + w
    over = total > 1
    r[over] /= total[over]
    w[over] /= total[over]
    # Noise in flat background reads as faint ink; drop it.
    r[r < 0.02] = 0
    w[w < 0.02] = 0
    return r, w


# MARK: Painting


def vertical(stops: tuple[str, ...], top: int = 0, bottom: int = SIZE) -> np.ndarray:
    """A SIZE x SIZE x 3 gradient through `stops` between rows `top` and `bottom`."""
    colours = np.stack([rgb(s) for s in stops])
    y = np.clip((np.arange(SIZE) - top) / max(1, bottom - top), 0, 1)
    position = y * (len(stops) - 1)
    low = np.clip(np.floor(position).astype(int), 0, len(stops) - 2) if len(stops) > 1 else np.zeros(SIZE, int)
    t = (position - low)[:, None]
    column = colours[low] * (1 - t) + colours[np.minimum(low + 1, len(stops) - 1)] * t
    return np.broadcast_to(column[:, None, :], (SIZE, SIZE, 3)).copy()


def blurred(mask: np.ndarray, radius: float) -> np.ndarray:
    image = Image.fromarray((mask * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(image, dtype=np.float64) / 255


def over(base: np.ndarray, colour: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    a = alpha[..., None]
    return base * (1 - a) + colour * a


def disc(cx: float, cy: float, radius: float) -> np.ndarray:
    yy, xx = np.mgrid[0:SIZE, 0:SIZE]
    distance = np.hypot(xx - cx, yy - cy)
    return np.clip(radius - distance + 0.5, 0, 1)


def paint(icon: Icon, small: np.ndarray, big: np.ndarray, seed: int) -> Image.Image:
    rng = np.random.default_rng(seed)
    mark = np.clip(small + big, 0, 1)
    near_mark = blurred((mark > 0.05).astype(np.float64), 1) > 0
    near_mark = blurred(near_mark.astype(np.float64), 14) > 0.02
    bg = vertical(icon.background)
    finish = set(icon.finish)

    if "sun" in finish:
        # A low sun behind the big peak, lighter at its rim.
        sun = disc(612, 470, 250)
        bg = over(bg, rgb("#FFE3A3"), sun * 0.95)
        bg = over(bg, rgb("#FFF4D6"), disc(612, 470, 200) * 0.9)
    if "aurora" in finish:
        yy, xx = np.mgrid[0:SIZE, 0:SIZE]
        for amplitude, phase, centre, colour, strength in (
            (40, 0.0, 250, "#3BF0B0", 0.55), (30, 1.7, 320, "#2FB6E8", 0.4), (24, 3.1, 205, "#9B7BFF", 0.3)
        ):
            line = centre + amplitude * np.sin(xx / 150 + phase)
            band = np.exp(-((yy - line) / 38) ** 2) * (0.6 + 0.4 * np.sin(xx / 90 + phase * 2) ** 2)
            bg = over(bg, rgb(colour), np.clip(band * strength, 0, 1))
    if "stars" in finish:
        stars = np.zeros((SIZE, SIZE))
        for _ in range(70):
            x, y = rng.uniform(40, SIZE - 40), rng.uniform(60, 470)
            stars = np.maximum(stars, disc(x, y, rng.choice([1.6, 2.2, 3.0], p=[0.6, 0.3, 0.1])) * rng.uniform(0.35, 0.9))
        stars[near_mark] = 0
        bg = over(bg, rgb("#FFFFFF"), stars)
    if "snow" in finish:
        flakes = np.zeros((SIZE, SIZE))
        for _ in range(90):
            x, y = rng.uniform(0, SIZE), rng.uniform(0, SIZE)
            flakes = np.maximum(flakes, disc(x, y, rng.uniform(2.0, 4.5)) * rng.uniform(0.25, 0.6))
        flakes[near_mark] = 0
        bg = over(bg, rgb("#FFFFFF"), flakes)
    if "stripes" in finish:
        # Three print bands under the mark, as on a seventies patch.
        for i, colour in enumerate(("#E8732F", "#E9A93B", "#7A4A28")):
            top = 760 + i * 44
            band = np.zeros((SIZE, SIZE))
            band[top:top + 32, 150:874] = 1
            bg = over(bg, rgb(colour), blurred(band, 0.7))
    if "vignette" in finish:
        yy, xx = np.mgrid[0:SIZE, 0:SIZE]
        distance = np.hypot(xx - SIZE / 2, yy - SIZE * 0.45) / (SIZE * 0.75)
        bg = bg * (1 - 0.35 * np.clip(distance, 0, 1)[..., None] ** 2)
    if "shadow" in finish:
        shadow = blurred(np.roll(mark, 18, axis=0), 22)
        bg = bg * (1 - 0.22 * shadow[..., None])

    mark_top, mark_bottom = 350, 716
    small_fill = vertical(icon.small_peak, mark_top, mark_bottom)
    big_fill = vertical(icon.big_peak, mark_top, mark_bottom)
    if "metal" in finish:
        # A diagonal sheen across the gold.
        yy, xx = np.mgrid[0:SIZE, 0:SIZE]
        sheen = np.exp(-(((xx - yy) - 60) / 70) ** 2) * 0.55
        big_fill = over(big_fill, rgb("#FFF6D2"), sheen)
        small_fill = over(small_fill, rgb("#F4F6FA"), sheen * 0.8)

    out = bg * (1 - mark[..., None]) + small_fill * small[..., None] + big_fill * big[..., None]
    return Image.fromarray(np.clip(np.round(out), 0, 255).astype(np.uint8), "RGB")


# MARK: Output


def write_icon_set(icon: Icon, image: Image.Image) -> None:
    folder = ASSETS / f"{icon.asset}.appiconset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir()
    image.save(folder / "icon-1024.png", optimize=True)
    contents = {
        "images": [{"idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon-1024.png"}],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def write_thumb(suffix: str, image: Image.Image) -> None:
    folder = ASSETS / f"IconThumb-{suffix}.imageset"
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir()
    image.resize((108, 108), Image.LANCZOS).save(folder / "thumb.png", optimize=True)
    contents = {
        "images": [{"idiom": "universal", "filename": "thumb.png", "scale": "3x"}],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def remove_others(keep: set[str], thumbs: set[str]) -> list[str]:
    removed = []
    for folder in sorted(ASSETS.iterdir()):
        stale_icon = folder.suffix == ".appiconset" and folder.name.startswith("AppIcon-") and folder.stem not in keep
        stale_preview = folder.suffix == ".imageset" and folder.name.startswith("IconPreview")
        stale_thumb = folder.suffix == ".imageset" and folder.name.startswith("IconThumb-") and folder.stem not in thumbs
        if stale_icon or stale_preview or stale_thumb:
            shutil.rmtree(folder)
            removed.append(folder.name)
    return removed


def rounded(image: Image.Image, size: int) -> Image.Image:
    scaled = image.resize((size, size), Image.LANCZOS).convert("RGBA")
    mask = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size * 4 - 1, size * 4 - 1), radius=int(size * 4 * 0.2237), fill=255)
    scaled.putalpha(mask.resize((size, size), Image.LANCZOS))
    return scaled


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def contact_sheet(icons: list[tuple[str, Image.Image]]) -> None:
    columns, cell, icon_size, label = min(5, len(icons)), 260, 200, 44
    rows = -(-len(icons) // columns)
    small = 60
    strip_height = small + 60
    width = columns * cell + 40
    height = rows * (cell + label - 30) + strip_height + 80
    sheet = Image.new("RGB", (width, height), (238, 239, 242))
    draw = ImageDraw.Draw(sheet)
    title = font(26)
    draw.text((20, 18), "PowderMeet app icons", fill=(30, 30, 34), font=title)
    caption = font(20)
    for index, (name, image) in enumerate(icons):
        column, row = index % columns, index // columns
        x = 20 + column * cell + (cell - icon_size) // 2
        y = 64 + row * (cell + label - 30)
        sheet.paste(rounded(image, icon_size), (x, y), rounded(image, icon_size))
        text_width = draw.textlength(name, font=caption)
        draw.text((x + (icon_size - text_width) / 2, y + icon_size + 8), name, fill=(40, 40, 46), font=caption)
    # The same icons at Home Screen size, side by side.
    y = height - strip_height - 10
    draw.text((20, y), "At Home Screen size", fill=(90, 90, 96), font=caption)
    gap = (width - 40 - small * len(icons)) / max(1, len(icons) - 1)
    for index, (_, image) in enumerate(icons):
        x = int(20 + index * (small + gap))
        thumb = rounded(image, small)
        sheet.paste(thumb, (x, y + 34), thumb)
    SHEET.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(SHEET, optimize=True)


def main() -> None:
    argparse.ArgumentParser(description=__doc__.splitlines()[0]).parse_args()

    small, big = load_masks()
    master = Image.open(MASTER).convert("RGB")
    sheet = [("PowderMeet", master)]
    write_thumb("Original", master)
    thumbs = {"IconThumb-Original"}
    for case, name in KEPT:
        folder = ASSETS / f"AppIcon-{name}.appiconset"
        art = folder / "icon-dark-1024.png"
        image = Image.open(art if art.exists() else folder / "icon-1024.png").convert("RGB")
        write_thumb(name, image)
        thumbs.add(f"IconThumb-{name}")
        sheet.append((name, image))
        print(f"{'AppIcon-' + name:24} {case} (kept)")
    for index, icon in enumerate(FAMILY):
        image = paint(icon, small, big, seed=index + 1)
        write_icon_set(icon, image)
        write_thumb(icon.asset.removeprefix("AppIcon-"), image)
        thumbs.add(f"IconThumb-{icon.asset.removeprefix('AppIcon-')}")
        sheet.append((icon.name, image))
        print(f"{icon.asset:24} {icon.case}")
    removed = remove_others({icon.asset for icon in FAMILY} | {f"AppIcon-{name}" for _, name in KEPT}, thumbs)
    contact_sheet(sheet)
    print(f"removed {len(removed)} old sets; contact sheet at {SHEET.relative_to(REPO)}")


if __name__ == "__main__":
    main()
