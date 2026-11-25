"""Draws the battery percentage inside the status bar's battery glyph, as an iPhone
with Battery Percentage on does; the Simulator has no such switch.
Usage: battery_percent.py <in.png> <out.png> [percent]"""
import sys
from PIL import Image, ImageDraw, ImageFont

src, dst = sys.argv[1], sys.argv[2]
pct = sys.argv[3] if len(sys.argv) > 3 else "87"
im = Image.open(src).convert("RGBA")
W, H = im.size
px = im.load()
# The battery body: the bright and grey pixels right of the Wi-Fi glyph in the status bar.
x0, x1, y0, y1 = int(W * 0.83), int(W * 0.95), int(H * 0.02), int(H * 0.06)
body = [(x, y) for y in range(y0, y1) for x in range(x0, x1)
        if min(px[x, y][:3]) > 120 and max(px[x, y][:3]) - min(px[x, y][:3]) < 25]
bx0 = min(p[0] for p in body); by0 = min(p[1] for p in body); by1 = max(p[1] for p in body)
# Cut the nub off: the body ends where its column is shorter than most of the body's height.
cols = {}
for x, y in body: cols.setdefault(x, []).append(y)
full = [x for x, ys in cols.items() if max(ys) - min(ys) > (by1 - by0) * 0.7]
bx1 = max(full)
h = by1 - by0
font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", int(h * 0.78))
try:
    font.set_variation_by_name("Bold")
except Exception:
    pass
d = ImageDraw.Draw(im)
cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
d.text((cx, cy), pct, font=font, fill=(0, 0, 0, 255), anchor="mm")
im.convert("RGB").save(dst)
print(f"battery body x {bx0}-{bx1}, y {by0}-{by1}; drew {pct}")
