# PowderMeet

Two skiers, one mountain, one question: *where should we meet?* PowderMeet solves it — picking the optimal meeting point on the trail/lift graph given each skier's ability and live trail conditions (fresh snow, ice, wind, visibility), so neither of you ends up stuck on a run you can't ski, or waiting 20 minutes for your friend.

Swift 6 + SwiftUI · Mapbox Maps · Supabase (Postgres + Realtime + Edge Functions).

---

## Architecture at a glance

- **iOS client** — Swift 6, SwiftUI, Xcode 16 synchronized folder groups. Targets
  iOS 17.6+. iPhone is the primary device; iPad layout is supported.
- **Map** — Mapbox Maps SDK v11, `mapbox://styles/mapbox/satellite-streets-v12`
  base, with per-resort trail / lift / POI layers rendered from a locally-built
  mountain graph.
- **Graph** — Directed graph of lift + run segments built from OpenStreetMap
  ski tags. Nodes carry elevation (open-elevation), edges carry slope, aspect,
  and difficulty. Dijkstra + an α-weighted wait penalty picks the meeting point.
- **Backend** — Supabase for auth, profile storage, friend graph, meet
  requests, live position broadcast, and a serverless Edge Function that
  caches per-resort OSM + elevation snapshots so every device builds an
  identical graph.
- **Weather** — Open-Meteo (free, no key).

See `CLAUDE.md` for a deeper tour of directory layout and architectural
invariants.

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
git clone <your-fork-url>
cd PowderMeet
open PowderMeet.xcodeproj
```

The first open will fetch Swift Package dependencies (`MapboxMaps`, `Supabase`).
This takes a minute on a cold cache.

### 2. Create `Secrets.xcconfig`

```bash
cp Secrets.xcconfig.example Secrets.xcconfig
```

Then fill it in:

```
SUPABASE_URL = https://YOUR_PROJECT.supabase.co
SUPABASE_ANON_KEY = eyJhbGciOi...   # Supabase → Settings → API → anon public
MAPBOX_ACCESS_TOKEN = pk.ey...       # Mapbox → Account → Access Tokens
```

`Secrets.xcconfig` is git-ignored — it never gets committed. The three keys
are wired into the build via `Info.plist` substitutions:

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

The app expects the following schema. A small number of incremental migrations
live in `supabase/migrations/`, but the bulk of the initial schema was built
interactively in Supabase Studio during development and is **not** fully
captured as migrations in this repo. If you're setting up a fresh project,
you'll need to create these tables/policies yourself (SQL editor or Studio).

**Tables**

- `profiles` — user profile mirror. PK = `auth.users.id`. Columns include
  `display_name`, `avatar_url`, `skill_level`, `current_resort_id`,
  `top_speed_kmh`, plus dormant columns noted in `CLAUDE.md`.
- `friendships` — `(requester_id, addressee_id, status, created_at)` where
  `status ∈ {'pending', 'accepted'}`.
- `meet_requests` — pending and active meetup sessions between two friends,
  keyed by `id`; carries resort, graph snapshot date, and chosen meeting node.
  `status ∈ {'pending', 'accepted', 'declined', 'expired'}` enforced by CHECK
  constraint; a BEFORE UPDATE trigger rejects backwards transitions (e.g.
  expired → pending).
- `imported_runs` — per-user ski activity rows parsed from GPX / TCX / FIT /
  Slopes imports, restored .powdermeet backups, AND live on-device run
  detection (`source ∈ {'slopes', 'gpx', 'tcx', 'fit', 'live'}`). Carries
  `dedup_hash` so re-imports of the same file are idempotent.
- `profile_stats` — table aggregating `imported_runs` into lifetime stats
  (distance, vertical, top speed, avg speed, days, runs).
- `profile_edge_speeds` — per-`(profile, resort, edge, conditions_fp)`
  rolling-average speeds. The "same run + same conditions + faster
  previous = faster prediction" signal lives here —
  `UserProfile.traverseTime` uses `rolling_speed_ms` directly when
  `observation_count >= 3`, otherwise falls back to the
  bucketed-difficulty profile speed. Friends-only RLS read on this
  table lets MeetSolver give *both* skiers per-edge calibration in
  the solve, so uploading activity files improves your friend's half
  of a meet route too — not just yours.
- `live_presence` — last-known position row per user, written by the iOS
  client via REST for cold-start hydration.

**Row Level Security** must be enabled on all of the above. In particular:
- `profiles` — self-read/write; friends-of-caller read allowed via a join
  against `friendships` where `status = 'accepted'`.
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
  delete-before-insert). Called after every import / restore / delete.
- `find_users_by_phones(phones text[])` — returns `profiles` rows whose
  `auth.users.phone` is in the supplied list (SECURITY DEFINER).
- `find_users_by_emails(emails text[])` — same shape, for email matching.
  See `supabase/migrations/20260418_find_users_by_emails.sql` for reference.

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

Without the function deployed, the client falls back to direct Overpass
fetches — works for a single device but loses cross-device determinism
because two devices may hit different Overpass mirrors.

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
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Or hit `Cmd+R` in Xcode with an iPhone simulator selected. iPhone is the
primary target (one-handed on a chairlift, in a pocket with gloves). Verify
iPad layout with:

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' build
```

CI (GitHub Actions) runs both destinations on every PR + push to `main`
via `.github/workflows/build.yml`. Required repo secrets:
`MAPBOX_DOWNLOADS_TOKEN` (scope `DOWNLOADS:READ`), `MAPBOX_ACCESS_TOKEN`,
`SUPABASE_URL`, `SUPABASE_ANON_KEY`.

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

The migration that adds the column is `supabase/migrations/20260513_skis_catalog_topsheet_keys.sql`.
Naming convention + image specs are documented in CLAUDE.md under
"Operator runbooks → Topsheet artwork import".

---

## Repository layout

```
PowderMeet/             iOS app source (Swift / SwiftUI)
PowderMeetTests/        XCTest target
supabase/               Postgres migrations + edge functions
  migrations/             SQL — `supabase db push`
  functions/              snapshot-resort, build-resort-graph,
                          get-resort-graph, refresh-live-status, send-push
tools/canonical_ingest/ Python package: source-fuse Skimap + OpenSkiMap
                        + Overpass into a draft manifest, reconcile,
                        apply. The 8-step operator workflow lives in
                        CLAUDE.md → "Operator runbooks → Canonical ingest".
ci_scripts/             Xcode Cloud `ci_post_clone.sh`.
scripts/                Operator-side bash (e.g. deploy-build-resort-graph.sh).
_local/                 ⚠️ **Gitignored**. Local-only files that never
                        enter the repo:
                          _local/media/     demo screenshots, video
                          _local/secrets/   APNs .p8 keys
                          _local/gps-logs/  personal GPX/Slopes test data
                        Single umbrella so contributors only have one
                        ignore rule to remember.
CLAUDE.md               In-repo orientation for Claude Code sessions.
                        Single source of truth for architectural
                        invariants, backend schema, edge functions,
                        canonical-pipeline state, and operator runbooks.
                        When you add or move project structure, update
                        this README *and* CLAUDE.md in the same change.
                        No other docs in the repo by policy — per-feature
                        READMEs and standalone runbooks all live in
                        CLAUDE.md.
```

---

## Running the full experience

Some parts of the app really only come alive with a second device:

- **Live friend presence** — the friend dot, signal quality, and ETA
  calculation all depend on a real second account broadcasting location.
- **Meet requests** — sender and receiver must be mutual friends.
- **Active meetup** — routes render for both participants live.

For solo testing, the `RoutingTestSheet` (DEV build only) lets you pick any
graph node as your "current location" so you can exercise the solver without a
friend.

---

## License

Source-available, **all rights reserved**. See [`LICENSE`](LICENSE) for the
full text. The code is published for viewing and evaluation only — no rights
are granted to copy, modify, distribute, sublicense, sell, or create
derivative works without prior written permission. To request permission,
open an issue on this repository.

---

## Acknowledgements

- [OpenStreetMap](https://www.openstreetmap.org/) contributors — the mountain
  graph is built from OSM's `piste:type` / `aerialway` tags.
- [open-elevation](https://open-elevation.com/) — free elevation DEM.
- [Open-Meteo](https://open-meteo.com/) — free weather API.
- [Mapbox](https://www.mapbox.com/) — satellite-streets base style + rendering.
- [Supabase](https://supabase.com/) — auth, Postgres, Realtime, Storage,
  Edge Functions.