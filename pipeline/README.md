# PowderMeet resort pipeline

Builds a resort bundle from OpenStreetMap, OpenSkiMap and the resort's official
lists, for every resort in `resorts.yaml`, with nobody reviewing a resort by hand.
The contract is `specs/05-PIPELINE.md`; the bundle format is `specs/02-DOMAIN.md`
section 2.

```
extract ─▶ reconcile ─▶ build ─▶ validate ─▶ publish
```

## Running it

Keep the virtual environment and the stage outputs out of iCloud Drive:

```bash
export UV_PROJECT_ENVIRONMENT=~/Library/Caches/PowderMeet/pipeline-venv
export PM_PIPELINE_WORKDIR=~/Library/Caches/PowderMeet/pipeline-work
```

```bash
uv run pm-pipeline extract whistler-blackcomb
uv run pm-pipeline reconcile whistler-blackcomb --extract <extract_id>
uv run pm-pipeline build whistler-blackcomb --manifest v<N> --extract <extract_id>
uv run pm-pipeline validate <bundle_id>
uv run pm-pipeline publish whistler-blackcomb --bundle <bundle_id>
```

`<N>` is the manifest version `reconcile` wrote (`manifest/<resort_id>/v<N>.json`).

- `extract` is the only stage that uses the network. Its first run downloads
  OpenSkiMap's two world files (290 MB) into the work directory's cache, where they
  are reused for a week; after that a resort takes under a minute and about 120 MB
  of memory. `--extract` and `--manifest` also accept a file path. A busy Overpass
  (HTTP 502, dropped connections) is retried for up to about 13 minutes;
  `PM_OVERPASS_URL` points it at other instances.
- `extract <resort_id> --official-only` fetches just the official lift and trail
  lists again and freezes them with the latest extract's map data. Epic pages fill
  in their lifts as each resort opens, so this is how a resort picks up the names
  it needs for live status. A list that cannot be fetched is replaced by the newest
  one an earlier extract holds.
- `extract <resort_id> --openskimap-only` reads OpenSkiMap again for the latest
  extract's whole map box and keeps everything else, so ways past the catalog box
  are checked against the ski area they belong to. `build-all --reuse-extracts`
  does this by itself for any extract that needs it.
- `validate` writes `report/<resort_id>/<bundle_id>.md` and a `.geojson` preview
  into the work directory, and exits 2 when the bundle is not publishable.
- `publish` needs `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`. It writes the
  resort's row in `resorts`, the bundle, and a small `.status.json` beside it for
  the status worker. The server's bundle row gets a manifest number above every
  bundle published for the resort before, so a fresh work directory (whose
  manifests start again at v1) never records a lower one; the bundle itself keeps
  its local number.

## Every resort at once

```bash
uv run pm-pipeline build-all --only vail,stowe,zermatt
```

Without `--only` it runs the whole catalog, one resort at a time; `--shard 0/8`
runs an eighth of it. A resort that fails is recorded and the batch carries on.
The result is `report/summary.md` and `summary.json` in the work directory: per
resort, pass or fail, the validation numbers and what blocks it.
`--reuse-extracts` rebuilds from the extracts already frozen there, which is the
quick way to see what a pipeline change does. With `--only` the result goes to
`report/summary-only.md` and `.json`, leaving the whole-catalog summary alone. The `build-all` workflow does the
same on GitHub in eight shards; it is dispatch-only because it costs minutes.

## Correcting one resort

No resort needs a decisions file. When the sources are wrong about a mountain:

1. Read its report (`report/<resort_id>/<bundle_id>.md`) and open the `.geojson`
   preview (geojson.io works) to see the flagged edges.
2. Add `decisions/<resort_id>.yaml`; the keys are documented at the top of
   `powdermeet_pipeline/reconcile/decisions.py`.
3. Run reconcile, build and validate again.

## Fixture

`fixtures/whistler-blackcomb/` holds a frozen extract, its manifest, the expected
SHAs and the report. After changing the decisions file or the pipeline, refresh it
and the bundle the Swift tests read (`packages/MountainCore/Tests/Fixtures/`):

```bash
uv run pm-pipeline fixture whistler-blackcomb
```

## Tests

```bash
uv run pytest
```

Determinism, the reference reconcile cases, and each validation threshold on a small
synthetic mountain (`tests/synthetic.py`).
