"""Geometry override authoring tool — minimal Flask + Leaflet web app.

Workflow:
  1. Operator runs `python -m canonical_ingest.geometry_tool <resort_id>`
  2. Server boots on http://localhost:8765, opens browser
  3. Page shows the draft manifest's trails + lifts in a sidebar
  4. Click a trail/lift → map shows all candidate geometries:
       - existing canonical_geometry (if any prior override)
       - Skimap geometry (from cached fetch)
       - OpenSkiMap geometry (from cached fetch)
       - Overpass geometry (from cached fetch)
  5. Operator picks ONE candidate via radio button OR draws a new trace
  6. Click Save → POST /override → write canonical_geometry_override
  7. Move to the next item.

Server is single-tenant, single-user — no auth, listens on localhost
only, refuses non-loopback connections. Designed for the operator
workstation, never for production deployment.

Dependencies:
  pip install flask
"""

from __future__ import annotations
import json
import os
import sys
import webbrowser
from pathlib import Path
from typing import Optional, Dict, Any, List
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")

ROOT = Path(__file__).resolve().parent
DRAFTS_DIR = ROOT / "drafts"
FIXTURES_DIR = ROOT / "fixtures"


def main(resort_id: str, port: int = 8765) -> int:
    try:
        from flask import Flask, jsonify, request, send_from_string  # type: ignore
    except ImportError:
        print("flask is required: pip install flask", file=sys.stderr)
        return 2

    draft_path = DRAFTS_DIR / f"{resort_id}.json"
    if not draft_path.exists():
        print(f"no draft for {resort_id} — run `ingest` first", file=sys.stderr)
        return 3
    draft = json.loads(draft_path.read_text())

    from flask import Flask, jsonify, request  # noqa: E402  (deferred import)

    app = Flask(__name__)

    @app.route("/")
    def index():
        return _INDEX_HTML.replace("__RESORT_ID__", resort_id)

    @app.route("/api/draft")
    def api_draft():
        return jsonify(draft)

    @app.route("/api/candidates")
    def api_candidates():
        kind = request.args.get("kind", "trail")
        name = request.args.get("name", "")
        return jsonify(_collect_candidates(resort_id, kind, name))

    @app.route("/api/override", methods=["POST"])
    def api_override():
        body = request.get_json() or {}
        target_kind = body.get("target_kind")
        target_name = body.get("target_name")
        geometry = body.get("geometry")
        notes = body.get("notes") or None
        manifest_version = body.get("manifest_version") or 1
        if target_kind not in ("trail", "lift") or not target_name or not geometry:
            return jsonify({"error": "missing required fields"}), 400
        try:
            _write_override(
                resort_id=resort_id,
                target_kind=target_kind,
                target_name=target_name,
                geometry=geometry,
                notes=notes,
                manifest_version_introduced=int(manifest_version),
            )
        except RuntimeError as err:
            return jsonify({"error": str(err)}), 500
        return jsonify({"ok": True})

    print(f"geometry tool serving on http://localhost:{port}/")
    webbrowser.open(f"http://localhost:{port}/")
    app.run(host="127.0.0.1", port=port, debug=False)
    return 0


def _collect_candidates(resort_id: str, kind: str, name: str) -> Dict[str, Any]:
    """Return all known candidate geometries for this trail/lift name
    plus a few mini-stats to help the operator pick.
    """
    name_norm = name.lower().strip()
    out: Dict[str, Any] = {
        "name": name,
        "kind": kind,
        "candidates": [],
    }

    # Skimap fixture
    skimap_dir = FIXTURES_DIR / "skimap"
    for path in skimap_dir.glob("*.json"):
        if path.name == "_registry.json":
            continue
        try:
            area = json.loads(path.read_text())
        except (OSError, ValueError):
            continue
        for entry in (area.get("pistes" if kind == "trail" else "lifts") or []):
            if (entry.get("name") or "").lower().strip() == name_norm:
                geom = entry.get("geometry")
                if geom and geom.get("type") == "LineString":
                    out["candidates"].append({
                        "source": "skimap",
                        "geometry": geom,
                    })

    # OpenSkiMap fixture
    osm_path = FIXTURES_DIR / "openskimap" / f"{resort_id}-{'runs' if kind == 'trail' else 'lifts'}.json"
    if osm_path.exists():
        try:
            data = json.loads(osm_path.read_text())
            for feat in data.get("features") or []:
                if (feat.get("properties", {}).get("name") or "").lower().strip() == name_norm:
                    if feat.get("geometry", {}).get("type") == "LineString":
                        out["candidates"].append({
                            "source": "openskimap",
                            "geometry": feat["geometry"],
                        })
        except (OSError, ValueError):
            pass

    # Overpass fixture
    overpass_path = FIXTURES_DIR / "overpass" / f"{resort_id}.json"
    if overpass_path.exists():
        try:
            data = json.loads(overpass_path.read_text())
            nodes = {
                int(n["id"]): (float(n["lon"]), float(n["lat"]))
                for n in data.get("elements", [])
                if n.get("type") == "node"
            }
            for el in data.get("elements", []):
                if el.get("type") != "way":
                    continue
                tags = el.get("tags") or {}
                if kind == "trail" and tags.get("piste:type") != "downhill":
                    continue
                if kind == "lift" and not tags.get("aerialway"):
                    continue
                if (tags.get("name") or "").lower().strip() != name_norm:
                    continue
                coords = [nodes.get(int(r)) for r in (el.get("nodes") or [])]
                coords = [c for c in coords if c is not None]
                if coords:
                    out["candidates"].append({
                        "source": "overpass",
                        "geometry": {
                            "type": "LineString",
                            "coordinates": coords,
                        },
                    })
        except (OSError, ValueError):
            pass

    # Existing override (if any)
    if SUPABASE_URL and SUPABASE_SERVICE_KEY:
        existing = _fetch_existing_override(resort_id, kind, name)
        if existing:
            out["candidates"].append({
                "source": "existing_override",
                "geometry": existing,
            })

    return out


def _fetch_existing_override(resort_id: str, kind: str, name: str) -> Optional[Dict[str, Any]]:
    url = (
        f"{SUPABASE_URL}/rest/v1/rpc/latest_geometry_overrides"
    )
    payload = {"p_resort_id": resort_id}
    body = json.dumps(payload).encode()
    req = Request(url, data=body, headers={
        "Content-Type": "application/json",
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
    })
    try:
        with urlopen(req, timeout=15) as resp:
            rows = json.loads(resp.read())
    except (URLError, HTTPError, ValueError):
        return None
    for row in rows:
        if row.get("target_kind") == kind and row.get("target_name") == name:
            geom_text = row.get("geometry")
            if geom_text:
                try:
                    return json.loads(geom_text)
                except ValueError:
                    return None
    return None


def _write_override(
    *,
    resort_id: str,
    target_kind: str,
    target_name: str,
    geometry: Dict[str, Any],
    notes: Optional[str],
    manifest_version_introduced: int,
) -> None:
    if not (SUPABASE_URL and SUPABASE_SERVICE_KEY):
        raise RuntimeError("SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY env vars required")
    url = f"{SUPABASE_URL}/rest/v1/canonical_geometry_override"
    payload = [{
        "resort_id": resort_id,
        "target_kind": target_kind,
        "target_name": target_name,
        "geometry": geometry,
        "notes": notes,
        "manifest_version_introduced": manifest_version_introduced,
    }]
    body = json.dumps(payload).encode()
    req = Request(url, data=body, headers={
        "Content-Type": "application/json",
        "Prefer": "return=minimal",
        "apikey": SUPABASE_SERVICE_KEY,
        "Authorization": f"Bearer {SUPABASE_SERVICE_KEY}",
    })
    try:
        with urlopen(req, timeout=30) as resp:
            resp.read()
    except HTTPError as err:
        msg = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"override insert failed: HTTP {err.code} — {msg}") from err
    except URLError as err:
        raise RuntimeError(f"override insert failed: {err}") from err


_INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Geometry override — __RESORT_ID__</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<style>
  body { margin: 0; font-family: -apple-system, system-ui, sans-serif; }
  #app { display: flex; height: 100vh; }
  #sidebar { width: 360px; overflow-y: auto; border-right: 1px solid #ddd; padding: 12px; box-sizing: border-box; }
  #map { flex: 1; }
  h1 { font-size: 14px; text-transform: uppercase; letter-spacing: 1px; margin: 0 0 12px; }
  .group { margin-bottom: 16px; }
  .group h2 { font-size: 11px; text-transform: uppercase; letter-spacing: 1px; color: #666; margin: 0 0 6px; }
  .row { padding: 6px 8px; cursor: pointer; border-radius: 4px; font-size: 13px; }
  .row:hover { background: #f3f3f3; }
  .row.active { background: #007aff; color: white; }
  .row.has-override::after { content: "✓"; float: right; color: #34c759; }
  #candidate-panel { padding: 12px; border-top: 1px solid #ddd; }
  .candidate { padding: 6px; cursor: pointer; border-radius: 4px; font-size: 12px; }
  .candidate:hover { background: #f3f3f3; }
  .candidate.active { background: #007aff; color: white; }
  button { margin-top: 8px; padding: 6px 12px; font-size: 13px; cursor: pointer; }
</style>
</head>
<body>
<div id="app">
  <div id="sidebar">
    <h1>__RESORT_ID__ overrides</h1>
    <div id="trail-list"></div>
    <div id="lift-list"></div>
    <div id="candidate-panel" style="display:none">
      <h2 id="candidate-title"></h2>
      <div id="candidates"></div>
      <button id="save-btn" disabled>Save override</button>
    </div>
  </div>
  <div id="map"></div>
</div>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const map = L.map('map').setView([39.6, -106.5], 12);
L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18 }).addTo(map);
let activeLayer = null;
let activeRow = null;
let activeCandidate = null;

async function load() {
  const draft = await (await fetch('/api/draft')).json();
  document.getElementById('trail-list').innerHTML = renderGroup('trails', draft.trail_rows || []);
  document.getElementById('lift-list').innerHTML = renderGroup('lifts', draft.lift_rows || []);
}

function renderGroup(label, rows) {
  if (!rows.length) return '';
  return `<div class="group"><h2>${label} (${rows.length})</h2>` +
    rows.map(r => `<div class="row" data-kind="${r.kind}" data-name="${escapeHtml(r.name)}">${escapeHtml(r.name)}</div>`).join('') +
    `</div>`;
}

function escapeHtml(s) { return s.replace(/[&<>"']/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])); }

document.addEventListener('click', async (e) => {
  if (e.target.classList.contains('row')) {
    if (activeRow) activeRow.classList.remove('active');
    activeRow = e.target;
    activeRow.classList.add('active');
    const kind = activeRow.dataset.kind;
    const name = activeRow.dataset.name;
    const data = await (await fetch(`/api/candidates?kind=${kind}&name=${encodeURIComponent(name)}`)).json();
    showCandidates(data);
  }
  if (e.target.classList.contains('candidate')) {
    if (activeCandidate) activeCandidate.classList.remove('active');
    activeCandidate = e.target;
    activeCandidate.classList.add('active');
    const idx = parseInt(activeCandidate.dataset.idx);
    drawCandidate(currentCandidates[idx].geometry);
    document.getElementById('save-btn').disabled = false;
  }
});

let currentCandidates = [];
function showCandidates(data) {
  currentCandidates = data.candidates || [];
  document.getElementById('candidate-panel').style.display = 'block';
  document.getElementById('candidate-title').textContent = `${data.kind}: ${data.name}`;
  document.getElementById('candidates').innerHTML = currentCandidates.length
    ? currentCandidates.map((c, i) => `<div class="candidate" data-idx="${i}">${c.source} (${c.geometry.coordinates?.length || 0} pts)</div>`).join('')
    : '<em>no candidates — draw manually on the map</em>';
  if (currentCandidates.length) drawCandidate(currentCandidates[0].geometry);
}

function drawCandidate(geom) {
  if (activeLayer) map.removeLayer(activeLayer);
  if (geom?.type === 'LineString') {
    const latlngs = geom.coordinates.map(c => [c[1], c[0]]);
    activeLayer = L.polyline(latlngs, { color: 'red', weight: 4 }).addTo(map);
    map.fitBounds(activeLayer.getBounds(), { maxZoom: 16 });
  }
}

document.getElementById('save-btn').addEventListener('click', async () => {
  if (!activeCandidate || !activeRow) return;
  const idx = parseInt(activeCandidate.dataset.idx);
  const candidate = currentCandidates[idx];
  const body = {
    target_kind: activeRow.dataset.kind,
    target_name: activeRow.dataset.name,
    geometry: candidate.geometry,
    manifest_version: 1,
  };
  const res = await fetch('/api/override', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (res.ok) {
    activeRow.classList.add('has-override');
    document.getElementById('save-btn').disabled = true;
  } else {
    const err = await res.json();
    alert('save failed: ' + (err.error || res.status));
  }
});

load();
</script>
</body>
</html>"""


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: python -m canonical_ingest.geometry_tool <resort_id> [--port N]", file=sys.stderr)
        sys.exit(1)
    rid = sys.argv[1]
    port = 8765
    for arg in sys.argv[2:]:
        if arg.startswith("--port="):
            port = int(arg.split("=", 1)[1])
    sys.exit(main(rid, port))
