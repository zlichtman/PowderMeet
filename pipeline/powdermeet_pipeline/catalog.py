"""The resort catalog (`resorts.yaml`) and where each stage keeps its files."""

from __future__ import annotations

import os
import re
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "resorts.yaml"
DECISIONS_DIR = ROOT / "decisions"
FIXTURES_DIR = ROOT / "fixtures"


class PipelineError(RuntimeError):
    """A stage could not produce its output. The message says what to fix."""


def _catalog() -> dict:
    return yaml.safe_load(CATALOG_PATH.read_text())


def resort_ids() -> list[str]:
    return sorted(_catalog()["resorts"])


def resort(resort_id: str) -> dict:
    document = _catalog()
    catalog = document["resorts"]
    if resort_id not in catalog:
        raise PipelineError(f"unknown resort_id {resort_id!r}; add it to {CATALOG_PATH.name}")
    entry = {**(document.get("defaults") or {}), **catalog[resort_id]}
    entry["resort_id"] = resort_id
    min_lon, min_lat, max_lon, max_lat = entry["bbox"]
    if not (-180 <= min_lon < max_lon <= 180 and -90 <= min_lat < max_lat <= 90):
        raise PipelineError(f"invalid bbox for {resort_id}")
    return entry


def workdir() -> Path:
    """Stage outputs and caches. Set PM_PIPELINE_WORKDIR to keep them out of the
    repository folder (for a repository in a synced folder such as iCloud Drive)."""
    return Path(os.environ.get("PM_PIPELINE_WORKDIR") or ROOT / ".work")


def cache_dir() -> Path:
    return workdir() / ".cache"


def file_stem(identifier: str) -> str:
    """Extract ids contain ':' from their ISO time, which artifact stores and some
    file systems refuse. File names drop it; the id inside the file keeps it."""
    return identifier.replace(":", "")


def extract_path(resort_id: str, extract_id: str) -> Path:
    return workdir() / "extract" / resort_id / f"{file_stem(extract_id)}.json"


def manifest_dir(resort_id: str) -> Path:
    return workdir() / "manifest" / resort_id


def bundle_path(resort_id: str, bundle_id: str) -> Path:
    return workdir() / "bundle" / resort_id / f"{bundle_id}.json.gz"


def report_dir(resort_id: str) -> Path:
    return workdir() / "report" / resort_id


def find_bundle(bundle_id: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{64}", bundle_id):
        raise PipelineError("bundle_id must be 64 lowercase hex characters")
    matches = sorted((workdir() / "bundle").glob(f"*/{bundle_id}.json.gz"))
    if not matches:
        raise PipelineError(f"bundle {bundle_id} not found under {workdir() / 'bundle'}")
    return matches[0]
