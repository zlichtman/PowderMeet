#!/usr/bin/env python3
"""Build missing frozen map snapshots and audit every catalog resort.

Uses the app's public configuration from a built Info.plist. Never stages or
publishes canonical routing data: source inventories still require review.
Signed download URLs and API keys are not included in the saved report.
"""
from __future__ import annotations
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import json
from pathlib import Path
import plistlib
import time
from urllib.request import urlopen

from prewarm_snapshots import CATALOG_PATH, parse_catalog, post_with_retry
from canonical_ingest.sources.overpass import _extract_items

ROOT = Path(__file__).resolve().parent.parent


def audit_source(osm: dict, elevations: dict) -> dict:
    elements = osm.get('elements', [])
    nodes = {e['id'] for e in elements if e.get('type') == 'node'}
    ways = [e for e in elements if e.get('type') == 'way']
    trails = [e for e in ways if e.get('tags', {}).get('piste:type') == 'downhill']
    items = _extract_items(osm)
    lift_items = [x for x in items if x.kind == 'lift']
    trail_items = [x for x in items if x.kind == 'trail']
    unresolved_nodes = sorted({n for w in ways for n in w.get('nodes', []) if n not in nodes})
    return {
        'source_nodes': len(nodes), 'source_ways': len(ways),
        'source_query_version': osm.get('powdermeet_source_query_version'),
        'explicit_connection_ways': sum(w.get('tags', {}).get('piste:type') == 'connection' for w in ways),
        'source_timestamp': osm.get('osm3s', {}).get('timestamp_osm_base'),
        'downhill_ways': len(trails),
        'downhill_area_ways': sum(w.get('tags', {}).get('area') == 'yes' for w in trails),
        'downhill_centerline_ways': sum(w.get('tags', {}).get('area') != 'yes' for w in trails),
        'named_trail_candidates': len(trail_items),
        'named_lift_candidates': len(lift_items),
        'unnamed_downhill_ways': sum(not (w.get('tags', {}).get('name') or w.get('tags', {}).get('piste:name')) for w in trails),
        'downhill_ways_without_difficulty': sum(not w.get('tags', {}).get('piste:difficulty') for w in trails),
        'unresolved_source_node_count': len(unresolved_nodes),
        'elevation_entries': len(elevations),
        'candidate_inventory': [{'kind': i.kind, 'name': i.name, 'osm_way_ids': list(i.osm_way_ids), 'attributes': i.extra} for i in items],
    }


def download_json(url: str) -> dict:
    if not url.startswith('https://'):
        raise ValueError('snapshot download must use HTTPS')
    with urlopen(url, timeout=60) as response:
        data = response.read(50_000_001)
    if len(data) > 50_000_000:
        raise ValueError('snapshot exceeded 50 MB limit')
    result = json.loads(data)
    if not isinstance(result, dict):
        raise ValueError('snapshot must be a JSON object')
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app-plist', type=Path, required=True)
    parser.add_argument('--inventory', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / '_local/resort-rollout')
    parser.add_argument('--build-missing', action='store_true')
    parser.add_argument('--snapshot-date', help='Stage a new immutable snapshot date without changing active pins')
    parser.add_argument('--workers', type=int, choices=(1, 2), default=1)
    parser.add_argument('--resort', action='append')
    args = parser.parse_args()
    if args.snapshot_date:
        try:
            datetime.strptime(args.snapshot_date, '%Y-%m-%d')
        except ValueError:
            parser.error('--snapshot-date must be YYYY-MM-DD')
    config = plistlib.loads(args.app_plist.read_bytes())
    baseline = json.loads(args.inventory.read_text())
    objects = {o['name'] for o in baseline['objects']}
    pins = {p['resort_id']: p['snapshot_date'] for p in baseline.get('pins') or []}
    entries = list(parse_catalog(CATALOG_PATH.read_text()))
    if len(entries) != len({x[0] for x in entries}):
        raise ValueError('duplicate catalog IDs')
    if args.resort:
        unknown = set(args.resort) - {x[0] for x in entries}
        if unknown:
            parser.error(f'unknown resorts: {sorted(unknown)}')
        entries = [x for x in entries if x[0] in args.resort]
    args.output.mkdir(parents=True, exist_ok=True)
    rows = {}
    report_path = args.output / 'coverage.json'
    if report_path.exists():
        rows = json.loads(report_path.read_text()).get('resorts', {})

    def process(entry):
        rid, name, south, west, north, east, catalog_pin = entry
        pin = args.snapshot_date or pins.get(rid, pins.get('__catalog__', catalog_pin))
        result = {'id': rid, 'name': name, 'snapshot_date': pin,
                  'routing_status': 'not_published', 'map_status': 'pending'}
        ready = all(f'{rid}/{kind}-{pin}.json' in objects for kind in ('osm', 'elev'))
        if not ready and not args.build_missing:
            result['map_status'] = 'missing_snapshot'
            return result
        resort_dir = args.output / rid
        resort_dir.mkdir(exist_ok=True)
        try:
            payload = dict(resort_id=rid, south=south, west=west, north=north,
                           east=east, pinned_snapshot_date=pin)
            last_progress = None
            stalled = 0
            for iteration in range(256):
                body = post_with_retry(config['SupabaseURL'], config['SupabaseAnonKey'], payload, max_attempts=2, base_delay=3)
                if body.get('status') == 'ready' or ('osm_url' in body and 'elevation_url' in body):
                    break
                if body.get('status') != 'elevation_pending':
                    raise ValueError(f"unexpected snapshot status: {body.get('status')}")
                progress = body.get('elevation_progress', {})
                current = (progress.get('processed'), progress.get('total'))
                if not all(isinstance(v, int) for v in current) or not 0 <= current[0] <= current[1] or current[1] <= 0:
                    raise ValueError('invalid elevation progress')
                if last_progress and (current[1] != last_progress[1] or current[0] < last_progress[0]):
                    raise ValueError('elevation identity or progress changed')
                stalled = stalled + 1 if current == last_progress else 0
                if stalled >= 3:
                    raise TimeoutError('elevation checkpoint stopped advancing')
                last_progress = current
                print(f"{rid}: elevation {current[0]}/{current[1]}", flush=True)
                payload['continue'] = True
                time.sleep(2)
            else:
                raise TimeoutError('elevation build did not complete in 256 steps')
            if body.get('snapshot_date') != pin:
                raise ValueError('server returned a different snapshot date')
            osm = download_json(body['osm_url'])
            elevations = download_json(body['elevation_url'])
            result.update(audit_source(osm, elevations))
            result['map_status'] = 'snapshot_ready' if result['downhill_ways'] and result['named_lift_candidates'] and not result['unresolved_source_node_count'] else 'source_review_required'
            result['canonical_review_required'] = True
            (resort_dir / 'osm.json').write_text(json.dumps(osm))
            (resort_dir / 'elevation.json').write_text(json.dumps(elevations))
            (resort_dir / 'source-audit.json').write_text(json.dumps(result, indent=2))
        except Exception as exc:
            # Do not save exception strings containing signed URLs or credentials.
            result['map_status'] = 'fetch_failed'
            result['error_type'] = type(exc).__name__
            result['http_status'] = getattr(exc, 'code', None)
        result['checked_at'] = datetime.now(timezone.utc).isoformat()
        return result

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        pending = {pool.submit(process, e): e[0] for e in entries}
        for completed, future in enumerate(as_completed(pending), start=1):
            result = future.result()
            rows[result['id']] = result
            summary = {}
            for row in rows.values():
                summary[row['map_status']] = summary.get(row['map_status'], 0) + 1
            report = {'generated_at': datetime.now(timezone.utc).isoformat(),
                      'meaning': 'Snapshot readiness is not verified rendering or canonical routing readiness.',
                      'summary': summary, 'resorts': dict(sorted(rows.items()))}
            temporary = report_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(report, indent=2))
            temporary.replace(report_path)
            print(f"{result['id']}: {result['map_status']} ({completed}/{len(entries)})", flush=True)
    print(json.dumps(summary), flush=True)
    return 1 if any(r['map_status'] != 'snapshot_ready' for r in rows.values()) else 0


if __name__ == '__main__':
    raise SystemExit(main())
