# PowderMeet

Two skiers, one mountain, one question: *where should we meet?* PowderMeet
routes both friends over the resort's real lift-and-trail graph, runs a
separate solve for each skier under their own ability and terrain limits, and
ranks meeting points by when the last person actually arrives and how long the
other waits. It explains the trade-offs instead of promising simultaneous
arrival.

Screenshots and demo: https://zlichtman.com/open-source#powdermeet

Swift 6 + SwiftUI · Mapbox Maps · Supabase (Postgres + Realtime + Edge Functions)

## What it does

- **Meet in the middle.** Pick a friend and compare practical meeting places.
  Each option shows the arrival range, expected wait, hardest marked terrain,
  and lift count, so the choice is yours.
- **Live on the hill.** Friend locations over Supabase Realtime, turn-by-turn
  descent directions, and automatic rerouting when a lift or run closes.
- **Your real pace.** Import runs from Slopes, GPX, TCX, or FIT. Runs are
  matched to trails with directional evidence and calibrate the solver per ski.
- **Conditions-aware.** Hourly forecast, snow totals, sun exposure, and lift
  queues feed the routing costs continuously rather than at label boundaries.
- **A mountain you can read.** Pitched satellite terrain, difficulty-colored
  trails, closures drawn exactly where they are, and a selectable timeline.

## Resort coverage

159 Epic and Ikon resorts are cataloged with bounding boxes, pass products, and
camera framing. Whistler Blackcomb has a curated overlay and local golden routing
fixtures; the other 158 overlays are stubs. The September 20 backend audit found
no published canonical mountain datasets, including Whistler. Recovered map
snapshots are previews, not evidence of complete or live routing. See
[`RELEASE_READINESS.md`](RELEASE_READINESS.md) for the current release hold.
On-mountain routing has not been field-tested this season.

## Requirements

- iPhone running iOS 17.6 or later (iPhone-only; there is no iPad layout).
- Location access for live presence and navigation; notifications for meet
  requests.

---

## Prerequisites

- **Xcode 16+** (iOS 17.6 SDK).
- **Apple Developer account** for device signing (a free account is fine for
  simulator-only use).
- **Mapbox account** — free tier is enough for development.
- **Supabase project** — free tier works. You'll need `SUPABASE_URL` and the
  `anon` key.
- **Node + Supabase CLI** — only if you want to deploy the Edge Function
  (`supabase` via `brew install supabase/tap/supabase`).

---

## Setup

### 1. Clone + open

```bash
git clone https://github.com/zlichtman/PowderMeet.git
cd PowderMeet
open PowderMeet.xcodeproj
```

The first open will fetch Swift Package dependencies (`MapboxMaps`, `Supabase`).
This takes a minute on a cold cache.

### 2. Review `Secrets.xcconfig`

The canonical repository includes the current client-public
configuration. For a different Supabase or Mapbox project, replace it from the
template and fill in:

```bash
cp Secrets.xcconfig.example Secrets.xcconfig
```

```
SUPABASE_URL = https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOi...   # Supabase → Settings → API → anon public
MAPBOX_ACCESS_TOKEN = pk.ey...       # Mapbox → Account → Access Tokens
```

`Secrets.xcconfig` is intentionally committed because these three values are
embedded in every client build and are public by design. Never put a Supabase
service-role key, Mapbox secret/download token, APNs key, or other server
credential in this file. The client values are wired into the build via
`Info.plist` substitutions:

| Key in Info.plist | Source |
|---|---|
| `MBXAccessToken` | `MAPBOX_ACCESS_TOKEN` |
| `SupabaseURL` | `SUPABASE_URL` |
| `SupabaseAnonKey` | `SUPABASE_ANON_KEY` |

### 3. Mapbox token scopes

The default public token scopes are sufficient. If you rotate to a scoped
token, make sure it includes:

- `styles:read`
- `fonts:read`
- `datasets:read`
- `vision:read`

### 4. Supabase schema

The complete database is reproducible from the 73 ordered migrations in
`supabase/migrations/`; no Studio-created tables, policies, functions, triggers,
publications, or storage buckets are required. For a fresh linked project:

```bash
supabase db push --dry-run
supabase db push
```

The existing PowderMeet production project predates the reconstructed
`20260301000000_foundation_schema.sql` history entry. Its first approved rollout
must use `supabase db push --include-all` so that guarded, idempotent foundation
runs before the newer pending migrations. Always inspect the corresponding
`--dry-run` first. Do not paste individual migrations into Studio: that would
make migration history non-reproducible again.

To prove the whole chain locally (Docker-compatible runtime required):

```bash
supabase start
supabase db reset --local --no-seed
supabase test db supabase/tests/database
```

**Tables**

- `profiles` — user profile mirror. PK = `auth.users.id`. Columns include
  `display_name`, `avatar_url`, `skill_level`, `current_resort_id`,
  `live_recording_enabled`, per-difficulty speed presets, body measurements,
  and the selected ski.
- `friendships` — `(requester_id, addressee_id, status, created_at)` where
  `status ∈ {'pending', 'accepted'}`.
- `meet_requests` — pending and active meetup sessions between two friends,
  keyed by `id`; carries resort, exact mountain dataset identity, graph snapshot
  date, chosen meeting node, both starts, full paths, and ETAs.
  `status ∈ {'pending', 'accepted', 'declined', 'expired'}` enforced by CHECK
  constraint; a BEFORE UPDATE trigger rejects backwards transitions (e.g.
  expired → pending).
- `imported_runs` — per-user ski activity rows parsed from GPX / TCX / FIT /
  Slopes imports, restored .powdermeet backups, AND live on-device run
  detection (`source ∈ {'slopes', 'gpx', 'tcx', 'fit', 'healthkit', 'live',
  'powdermeet'}`). Carries
  a shared per-run identity plus dataset version, full directed matched segment
  sequence, exact edge-local pace observations, confidence, raw source
  identity, and equipment-at-activity provenance. The physical descent remains
  one row for history and stats. Display-only or ambiguous multi-edge rows may
  remain saved, but cannot train routing.
- `profile_stats` — table aggregating `imported_runs` into lifetime stats
  (distance, vertical, top speed, avg speed, days, runs).
- `profile_edge_speeds` — per-`(profile, resort, edge, conditions_fp,
  equipment_key)` rolling-average speeds. The "same ski + same run + same
  conditions + faster previous = faster prediction" signal lives here.
  `UserProfile.traverseTime` prefers the selected ski's trusted cohort, falls
  back to neutral history, and never borrows another ski's cohort. These rows
  are measured edge pace, not a generic speed preset: exact-condition rows are
  used without reapplying terrain, weather, or the same ski effect; `default`
  rows skip the already-observed terrain model but receive current weather
  once; unrelated condition buckets are rejected. With no trusted history it
  falls back to the bucketed-difficulty profile speed and full synthetic model.
  Friends-only RLS read on this table lets MeetSolver give *both* skiers
  per-edge calibration in the solve, so uploading activity files improves
  your friend's half of a meet route too — not just yours.
  Recompute accepts only current-dataset, high-confidence, finite, physically
  plausible edge observations that belong to the matched segment sequence.
  Pre-v5 single-edge runs retain a legacy whole-run fallback (not proof of
  forward GPS pace); new route-only records are excluded. Legacy multi-edge
  averages are never copied onto every edge.
- `live_presence` — last-known position row per user, written by the iOS
  client via REST for cold-start hydration.

**Row Level Security** is enabled by the migrations on all app-owned public
tables. In particular:
- `profiles` — readable by authenticated users for social discovery; only the
  owner can insert or update their row.
- `friendships` — readable by either party; only the requester can insert,
  only the addressee can accept (a status-transition trigger pins the path
  to pending → accepted). Removing a friend is a DELETE by either party.
- `meet_requests` — readable by either party; only the sender can insert;
  either party can update (receiver accept/decline, sender cancel-to-expired).
  Status-transition trigger enforces allowed lifecycle.
- `live_presence` — readable only by accepted friends of the row owner (this
  is the privacy boundary for live positions — do not rely on client-side
  filtering alone).
- `profile_edge_speeds` — owner read/write, plus accepted-friend read so
  meet solves can use the friend's per-edge rolling speeds instead of
  falling back to bucketed difficulty for the friend's half of the
  route.

**RPC functions**

- `recompute_profile_stats(uid uuid)` — re-aggregates `imported_runs` into
  `profile_stats` for a user. Called after activity imports.
- `recompute_profile_edge_speeds(uid uuid)` — rebuilds
  `profile_edge_speeds` from current `imported_runs` (idempotent
  delete-before-insert), enforcing dataset, confidence, topology, speed, and
  duration gates and aggregating each equipment cohort independently. Called
  after every import / restore / delete.
- `find_users_by_phones(phones text[])` — returns `profiles` rows whose
  `auth.users.phone` is in the supplied list (SECURITY DEFINER).
- `find_users_by_emails(emails text[])` — same shape, for email matching.
  See `supabase/migrations/20260418081057_find_users_by_emails_rpc.sql` for reference.

**Realtime**

Enable Realtime for `friendships`, `meet_requests`, and `live_presence`. The
position broadcast path uses Supabase Realtime **Broadcast** channels
(`pos:cell:{geohash6}`) — no database table is involved for that hot path.

### 5. Sign in with Apple (optional)

Email/password sign-in works without any extra setup. Sign in with Apple
needs three things wired together:

1. **Apple Developer Program account** ($99/yr). The Sign In with Apple
   capability is unavailable to free Personal Teams.
2. **App ID** at `developer.apple.com` → Identifiers → your bundle id
   (`com.powdermeet.PowderMeet` in this repo) → enable **Sign In with
   Apple** under Capabilities.
3. **Supabase Apple provider** at `Authentication → Providers → Apple`:
   toggle it on and add your bundle id under *Authorized Client IDs*.
   No client secret is required — the iOS native flow uses the identity
   token directly via `signInWithIdToken`.

The capability is already present in `PowderMeet.entitlements`. If you're
running with a Personal Team for simulator-only work, comment out
`com.apple.developer.applesignin` in the entitlements file or Xcode will
refuse to sign. Restore it before archiving for TestFlight.

`Services/SupabaseManager.swift` and `Views/Auth/AuthView.swift` hold the
client-side flow; `Utilities/CryptoHelpers.swift` generates the nonce
(raw → Apple, SHA-256 → Supabase).

### 6. Deploy the snapshot Edge Function (optional, but recommended)

`ResortDataManager` calls a `snapshot-resort` Edge Function. **Chunked
elevation builder** — big resorts (Vail, Whistler, Palisades) have 5K+
elevation coordinates and Open-Meteo rate-limits per-IP at ~6-10 batches.
The function is a state machine:
1. **Stage 0** — fetch OSM via Overpass, write `osm-{date}.json`, write
   a `checkpoint-{date}.json` blob with `{coords, processed: 0,
   elevations: {}}`. Return `status: "elevation_pending"`.
2. **Stage N** — read checkpoint, process up to 1200 coords (12 batches
   × 100), merge into `elevations`, persist. Return progress. Repeat.
3. **Final** — when `processed == total`, write merged `elev-{date}.json`,
   delete checkpoint, return signed URLs (`status: "ready"`).

The Swift client (`ResortDataManager.driveSnapshotPipeline`) loops on
`elevation_pending` until `ready`. Worst-case big resort: ~5 round-trips
to cold-build; subsequent devices hit the cached pinned blob in one
round-trip. The same chunked driver lives in `tools/prewarm_snapshots.py`
so a single CLI run pre-bakes the whole 159-resort catalog.

Without the canonical graph functions deployed, the client can show a frozen
snapshot preview but will not send or activate navigation, and it never builds
a live device-specific Overpass routing graph. The builder and the iOS client
independently reject wrong-resort, stale-fingerprint, dangling, duplicate,
detached, non-finite, out-of-range, or queue-ambiguous graphs before anything
is uploaded, cached, or routed.

```bash
# First time: create the storage bucket the function writes to.
# Either via Supabase Studio (Storage → New bucket → "resort-snapshots")
# or via the SQL editor:
#   insert into storage.buckets (id, name, public) values
#     ('resort-snapshots', 'resort-snapshots', false);

supabase functions deploy snapshot-resort
```

Pinned snapshots (`ResortEntry.defaultPinnedSnapshotDate`) make the blobs
immutable — every device on the same pin gets the same OSM + elevation
data, so trail / lift counts stop drifting between cold launches.

### 7. Build + run

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build
```

Or press `Cmd+R` in Xcode with an iPhone simulator selected. All app and test
build configurations use `TARGETED_DEVICE_FAMILY = 1`. `ci_scripts/ci_post_clone.sh`
prepares Mapbox credentials when an Xcode Cloud workflow is configured.

Run the tests with `xcodebuild test` on the same destination. The private
full-day Garmin/Slopes import audits are opt-in: set
`POWDERMEET_RUN_PRIVATE_IMPORT_AUDIT=1` and `POWDERMEET_PRIVATE_DATASET` on the
test action (details in `AGENTS.md`).

### 8. Bundle ski topsheet artwork (optional)

`SkiPairView` renders friends' skis (friend rows), the user's skis (on-mountain
status card), and the SKIS picker preview as horizontal-ski silhouettes with
proper hourglass sidecut. Geometry per category is parameterized from
manufacturer-published widths (`skis_catalog.waist_width_mm`); a powder ski
visibly looks fatter than a race ski because the underlying numbers say so.

Topsheet rendering is image-only — no procedural brand-imitation patterns. A
catalog row\'s `topsheet_asset_key` column resolves at runtime against
`PowderMeet/Resources/SkisTopsheets.xcassets`:

- **Asset present** — `Image(assetKey)` clipped to the silhouette is the body.
- **Asset missing** — neutral dark gradient on the silhouette; the model name
  text label still reads.

To bundle licensed topsheet PNGs into the asset catalog there are two
helper scripts. Both feed into the same final importer:

**Path A — Playwright auto-fetch (one command, defeats bot protection).**
A real Chromium with stealth patches searches DDG-Lite, navigates to each
brand/retailer product page, and extracts og:image. Works on sites that
block plain HTTP (Atomic, Salomon, evo, Backcountry — all PerimeterX).

```bash
~/topsheet-source/.venv/bin/pip install playwright playwright-stealth
~/topsheet-source/.venv/bin/playwright install chromium
~/topsheet-source/.venv/bin/python tools/playwright_topsheets.py --auto
```

**Path B — Operator-curated URLs (manual list, no browser needed).**
Open `tools/topsheet_urls.tsv`, paste an image URL per slug, then:

```bash
~/topsheet-source/.venv/bin/python tools/scrape_topsheets.py --from-urls
```

Both paths land cleaned 1280×200 PNGs in `~/topsheet-source/processed/`.
Then run the final importer:

```bash
pip install Pillow                                  # one-time
python3 tools/import_topsheets.py ~/topsheet-source/processed
```

Source PNGs must be named with the slug format `<brand>-<model>.png`
(lowercase, hyphenated, e.g. `atomic-bent-110.png`, `black-crows-atris.png`).
The importer normalizes each to 1280×200 with alpha, writes one image set per
file into `SkisTopsheets.xcassets`, and emits `tools/topsheet_keys.sql` —
paste that into the Supabase SQL editor or `supabase db push` to populate
`topsheet_asset_key` on the matching rows. Catalog seed + slug mapping live
in `tools/import_topsheets.py`.

The migration that adds the column is `supabase/migrations/20260509025138_skis_catalog_topsheet_keys.sql`.
Naming convention + image specs are documented in AGENTS.md under
"Operator runbooks → Topsheet artwork import".

---

## Repository layout

```
PowderMeet/             iOS app: Algorithm (solver), Navigation, Map, Models,
                        Services (dataset cache, parsers, realtime), Theme, Views
PowderMeetTests/        XCTest suite; Fixtures/GPSLogs is a parsed corpus of
                        real Slopes and GPX recordings
supabase/               Postgres migrations, pgTAP tests, edge functions
tools/canonical_ingest/ Python operator package that stages, builds, and
                        publishes one exact resort graph
scripts/                Operator-side scripts
ci_scripts/             Xcode Cloud post-clone script
Demos/                  Media behind the gallery on zlichtman.com
AGENTS.md               Architecture, invariants, backend, and operator runbooks
```

## Running the full experience

Some parts of the app only come alive with a second device:

- **Live friend presence** — the friend dot, signal quality, and ETA all depend
  on a second account broadcasting location.
- **Meet requests** — sender and receiver must be mutual friends.
- **Active meetup** — routes render for both participants live.

For solo testing, the `RoutingTestSheet` (Debug, Ad Hoc, and TestFlight builds)
exposes every named trail group and lift as a searchable location. Set **your**
location once, reopen the picker, select a different trail or lift, then choose
**Preview With Partner Here**. This runs the same strict two-skier solver with a
fixed advanced demo partner, draws both approaches on the map, and labels the
result as preview-only. It never sends a request or starts a live session.

---

## License

Source-available, **all rights reserved**. See [`LICENSE`](LICENSE) for the
full text. The code is published for viewing and evaluation only — no rights
are granted to copy, modify, distribute, sublicense, sell, or create
derivative works without prior written permission. To request permission,
open an issue on this repository.

## Acknowledgements

- [OpenStreetMap](https://www.openstreetmap.org/) contributors — the mountain
  graph is built from OSM's `piste:type` / `aerialway` tags.
- [open-elevation](https://open-elevation.com/) — free elevation DEM.
- [Open-Meteo](https://open-meteo.com/) — free weather API.
- [Mapbox](https://www.mapbox.com/) — Satellite Streets base style, terrain, and rendering.
- [Supabase](https://supabase.com/) — auth, Postgres, Realtime, Storage,
  Edge Functions.

## Version 1.0.0 — build 62 testing release

Uploaded to App Store Connect on September 21, 2026 for TestFlight processing.
This version restores the original branded interface, keeps eight icon variants,
adds the PowderMeet House ski to the picker, fixes stale mountain loading, and
requires confirmed server updates for friend and meetup acceptance.

The map now consumes the app's existing location updates instead of starting a
second GPS permission flow. Active ski sessions use When-In-Use authorization
with the system location indicator; there is no Always upgrade request.

Validation: 618 simulator tests passed, eight optional tests skipped; the Release
archive and App Store Connect upload succeeded. Real map previews were captured
for Whistler, Breckenridge and Niseko. A rolled-back two-user database test covered
friend requests, acceptance, meetup acceptance and cancellation.

**Known limitations:** this is a testing release, not complete live-routing
coverage. All 159 source graphs parse; sampled local routes succeeded for 103,
with 56 unresolved. Reviewed canonical datasets and fresh matching operational
status remain unpublished. Go To and live meetup navigation remain gated when
that data is unavailable. Two-phone realtime, push and physical background-session
verification remain pending. See [release readiness](RELEASE_READINESS.md).
