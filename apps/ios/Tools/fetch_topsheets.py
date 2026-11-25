"""Ski topsheets for the catalog: find them on the brands' own sites, fetch
them politely, and turn each into the image set the app draws.

    export UV_PROJECT_ENVIRONMENT=~/Library/Caches/PowderMeet/tools-venv
    uv run fetch_topsheets.py feed https://www.on3pskis.com      # list a Shopify store's skis
    uv run fetch_topsheets.py product <Shopify product URL>      # title, mm figures, images
    uv run fetch_topsheets.py page <product page URL>            # title, og:image, waist text
    uv run fetch_topsheets.py sitemap <sitemap URL> --grep ski   # product URLs
    uv run fetch_topsheets.py fetch [--key KEY]                  # topsheet_sources.tsv -> image sets
    swift trim_topsheets.swift ../PowderMeet/Resources/SkisTopsheets.xcassets

Every request checks the host's robots.txt first and waits at least five
seconds (or the host's Crawl-delay) between requests to one host, with an
ordinary browser user agent and nothing else about who is asking. Sites
behind bot protection are skipped, never worked round. Downloads and
listings are cached in ~/Library/Caches/PowderMeet/topsheets-work/, so a
rerun asks nothing twice.

`topsheet_sources.tsv`, beside this file, is the record: one row per
catalog ski with the page its facts came from and the image URL its art
came from. Brand artwork is the brands' copyright, so whether it ships is
settled before an App Store release.

Processing, per image: make the background transparent (a product shot on
white is flood-filled from its border), keep the largest ski when the shot
shows a pair, turn it horizontal with the tip to the left, trim, and scale
to 1280 px long, the size the existing art has (the widest place a ski is
drawn, a full-width pair on Profile, is about 1100 px at 3x).
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import html
import io
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

TOOLS = Path(__file__).resolve().parent
SOURCES = TOOLS / "topsheet_sources.tsv"
CATALOG = TOOLS.parent / "PowderMeet" / "Resources" / "SkisTopsheets.xcassets"
WORK = Path.home() / "Library" / "Caches" / "PowderMeet" / "topsheets-work"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"
)
MIN_DELAY = 5.0
LONG_EDGE = 1280
COLUMNS = ["key", "brand", "model", "category", "waist_mm", "season", "page_url", "image_url"]


# MARK: Polite fetching


class Polite:
    """One client: robots.txt per host, a delay per host, a disk cache."""

    def __init__(self) -> None:
        self.robots: dict[str, urllib.robotparser.RobotFileParser | None] = {}
        self.last: dict[str, float] = {}
        (WORK / "cache").mkdir(parents=True, exist_ok=True)

    def _open(self, url: str) -> bytes:
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "*/*"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()

    def _wait(self, host: str, delay: float) -> None:
        elapsed = time.monotonic() - self.last.get(host, 0)
        if elapsed < delay:
            time.sleep(delay - elapsed)
        self.last[host] = time.monotonic()

    def _rules(self, url: str) -> urllib.robotparser.RobotFileParser | None:
        parts = urllib.parse.urlsplit(url)
        origin = f"{parts.scheme}://{parts.netloc}"
        if origin not in self.robots:
            parser = urllib.robotparser.RobotFileParser()
            try:
                self._wait(parts.netloc, MIN_DELAY)
                parser.parse(self._open(f"{origin}/robots.txt").decode("utf-8", "replace").splitlines())
            except urllib.error.HTTPError as error:
                # No robots.txt (4xx) means no rules; a server error means ask later.
                parser = urllib.robotparser.RobotFileParser()
                parser.parse([] if 400 <= error.code < 500 else ["User-agent: *", "Disallow: /"])
            except urllib.error.URLError:
                parser = None
            self.robots[origin] = parser
        return self.robots[origin]

    def get(self, url: str) -> bytes:
        cached = WORK / "cache" / hashlib.sha256(url.encode()).hexdigest()
        if cached.exists():
            return cached.read_bytes()
        rules = self._rules(url)
        if rules is None:
            raise PermissionError(f"robots.txt unreachable for {url}")
        if not rules.can_fetch(USER_AGENT, url):
            raise PermissionError(f"robots.txt disallows {url}")
        host = urllib.parse.urlsplit(url).netloc
        self._wait(host, max(MIN_DELAY, float(rules.crawl_delay(USER_AGENT) or 0)))
        try:
            data = self._open(url)
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            # Asked to slow down: wait a minute, try once more, then leave it.
            time.sleep(60)
            self.last[host] = time.monotonic()
            try:
                data = self._open(url)
            except urllib.error.HTTPError as again:
                raise PermissionError(f"{host} keeps answering {again.code}; skipped") from again
        cached.write_bytes(data)
        return data


# MARK: Finding skis


def feed(client: Polite, base: str) -> None:
    """A Shopify store's own product feed, skis only."""
    page = 1
    while True:
        data = json.loads(client.get(f"{base.rstrip('/')}/products.json?limit=250&page={page}"))
        products = data.get("products", [])
        if not products:
            break
        for product in products:
            kind = (product.get("product_type") or "").lower()
            tags = " ".join(product.get("tags") or []).lower()
            title = product.get("title", "")
            if "ski" not in kind and "skis" not in tags:
                continue
            if any(word in kind for word in ("boot", "pole", "binding", "bag", "skin", "apparel", "strap")):
                continue
            images = [(image.get("width"), image.get("height"), image.get("src")) for image in product.get("images", [])]
            text = re.sub(r"<[^>]+>", " ", product.get("body_html") or "")
            waist = re.findall(r"(\d{2,3}(?:\.\d)?)\s*mm", text)
            print(f"\n{title} | type={product.get('product_type')} | {base.rstrip('/')}/products/{product.get('handle')}")
            print(f"  updated {product.get('updated_at', '')[:10]} tags: {tags[:160]}")
            print(f"  mm in text: {waist[:12]}")
            for width, height, src in images[:6]:
                print(f"  {width}x{height} {src}")
        page += 1


def product(client: Polite, url: str) -> None:
    """One Shopify product (`<product URL>.json`): title, mm figures, images."""
    item = json.loads(client.get(url.split("?")[0] + ".json"))["product"]
    text = html.unescape(re.sub(r"<[^>]+>", " ", item.get("body_html") or ""))
    print(f"{item.get('title')} | type={item.get('product_type')} | {url}")
    print(f"  mm in text: {re.findall(r'[^.]{0,30}?(\d{2,3}(?:\.\d)?)\s*mm', text)[:12]}")
    for option in item.get("options", []):
        print(f"  {option.get('name')}: {option.get('values')}")
    for image in item.get("images", [])[:8]:
        print(f"  {image.get('width')}x{image.get('height')} {image.get('src')}")


def page(client: Polite, url: str) -> None:
    text = client.get(url).decode("utf-8", "replace")
    title = re.search(r"<title[^>]*>(.*?)</title>", text, re.S)
    print("title:", html.unescape(title.group(1).strip()) if title else "-")
    for match in re.finditer(r'<meta[^>]+property="og:image(?::secure_url)?"[^>]+content="([^"]+)"', text):
        print("og:image:", html.unescape(match.group(1)))
    plain = html.unescape(re.sub(r"<[^>]+>", " ", text))
    for match in sorted(set(re.findall(r"[^.]{0,60}\b\d{2,3}\s*mm[^.]{0,40}", plain)))[:15]:
        print("mm:", " ".join(match.split()))
    for match in sorted(set(re.findall(r"https://[^\"' ]+\.(?:png|jpg|jpeg|webp)", text)))[:40]:
        print("img:", match)


def sitemap(client: Polite, url: str, pattern: str | None) -> None:
    text = client.get(url).decode("utf-8", "replace")
    for location in re.findall(r"<loc>([^<]+)</loc>", text):
        if pattern is None or re.search(pattern, location, re.I):
            print(location)


# MARK: Processing


def cut_out(image: Image.Image) -> Image.Image:
    """RGBA with the background transparent. A shot that already has alpha
    keeps it; one on a light, flat background loses everything of that
    colour that touches the border."""
    rgba = image.convert("RGBA")
    pixels = np.asarray(rgba).astype(np.int16)
    if (pixels[..., 3] < 250).mean() > 0.05:
        return rgba
    rgb = pixels[..., :3]
    border = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    background = np.median(border, axis=0)
    close = np.abs(rgb - background).max(axis=-1) < 18
    # Flood fill from the border through background-coloured pixels.
    from collections import deque

    height, width = close.shape
    seen = np.zeros_like(close)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        for y in (0, height - 1):
            if close[y, x] and not seen[y, x]:
                seen[y, x] = True
                queue.append((y, x))
    for y in range(height):
        for x in (0, width - 1):
            if close[y, x] and not seen[y, x]:
                seen[y, x] = True
                queue.append((y, x))
    while queue:
        y, x = queue.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < height and 0 <= nx < width and close[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                queue.append((ny, nx))
    alpha = np.where(seen, 0, 255).astype(np.uint8)
    # Soften the cut by a pixel so the edge is not jagged.
    alpha_image = Image.fromarray(alpha, "L").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    rgba.putalpha(alpha_image)
    return rgba


def components(alpha: np.ndarray) -> list[tuple[int, int, int, int, int]]:
    """Bounding boxes (x0, y0, x1, y1, area) of the opaque blobs, largest first,
    found on a reduced copy (a pair of skis is two blobs)."""
    scale = max(1, max(alpha.shape) // 400)
    small = alpha[::scale, ::scale] > 64
    height, width = small.shape
    labels = np.zeros(small.shape, dtype=np.int32)
    boxes = []
    current = 0
    for y0 in range(height):
        for x0 in range(width):
            if not small[y0, x0] or labels[y0, x0]:
                continue
            current += 1
            stack = [(y0, x0)]
            labels[y0, x0] = current
            xs, ys = [], []
            while stack:
                y, x = stack.pop()
                xs.append(x)
                ys.append(y)
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < height and 0 <= nx < width and small[ny, nx] and not labels[ny, nx]:
                        labels[ny, nx] = current
                        stack.append((ny, nx))
            boxes.append((min(xs) * scale, min(ys) * scale, (max(xs) + 1) * scale, (max(ys) + 1) * scale, len(xs)))
    return sorted(boxes, key=lambda box: -box[4])


def process(raw: bytes, flip: bool) -> Image.Image:
    image = cut_out(Image.open(io.BytesIO(raw)))
    alpha = np.asarray(image)[..., 3]
    blobs = components(alpha)
    if not blobs:
        raise ValueError("nothing opaque in the image")
    x0, y0, x1, y1, _ = blobs[0]
    pad = 4
    image = image.crop((max(0, x0 - pad), max(0, y0 - pad), min(image.width, x1 + pad), min(image.height, y1 + pad)))
    # Clear whatever of a second ski reaches into the box.
    alpha = np.asarray(image)[..., 3].copy()
    inner = components(alpha)
    if len(inner) > 1:
        keep = inner[0]
        mask = np.zeros_like(alpha)
        mask[keep[1]:keep[3], keep[0]:keep[2]] = 1
        rgba = np.asarray(image).copy()
        rgba[..., 3] = alpha * mask
        image = Image.fromarray(rgba, "RGBA")
    if image.height > image.width:
        # Upright product shot, tip at the top: turn it so the tip is on the left.
        image = image.rotate(90, expand=True)
    if flip:
        image = image.transpose(Image.FLIP_LEFT_RIGHT)
    bbox = image.getchannel("A").point(lambda value: 255 if value > 16 else 0).getbbox()
    if bbox:
        image = image.crop(bbox)
    if image.width / image.height < 9:
        # A pair whose skis touch reads as one blob: cut along the emptiest
        # row in the middle and keep the larger ski.
        coverage = (np.asarray(image)[..., 3] > 64).sum(axis=1)
        third = image.height // 3
        cut = third + int(np.argmin(coverage[third:image.height - third]))
        if coverage[cut] < 0.6 * coverage.max():
            top, bottom = image.crop((0, 0, image.width, cut)), image.crop((0, cut, image.width, image.height))
            image = top if coverage[:cut].sum() >= coverage[cut:].sum() else bottom
            bbox = image.getchannel("A").point(lambda value: 255 if value > 16 else 0).getbbox()
            if bbox:
                image = image.crop(bbox)
    ratio = image.width / image.height
    if not 5 <= ratio <= 25:
        raise ValueError(f"not one ski: {image.width}x{image.height}")
    if image.width > LONG_EDGE:
        image = image.resize((LONG_EDGE, round(LONG_EDGE / ratio)), Image.LANCZOS)
    return image


def write_set(key: str, image: Image.Image) -> None:
    folder = CATALOG / f"{key}.imageset"
    folder.mkdir(exist_ok=True)
    image.save(folder / f"{key}.png", optimize=True)
    contents = {
        "images": [{"idiom": "universal", "filename": f"{key}.png", "scale": "1x"}],
        "info": {"author": "xcode", "version": 1},
    }
    (folder / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def read_sources() -> list[dict[str, str]]:
    with SOURCES.open(newline="") as handle:
        rows = [row for row in csv.DictReader((line for line in handle if not line.startswith("#")), delimiter="\t")]
    return rows


def fetch(client: Polite, only: str | None, flips: set[str]) -> None:
    preview = WORK / "processed"
    preview.mkdir(parents=True, exist_ok=True)
    for row in read_sources():
        key = row["key"]
        if only and key != only:
            continue
        if not row.get("image_url"):
            continue
        try:
            image = process(client.get(row["image_url"]), flip=key in flips)
        except (PermissionError, ValueError, OSError, urllib.error.URLError) as error:
            print(f"{key}: SKIPPED {error}")
            continue
        image.save(preview / f"{key}.png")
        write_set(key, image)
        print(f"{key}: {image.width}x{image.height}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("feed").add_argument("base")
    commands.add_parser("page").add_argument("url")
    commands.add_parser("product").add_argument("url")
    site = commands.add_parser("sitemap")
    site.add_argument("url")
    site.add_argument("--grep")
    get = commands.add_parser("fetch")
    get.add_argument("--key")
    get.add_argument("--flip", action="append", default=[], help="a key whose shot has the tip on the right")
    args = parser.parse_args()
    client = Polite()
    try:
        if args.command == "feed":
            feed(client, args.base)
        elif args.command == "page":
            page(client, args.url)
        elif args.command == "product":
            product(client, args.url)
        elif args.command == "sitemap":
            sitemap(client, args.url, args.grep)
        else:
            fetch(client, args.key, set(args.flip))
    except (PermissionError, urllib.error.URLError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
