#!/usr/bin/env python3
"""
Generate PowderMeet alternate AppIcon variants from the Avalanche template.

Source of truth for the recolored mountain themes. The primary
AppIcon plus the AppIcon-Avalanche TEMPLATE and the hand-tuned
Glacier set are skipped (Avalanche stays only as the recolor
template; its theme was culled). Each Theme has:

  • Icon left + right mountain colors (single-color themes set both to
    the same hex).
  • Accent (text + chrome).
  • Background (sheet + card surface, used by HUDTheme.mapBackground —
    near-black with a hue tint, Original keeps the legacy black).

This script also emits Swift enum case bodies for ThemeManager.Theme and
the Info.plist CFBundleAlternateIcons block.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Tuple

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "PowderMeet" / "Assets.xcassets"
TEMPLATE = ASSETS / "AppIcon-Avalanche.appiconset"


# ──────────────────────────────────────────────────────────────────────
# Theme metadata
# ──────────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Theme:
    raw: str           # Swift enum case + filename slug
    name: str          # Pascal-cased asset basename
    label: str         # UI label, uppercase
    subtitle: str      # UI subtitle, uppercase
    left_hex: str      # PEAK color — above the snow line on both mountains
    right_hex: str     # BASE color — below the snow line on both mountains
    accent_hex: str    # HUD accent (text + chrome)
    bg_hex: str        # HUD background (near-black, hue-tinted)


NORMAL = [
    Theme("original",  "Original",  "ORIGINAL",  "RED + BLACK PEAKS",
          "#E63333", "#0F0F0F", "#EB3333", "#0F0F12"),
    Theme("glacier",   "Glacier",   "GLACIER",   "COOL CYAN",
          "#73D6FF", "#73D6FF", "#73D6FF", "#08121A"),
    Theme("sunset",    "Sunset",    "SUNSET",    "PINK + ORANGE PEAKS",
          "#FF4D6D", "#FF8A3D", "#FF5C7F", "#190A10"),
    Theme("carbon", "Carbon",    "CARBON",    "GRAPHITE + GUNMETAL", "#6B7280", "#1F2937", "#6B7280", "#0E1014"),
]


UNIQUE = [
    # ── Single-color identities ──
    Theme("bluebird",   "Bluebird",   "BLUEBIRD",   "PURE SKY BLUE",
          "#4DA6FF", "#4DA6FF", "#4DA6FF", "#070F1A"),
    Theme("emerald",    "Emerald",    "EMERALD",    "DEEP EMERALD",
          "#10B981", "#10B981", "#10B981", "#06140F"),
    Theme("lagoon",     "Lagoon",     "LAGOON",     "TURQUOISE LAGOON",
          "#06B6D4", "#06B6D4", "#06B6D4", "#06141A"),
    Theme("rose",       "Rose",       "ROSE",       "DUSTY ROSE",
          "#F472B6", "#F472B6", "#F472B6", "#170B12"),
    Theme("solar",      "Solar",      "SOLAR",      "GOLDEN YELLOW",
          "#F59E0B", "#F59E0B", "#F59E0B", "#160F06"),
    Theme("pine",       "Pine",       "PINE",       "DEEP PINE",
          "#166534", "#166534", "#22A658", "#06120A"),
    Theme("sapphire",   "Sapphire",   "SAPPHIRE",   "DEEP SAPPHIRE",
          "#2563EB", "#2563EB", "#3B82F6", "#070B1C"),
    Theme("lavender",   "Lavender",   "LAVENDER",   "SOFT LAVENDER",
          "#A78BFA", "#A78BFA", "#A78BFA", "#10091A"),
    Theme("violet",     "Violet",     "VIOLET",     "PURE VIOLET",
          "#7C3AED", "#7C3AED", "#7C3AED", "#0C0818"),
    Theme("cherry",     "Cherry",     "CHERRY",     "CHERRY RED",
          "#DC2626", "#DC2626", "#EF4444", "#170707"),
    Theme("magenta",    "Magenta",    "MAGENTA",    "VIVID MAGENTA",
          "#D946EF", "#D946EF", "#D946EF", "#150818"),
    Theme("mintFrost",  "MintFrost",  "MINT FROST", "ICY MINT",
          "#A7F3D0", "#A7F3D0", "#5EEAD4", "#08141A"),
    Theme("ember",      "Ember",      "EMBER",      "GLOWING EMBER",
          "#EA580C", "#EA580C", "#F97316", "#160A04"),

    # ── Two-tone identities ──
    Theme("powder",       "Powder",       "POWDER",       "ICE BLUE + FROST",
          "#7DD3FC", "#E0F2FE", "#7DD3FC", "#08121A"),
    Theme("whiteout",     "Whiteout",     "WHITEOUT",     "FOG + LIGHT GRAY",
          "#9CA3AF", "#D1D5DB", "#9CA3AF", "#101216"),
    Theme("aurora",       "Aurora",       "AURORA",       "TEAL + VIOLET",
          "#22D3EE", "#A855F7", "#22D3EE", "#08121A"),
    Theme("fireside", "Fireside",     "FIRESIDE",     "EMBER + CHARCOAL", "#F97316", "#374151", "#F97316", "#140A06"),
    Theme("timber", "Timber",       "TIMBER",       "PINE + WALNUT", "#92400E", "#365314", "#84CC16", "#0A0F06"),
    Theme("evergreen", "Evergreen",    "EVERGREEN",    "FOREST + SAGE", "#A3E635", "#14532D", "#65A30D", "#08120A"),
    Theme("moonlit", "Moonlit",      "MOONLIT",      "SILVER + DEEP BLUE", "#CBD5E1", "#1E3A8A", "#CBD5E1", "#07091A"),
    Theme("nebula",       "Nebula",       "NEBULA",       "PURPLE + MAGENTA",
          "#7C3AED", "#EC4899", "#A855F7", "#100618"),
    Theme("infrared", "Infrared",     "INFRARED",     "MAGENTA + DEEP RED", "#E11D48", "#9F1239", "#E11D48", "#15060B"),
    Theme("retro",        "Retro",        "RETRO",        "MAGENTA + GOLD",
          "#FF3D81", "#FFC24B", "#FF3D81", "#110817"),
    Theme("stardust",     "Stardust",     "STARDUST",     "VIOLET + LAVENDER",
          "#7C3AED", "#C4B5FD", "#C4B5FD", "#100818"),
    Theme("crevasse", "Crevasse",     "CREVASSE",     "ICE + DEEP NAVY", "#38BDF8", "#1E3A8A", "#38BDF8", "#070A1A"),

    # ── Five extra pure colors (round PURE COLORS up to 25 = 5 rows) ──
    Theme("olive",      "Olive",      "OLIVE",      "OLIVE GREEN",
          "#84CC16", "#84CC16", "#84CC16", "#0E1206"),

    # ── Five extra combos (round COMBOS up to 30 = 6 rows) ──
    Theme("tidepool",   "Tidepool",   "TIDEPOOL",   "TURQUOISE + SAND",
          "#06B6D4", "#FED7AA", "#06B6D4", "#0A1014"),
]


# ──────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────


def hex_to_rgb(h: str) -> Tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def is_template_foreground(img: np.ndarray) -> np.ndarray:
    """LOOSE foreground mask — every red-ish pixel including the
    anti-aliased ramp at silhouette edges. Used for the recolor
    strength gradient so soft edges survive the recoloring."""
    r = img[..., 0].astype(np.int32)
    g = img[..., 1].astype(np.int32)
    b = img[..., 2].astype(np.int32)
    return (r > 100) & (r - g > 40) & (r - b > 40)


def is_template_core(img: np.ndarray) -> np.ndarray:
    """STRICT core mask — only saturated red pixels, no anti-aliased
    fringe. Used for connected-component labeling AND for snow-line
    gap detection so the two mountains stay cleanly separated and
    the loose mask's soft edges don't bridge them across the seam
    (which produced a pink artifact running down the gap between
    the two silhouettes)."""
    r = img[..., 0].astype(np.int32)
    g = img[..., 1].astype(np.int32)
    b = img[..., 2].astype(np.int32)
    return (r > 180) & (r - g > 90) & (r - b > 90)


def label_mountains(mask: np.ndarray) -> np.ndarray:
    """Connected-component label of the two mountain shapes (4-connectivity).
    Small noise blobs are absorbed into the nearest big neighbor.
    """
    structure = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], dtype=np.uint8)
    labels, n = ndimage.label(mask, structure=structure)
    if n <= 2:
        return labels
    sizes = ndimage.sum(mask, labels, index=np.arange(1, n + 1))
    centroids = ndimage.center_of_mass(mask, labels, index=np.arange(1, n + 1))
    sorted_by_size = np.argsort(sizes)[::-1]
    a, b = sorted_by_size[:2].tolist()
    a_lbl, b_lbl = a + 1, b + 1
    for i in range(n):
        lbl = i + 1
        if lbl == a_lbl or lbl == b_lbl:
            continue
        col = centroids[i][1]
        nearer_a = abs(col - centroids[a][1]) < abs(col - centroids[b][1])
        labels[labels == lbl] = a_lbl if nearer_a else b_lbl
    return labels


def peak_base_masks(strict_mask: np.ndarray, loose_mask: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    """Split foreground into PEAK (above the snow line) and BASE
    (below) FOLLOWING THE WAVE'S CURVE column by column.

    Per column, the snow line is the midpoint of the BIGGEST vertical
    gap between the mountain's strict-red runs — i.e. exactly where
    the white snow wave sits in that column. Using the per-column gap
    value verbatim (not a mean or a global median) is what makes the
    peak/base boundary hug the wave's curve tightly instead of
    cutting a flat horizontal line through it.

    The only subtlety is no-gap columns:
      • A column with NO detectable gap that sits OUTSIDE the span of
        gap-bearing columns is a bare flank — the thin sliver where
        the small mountain tucks behind the big one, or the outer
        skirts. There is no snowcap there, so its snow line is -1 →
        every pixel is base. (Falling back to a mid-mountain median
        here is exactly what dripped peak color down the small
        mountain's right edge.)
      • A no-gap column BETWEEN gap columns (a 1-px wave dropout) is
        linearly interpolated from its neighbours so the curve stays
        continuous.

    Loose-mask (anti-aliased) pixels inherit the classification of
    their nearest strict pixel, but only within 3 px — far enough to
    cover the silhouette's soft edge, close enough that the inter-
    mountain gap doesn't get painted.
    """
    labels = label_mountains(strict_mask)

    strict_peak = np.zeros_like(strict_mask, dtype=bool)
    strict_base = np.zeros_like(strict_mask, dtype=bool)

    for lbl in np.unique(labels):
        if lbl == 0:
            continue
        m = labels == lbl
        cols_present = np.where(m.any(axis=0))[0]
        rows_present = np.where(m.any(axis=1))[0]
        if cols_present.size == 0 or rows_present.size == 0:
            continue

        # Per-column snow line = midpoint of the column's biggest gap.
        per_column_snow: dict[int, float] = {}
        for c in cols_present:
            rows_c = np.where(m[:, c])[0]
            if rows_c.size < 2:
                continue
            diffs = np.diff(rows_c)
            gap_idx = int(np.argmax(diffs))
            if diffs[gap_idx] > 1:
                gap_top = int(rows_c[gap_idx])
                gap_bot = int(rows_c[gap_idx + 1])
                per_column_snow[int(c)] = (gap_top + gap_bot) / 2.0

        if per_column_snow:
            import bisect
            gap_cols = sorted(per_column_snow)
            # Median-filter the per-column snow line. The wave is
            # smooth so this preserves its curve, but an anomalously
            # low gap at the narrowing shoulder (a false gap between
            # the peak toe and base toe, not the real wave) gets
            # pulled back up to its neighbours — that false-low gap is
            # what dripped a thin pink tongue down the small mountain.
            if len(gap_cols) >= 5:
                vals = np.array([per_column_snow[c] for c in gap_cols],
                                dtype=np.float64)
                win = max(3, (len(vals) // 12) | 1)  # odd window
                smoothed = ndimage.median_filter(vals, size=win, mode="nearest")
                per_column_snow = {c: float(smoothed[i])
                                   for i, c in enumerate(gap_cols)}

            def snow_at(col: int) -> float:
                exact = per_column_snow.get(col)
                if exact is not None:
                    return exact
                # No detected gap in this column (the peak's narrowing
                # right/left shoulder, or a 1-px dropout). CONTINUE the
                # snow line from the surrounding gap columns rather than
                # forcing all-base — forcing base here is what left the
                # background mountain with only half its cap colored and
                # a hard line down the middle. Clamp past the ends so
                # the cap completes smoothly out to the silhouette.
                i = bisect.bisect_left(gap_cols, col)
                if i == 0:
                    return per_column_snow[gap_cols[0]]
                if i >= len(gap_cols):
                    return per_column_snow[gap_cols[-1]]
                left, right = gap_cols[i - 1], gap_cols[i]
                t = (col - left) / (right - left)
                return (per_column_snow[left] * (1.0 - t)
                        + per_column_snow[right] * t)
        else:
            top, bot = int(rows_present[0]), int(rows_present[-1])
            const_snow = top + (bot - top) / 3.0

            def snow_at(col: int) -> float:
                return const_snow

        for c in cols_present:
            rows_c = np.where(m[:, c])[0]
            if rows_c.size == 0:
                continue
            snow_line = snow_at(int(c))
            for r in rows_c:
                if r < snow_line:
                    strict_peak[r, c] = True
                else:
                    strict_base[r, c] = True

    # Remove the thin peak "finger" (the drip down the small
    # mountain's occluded sliver) WITHOUT eroding the real cap.
    # Two guards:
    #   1. A gentle opening (~7 px) only deletes features narrower
    #      than the tongue; the cap is 100s of px wide so it's
    #      untouched at this radius. (The earlier 18 px radius was
    #      eating most of the cap — that's the "95 % of the peak is
    #      a blob" regression.)
    #   2. Even so, ONLY demote removed pixels that sit BELOW the
    #      peak's own median row. The cap body is above its median;
    #      a downward tongue hangs well below it. So a nibble taken
    #      out of the cap edge by the opening is never demoted —
    #      only genuine low tongues are.
    if strict_peak.any():
        radius = max(1, int(strict_peak.shape[1] * 0.007))  # ~7 px @1024
        opened = ndimage.binary_opening(
            strict_peak, structure=np.ones((3, 3), dtype=bool),
            iterations=radius
        )
        removed = strict_peak & ~opened
        # Only demote removed regions LARGE enough to be a real drip
        # tongue (~100 px tall on the 1024 template). A 1-2 px nick the
        # opening takes out of the small mountain's cap edge is a tiny
        # component → left as peak, so the cap stays whole. The actual
        # tongue is a big component → demoted to base.
        comp, ncomp = ndimage.label(removed)
        finger = np.zeros_like(removed)
        if ncomp:
            min_tongue = int(strict_peak.shape[1] * 0.015) ** 2 // 4  # ~ tongue area
            comp_sizes = ndimage.sum(removed, comp, index=np.arange(1, ncomp + 1))
            for i, sz in enumerate(comp_sizes, start=1):
                if sz >= min_tongue:
                    finger |= comp == i
        strict_peak = strict_peak & ~finger
        strict_base = strict_base | finger

    classified = np.zeros_like(strict_mask, dtype=np.uint8)
    classified[strict_peak] = 1
    classified[strict_base] = 2
    if classified.any():
        dist, indices = ndimage.distance_transform_edt(
            classified == 0, return_indices=True
        )
        nearest = classified[indices[0], indices[1]]
        within_fringe = dist <= 3
    else:
        nearest = classified
        within_fringe = np.zeros_like(strict_mask, dtype=bool)
    effective = loose_mask & within_fringe
    peak_mask = (nearest == 1) & effective
    base_mask = (nearest == 2) & effective
    return peak_mask, base_mask


def recolor(
    src_path: Path,
    dst_path: Path,
    peak_color: Tuple[int, int, int],
    base_color: Tuple[int, int, int],
) -> None:
    """Two-tone recolor split between PEAKS (above snow line on both
    mountains) and BASES (below). Single-color themes pass identical
    colors and the split is harmless. Edge anti-alias preserved via
    the same `strength` ramp the original recolor used.
    """
    img = Image.open(src_path).convert("RGBA")
    arr = np.array(img)
    bg = arr[0, 0, :3].astype(np.int32)
    loose_mask = is_template_foreground(arr)
    strict_mask = is_template_core(arr)
    r = arr[..., 0].astype(np.float32)
    g = arr[..., 1].astype(np.float32)
    b = arr[..., 2].astype(np.float32)
    strength = np.clip((r - np.maximum(g, b)) / 200.0, 0.0, 1.0)
    peak_mask, base_mask = peak_base_masks(strict_mask, loose_mask)
    out = arr.copy()
    for mask, color in ((peak_mask, peak_color), (base_mask, base_color)):
        if not mask.any():
            continue
        s = strength[mask][..., None]
        target = np.array(color, dtype=np.float32)[None, :]
        bg_f = bg.astype(np.float32)[None, :]
        blended = (target * s + bg_f * (1.0 - s)).astype(np.uint8)
        out[mask, :3] = blended
    Image.fromarray(out, mode="RGBA").save(dst_path, optimize=True)


def write_appiconset(theme: Theme) -> None:
    set_dir = ASSETS / f"AppIcon-{theme.name}.appiconset"
    set_dir.mkdir(parents=True, exist_ok=True)
    peak = hex_to_rgb(theme.left_hex)   # left_hex repurposed as peak (above wave)
    base = hex_to_rgb(theme.right_hex)  # right_hex repurposed as base (below wave)
    for src_name, dst_name in [
        ("icon-light-1024.png", "icon-light-1024.png"),
        ("icon-dark-1024.png", "icon-dark-1024.png"),
        ("icon-tinted-1024.png", "icon-tinted-1024.png"),
    ]:
        recolor(TEMPLATE / src_name, set_dir / dst_name, peak, base)
    light = Image.open(set_dir / "icon-light-1024.png").convert("RGBA")
    for scale in (2, 3):
        size = 60 * scale
        resized = light.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(set_dir / f"icon-60@{scale}x.png", optimize=True)
    contents = {
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
    }
    (set_dir / "Contents.json").write_text(json.dumps(contents, indent=2))


def appiconset_dir(name: str) -> Path:
    """The asset-catalog AppIcon set for `name`. Original is the
    primary `AppIcon`; every other theme is an `AppIcon-<Name>`
    alternate."""
    return ASSETS / ("AppIcon.appiconset" if name == "Original"
                     else f"AppIcon-{name}.appiconset")


def sync_preview_imageset(name: str) -> None:
    """Rebuild `IconPreview<name>.imageset` so it carries BOTH a
    light and a dark-appearance variant, sourced from the sibling
    AppIcon set's existing 1024 pngs (this only COPIES already-built
    art — it never regenerates the hand-tuned / bespoke icons, so it
    is safe to run for every theme including the skipped ones).

    The theme picker resolves the variant against the *system*
    appearance, so a cell shows exactly how the home-screen icon
    looks for the user's current iOS Light/Dark setting.
    """
    appset = appiconset_dir(name)
    light_src = appset / "icon-light-1024.png"
    dark_src = appset / "icon-dark-1024.png"
    set_dir = ASSETS / f"IconPreview{name}.imageset"
    set_dir.mkdir(parents=True, exist_ok=True)
    Image.open(light_src).save(set_dir / "icon-1024.png", optimize=True)
    images = [{"idiom": "universal", "filename": "icon-1024.png", "scale": "1x"}]
    if dark_src.exists():
        Image.open(dark_src).save(set_dir / "icon-1024-dark.png", optimize=True)
        images.append({
            "idiom": "universal",
            "filename": "icon-1024-dark.png",
            "scale": "1x",
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
        })
    (set_dir / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2))


def write_preview_imageset(theme: Theme) -> None:
    sync_preview_imageset(theme.name)


# ──────────────────────────────────────────────────────────────────────
# Swift + Info.plist snippet emitters
# ──────────────────────────────────────────────────────────────────────


def color_swift_literal(hex_str: str) -> str:
    r, g, b = hex_to_rgb(hex_str)
    return f"Color(red: {r/255:.3f}, green: {g/255:.3f}, blue: {b/255:.3f})"


def emit_swift_cases() -> str:
    out = []
    out.append("        // ── Normal — the original eight ──")
    for t in NORMAL:
        out.append(f"        case {t.raw}")
    out.append("")
    out.append("        // ── Unique — generated by tools/generate_theme_icons.py ──")
    for t in UNIQUE:
        out.append(f"        case {t.raw}")
    return "\n".join(out)


def emit_switch(prop_name: str, render) -> str:
    out = []
    for t in NORMAL + UNIQUE:
        out.append(f"            case .{t.raw}: return {render(t)}")
    return "\n".join(out)


def emit_swift_strings_switch(field: str) -> str:
    return emit_switch(field, lambda t: f'"{getattr(t, field)}"')


def emit_swift_accent_switch() -> str:
    return emit_switch("accent_hex", lambda t: color_swift_literal(t.accent_hex))


def emit_swift_background_switch() -> str:
    return emit_switch("bg_hex", lambda t: color_swift_literal(t.bg_hex))


def emit_swift_alternate_switch() -> str:
    out = []
    for t in NORMAL + UNIQUE:
        if t.raw == "original":
            out.append(f"            case .{t.raw}: return nil")
        else:
            out.append(f'            case .{t.raw}: return "AppIcon-{t.name}"')
    return "\n".join(out)


def emit_swift_preview_switch() -> str:
    out = []
    for t in NORMAL + UNIQUE:
        out.append(f'            case .{t.raw}: return "IconPreview{t.name}"')
    return "\n".join(out)


def emit_infoplist_block() -> str:
    lines = []
    for t in NORMAL + UNIQUE:
        if t.raw == "original":
            continue
        lines.append(f"\t\t\t<key>AppIcon-{t.name}</key>")
        lines.append("\t\t\t<dict>")
        lines.append("\t\t\t\t<key>CFBundleIconFiles</key>")
        lines.append("\t\t\t\t<array>")
        lines.append(f"\t\t\t\t\t<string>AppIcon-{t.name}</string>")
        lines.append("\t\t\t\t</array>")
        lines.append("\t\t\t\t<key>UIPrerenderedIcon</key>")
        lines.append("\t\t\t\t<false/>")
        lines.append("\t\t\t</dict>")
    return "\n".join(lines)


def emit_normal_ids_swift() -> str:
    ids = ", ".join(f".{t.raw}" for t in NORMAL)
    return f"[{ids}]"


def emit_unique_ids_swift() -> str:
    ids = ", ".join(f".{t.raw}" for t in UNIQUE)
    return f"[{ids}]"


def main() -> None:
    # Skip the hand-tuned iconsets AND the bespoke icons. Original /
    # Alpenglow / Glacier / Verdant are tuned by hand. Retro and
    # Aurora are NOT mountain recolors — they're bespoke artwork owned
    # by tools/generate_core_icons.py. Regenerating either here would
    # clobber that art back to a recolored mountain. Never touch them.
    # (The AppIcon-Avalanche set stays as the recolor TEMPLATE even
    # though the Avalanche theme itself was culled.)
    skip = {
        "original", "glacier", "retro", "aurora",
    }
    for theme in NORMAL + UNIQUE:
        if theme.raw in skip:
            continue
        print(f"Generating AppIcon-{theme.name}…")
        write_appiconset(theme)
        write_preview_imageset(theme)

    # Light+dark preview sync for EVERY theme — including the skipped
    # hand-tuned (original/avalanche/alpenglow/glacier/verdant) and
    # bespoke core (retro/aurora/blackDiamond/matrix) sets. This only
    # copies their already-built appiconset pngs into the preview
    # imageset with a dark-appearance entry; it never touches the
    # icon art itself, so the skip rule is not violated.
    print("Syncing light/dark preview imagesets for all themes…")
    for theme in NORMAL + UNIQUE:
        sync_preview_imageset(theme.name)

    print()
    print("// ── Swift: enum cases ──")
    print(emit_swift_cases())
    print()
    print("// ── Swift: label switch ──")
    print(emit_swift_strings_switch("label"))
    print()
    print("// ── Swift: subtitle switch ──")
    print(emit_swift_strings_switch("subtitle"))
    print()
    print("// ── Swift: accentColor switch ──")
    print(emit_swift_accent_switch())
    print()
    print("// ── Swift: backgroundColor switch ──")
    print(emit_swift_background_switch())
    print()
    print("// ── Swift: alternateIconName switch ──")
    print(emit_swift_alternate_switch())
    print()
    print("// ── Swift: previewImageName switch ──")
    print(emit_swift_preview_switch())
    print()
    print("// ── Swift: ordered NORMAL ids ──")
    print(emit_normal_ids_swift())
    print()
    print("// ── Swift: ordered UNIQUE ids ──")
    print(emit_unique_ids_swift())
    print()
    print("<!-- Info.plist CFBundleAlternateIcons entries -->")
    print(emit_infoplist_block())
    print()
    print(f"Total themes: {len(NORMAL) + len(UNIQUE)} ({len(NORMAL)} normal + {len(UNIQUE)} unique)")


if __name__ == "__main__":
    main()
