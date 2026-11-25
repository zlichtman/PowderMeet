"""Canonical bundle bytes: JSON with sorted keys and fixed float formatting, in a
gzip container whose header never varies. `bundle_id` is the SHA-256 of those bytes
(specs/02-DOMAIN.md section 1, invariant I-17).
"""

from __future__ import annotations

import hashlib
import json
import math
import struct
import zlib


class Fixed:
    """A float written with a fixed number of decimals."""

    __slots__ = ("value", "places")

    def __init__(self, value: float, places: int):
        if not math.isfinite(value):
            raise ValueError(f"non-finite number in bundle: {value!r}")
        self.value = float(value)
        self.places = places

    def __float__(self) -> float:
        return round(self.value, self.places)

    def __repr__(self) -> str:
        return _format(self)


def coord(value: float) -> Fixed:
    """Longitude or latitude: 7 decimals."""
    return Fixed(value, 7)


def meters(value: float) -> Fixed:
    """Meters, degrees and seconds: 1 decimal."""
    return Fixed(value, 1)


def share(value: float) -> Fixed:
    """Ratios in the integrity block: 4 decimals."""
    return Fixed(value, 4)


def score(value: float) -> Fixed:
    """Confidence and quality: 2 decimals."""
    return Fixed(value, 2)


def _format(number: Fixed) -> str:
    text = f"{number.value:.{number.places}f}"
    if text.startswith("-") and float(text) == 0.0:
        text = text[1:]
    return text


def dumps(value) -> str:
    """Serialize with sorted keys and no whitespace. Bare floats are refused so every
    number in a bundle has a declared precision."""
    out: list[str] = []
    _write(value, out)
    return "".join(out)


def _write(value, out: list[str]) -> None:
    if value is None:
        out.append("null")
    elif value is True:
        out.append("true")
    elif value is False:
        out.append("false")
    elif isinstance(value, Fixed):
        out.append(_format(value))
    elif isinstance(value, int):
        out.append(str(value))
    elif isinstance(value, float):
        raise TypeError(f"bare float {value!r}: wrap it in canonical.Fixed")
    elif isinstance(value, str):
        out.append(json.dumps(value, ensure_ascii=False))
    elif isinstance(value, dict):
        out.append("{")
        for index, key in enumerate(sorted(value)):
            if not isinstance(key, str):
                raise TypeError(f"non-string key {key!r}")
            if index:
                out.append(",")
            out.append(json.dumps(key, ensure_ascii=False))
            out.append(":")
            _write(value[key], out)
        out.append("}")
    elif isinstance(value, (list, tuple)):
        out.append("[")
        for index, item in enumerate(value):
            if index:
                out.append(",")
            _write(item, out)
        out.append("]")
    else:
        raise TypeError(f"cannot serialize {type(value).__name__}")


# ID1 ID2, deflate, no flags, mtime 0, XFL = best compression, OS = unknown.
_GZIP_HEADER = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff"


def gzip_bytes(data: bytes) -> bytes:
    """RFC 1952 container with no name and mtime 0. The header is written here
    rather than by zlib, which stamps the build platform into the OS byte."""
    deflater = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = deflater.compress(data) + deflater.flush()
    trailer = struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)
    return _GZIP_HEADER + body + trailer


def gunzip_bytes(data: bytes) -> bytes:
    return zlib.decompress(data, 47)


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def encode_bundle(document: dict) -> tuple[bytes, str]:
    """Return the stored bytes and their `bundle_id`."""
    stored = gzip_bytes(dumps(document).encode("utf-8"))
    return stored, sha256_hex(stored)


_PLACES = {
    "lon": 7, "lat": 7,
    "ele_m": 1, "length_m": 1, "vertical_m": 1, "grade_max_deg": 1, "aspect_deg": 1,
    "confidence": 2, "quality": 2,
    "lift_tops_reaching_base": 4, "rendezvous_reachable_from_all_lift_tops": 4,
    "orphan_edge_share": 4, "unnamed_run_share": 4,
}


def typed(value, key: str | None = None):
    """Give every number in a plain bundle document its declared precision, by the
    name of the field it sits in."""
    if isinstance(value, dict):
        return {k: typed(v, k) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        if key in ("bbox", "center"):
            return [coord(v) for v in value]
        if key == "geometry":
            return [[coord(p[0]), coord(p[1]), meters(p[2])] for p in value]
        return [typed(v) for v in value]
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return value
    if key in _PLACES:
        return Fixed(float(value), _PLACES[key])
    if isinstance(value, float):
        raise TypeError(f"no declared precision for float field {key!r}")
    return value
