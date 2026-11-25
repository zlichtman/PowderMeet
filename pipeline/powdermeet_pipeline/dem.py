"""Elevation from AWS Terrarium tiles (keyless), fetched by tile into a local cache
and sampled bilinearly. No per-coordinate API calls.

Terrarium encodes meters as `R * 256 + G + B / 256 - 32768` in 256 px PNG tiles.
"""

from __future__ import annotations

import http.client
import io
import math
import os
import time
from pathlib import Path
from urllib.request import Request, urlopen

TERRARIUM_URL = "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png"
USER_AGENT = "powdermeet-pipeline/1.0 (+https://powdermeet.app)"
TILE_SIZE = 256


class TerrariumDEM:
    def __init__(self, cache_dir: Path, zoom: int = 14, fetch=None):
        self.cache_dir = Path(cache_dir) / "terrarium" / str(zoom)
        self.zoom = zoom
        self._fetch = fetch or _http_get
        self._tiles: dict[tuple[int, int], bytes] = {}

    def sample(self, lon: float, lat: float) -> float:
        """Bilinear elevation in meters. Pixel centers sit at half-pixel offsets."""
        scale = (1 << self.zoom) * TILE_SIZE
        px = (lon + 180.0) / 360.0 * scale - 0.5
        lat_rad = math.radians(lat)
        py = (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * scale - 0.5
        x0, y0 = math.floor(px), math.floor(py)
        fx, fy = px - x0, py - y0
        top = self._pixel(x0, y0) * (1 - fx) + self._pixel(x0 + 1, y0) * fx
        bottom = self._pixel(x0, y0 + 1) * (1 - fx) + self._pixel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy

    @property
    def tile_count(self) -> int:
        return len(self._tiles)

    def _pixel(self, gx: int, gy: int) -> float:
        limit = (1 << self.zoom) * TILE_SIZE
        gx %= limit
        gy = min(max(gy, 0), limit - 1)
        rgb = self._tile(gx // TILE_SIZE, gy // TILE_SIZE)
        offset = ((gy % TILE_SIZE) * TILE_SIZE + gx % TILE_SIZE) * 3
        return rgb[offset] * 256.0 + rgb[offset + 1] + rgb[offset + 2] / 256.0 - 32768.0

    def _tile(self, x: int, y: int) -> bytes:
        key = (x, y)
        rgb = self._tiles.get(key)
        if rgb is None:
            path = self.cache_dir / str(x) / f"{y}.png"
            if path.exists():
                rgb = _decode_rgb(path.read_bytes())
            else:
                png = self._fetch(TERRARIUM_URL.format(z=self.zoom, x=x, y=y))
                # Decoded before it is cached, and moved into place whole: a
                # truncated download or a killed run never leaves a tile that
                # fails every later extract.
                rgb = _decode_rgb(png)
                path.parent.mkdir(parents=True, exist_ok=True)
                partial = path.with_name(f".{path.name}.{os.getpid()}.part")
                partial.write_bytes(png)
                partial.replace(path)
            self._tiles[key] = rgb
        return rgb


def _decode_rgb(png: bytes) -> bytes:
    from PIL import Image

    image = Image.open(io.BytesIO(png)).convert("RGB")
    if image.size != (TILE_SIZE, TILE_SIZE):
        raise ValueError(f"unexpected DEM tile size {image.size}")
    return image.tobytes()


def _http_get(url: str, attempts: int = 4) -> bytes:
    last: Exception | None = None
    for attempt in range(attempts):
        try:
            with urlopen(Request(url, headers={"User-Agent": USER_AGENT}), timeout=60) as response:
                return response.read()
        # A reset or a short read mid-body is as transient as a timeout.
        except (OSError, http.client.HTTPException) as error:
            last = error
            time.sleep(1.5 * (attempt + 1))
    raise RuntimeError(f"DEM tile request failed: {url}: {last}")
