"""Makes the black outside an iPhone screenshot's rounded screen transparent, so the
screen keeps its shape on any background. Only black touching the image's edge goes:
the Dynamic Island, an enclosed black shape, stays.
Usage: round_corners.py <in.png> <out.png>"""
import sys
from PIL import Image, ImageDraw

image = Image.open(sys.argv[1]).convert("RGBA")
w, h = image.size
for corner in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
    if image.getpixel(corner)[:3] == (0, 0, 0):
        ImageDraw.floodfill(image, corner, (0, 0, 0, 0), thresh=0)
image.save(sys.argv[2])
