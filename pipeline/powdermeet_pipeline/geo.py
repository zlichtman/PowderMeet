"""Spherical geometry. Points are (lon, lat) in degrees.

The radius and formulas match `MountainCore.Geo`, so a length the pipeline writes
is the length the client recomputes when it checks the bundle.
"""

from __future__ import annotations

import math

EARTH_RADIUS_M = 6_371_000.0


def haversine_m(a, b) -> float:
    lat1, lat2 = math.radians(a[1]), math.radians(b[1])
    d_lat = lat2 - lat1
    d_lon = math.radians(b[0] - a[0])
    h = math.sin(d_lat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(d_lon / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(min(1.0, max(0.0, h))))


def bearing_deg(a, b) -> float:
    """Initial bearing from a to b, clockwise from north, 0 <= bearing < 360."""
    lat1, lat2 = math.radians(a[1]), math.radians(b[1])
    d_lon = math.radians(b[0] - a[0])
    y = math.sin(d_lon) * math.cos(lat2)
    x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(d_lon)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def length_m(line) -> float:
    """Horizontal length of a polyline."""
    return sum(haversine_m(line[i - 1], line[i]) for i in range(1, len(line)))
