# PowderMeet engineering guide

PowderMeet is an iPhone app that finds the fairest meeting point for two skiers
on a resort's lift-and-trail graph and guides both of them there. This guide is
the architecture and operations reference: what the pieces are, the invariants
the code depends on, how the backend and the canonical resort pipeline fit
together, and the operator runbooks. Setup and day-to-day usage are in
`README.md`.

## Stack

- **iOS:** Swift 6 + SwiftUI, Xcode 16 Synchronized Folders. New `.swift` files
  auto-register; no `.pbxproj` edits needed.
- **Map:** MapboxMaps SDK (`satellite-streets-v12` at runtime and in the offline
  cache, with terrain exaggeration and zoom-aware canonical graph overlays).
- **Backend:** Supabase — auth, Postgres, Realtime (Broadcast + postgres_changes).
- **On-device cache:** SwiftData (`FriendLocationStore`); in-memory
  `LocationHistoryStore` breadcrumbs; a per-user `PendingLiveRunStore` file
  holding live runs whose save failed offline.
- **Build:** Open `PowderMeet.xcodeproj` in Xcode. Target family is iPhone
  only (`TARGETED_DEVICE_FAMILY = "1"`). PowderMeet is a one-handed-on-a-
  chairlift, in-a-pocket-with-gloves app — iPad layout isn't a use case
  worth shipping. All four build configs (app + tests, Debug + Release)
  are pinned to iPhone.
- **SPM deps:** `MapboxMaps`, `Supabase`. SourceKit often can't resolve these
  in isolation — "No such module" / "Cannot find type" diagnostics are usually
  project-resolution noise. Trust `xcodebuild`, not SourceKit.

## App shell — what's actually on screen

`ContentView.swift` is the scaffold — pure routing only. It owns three tabs
in a stacked-opacity layout (so each tab keeps its `@State` across switches):

- **Tab 0 — Map** (`ResortMapScreen` + `TimelineView` scrubber + `EdgeInfoCard`)
  — this is the **default** tab on launch (`selectedTab = 0`)
- **Tab 1 — PowderMeet** (`MeetView` — friends, meet requests, active meetup)
- **Tab 2 — Profile** (`ProfileView` — hero, stats, friends, settings)

Shared chrome: top `pageHeader` (tab title), bottom `resortBar` (resort picker
trigger), bottom `tabBar`. Resort picker, profile sub-screens, and meet flow
all open as sheets from this root.

`ContentCoordinator.swift` (`@MainActor @Observable`) owns the resort /
conditions / realtime / presence / nav-services / meetup-session lifecycle
that used to live as ~30 `@State` vars and a dozen `.onChange` watchers
inside `ContentView`. The view's `.task` calls `coordinator.bind(resortManager:)`
once and then dispatches every `.onChange` body to a typed coordinator
method (`handleSelectedEntryChange`, `handleScenePhaseChange`,
`handleFriendIdsChange`, `handleSelectedTimeChange`,
`handleTestMyNodeIdChange`, `handleLocationChange`,
`graphChangedShouldDropEdgeSelection`, `syncNavigationServices`,
`refreshGhostCache`, `teardown`). Owned services (`FriendService`,
`LocationManager`, `MeetRequestService`, `LocationHistoryStore`,
`FriendQualityStore`, `MapBridge`, lazily `RealtimeLocationService` +
`PresenceCoordinator`, conditionally `NavigationDirector` /
`NavigationViewModel` / `RouteChoreographer` / `BlendedETAEstimator`)
hang off the coordinator instance, not the view.

`MeetView` is a thin compositor over five purpose-specific subviews under
`Views/Meet/`: `IncomingMeetRequestsSection`, `PendingFriendRequestsSection`,
`MeetingOptionsSection` (paging cards + SHOW ROUTE ON MAP), `FriendsListSection`
(takes precomputed `Row` values so it doesn't read services itself), and
`PowderMeetActionButton` (pinned-bottom action). `MeetView` itself keeps the
cross-section coordination state (`selectedFriendId`, `fullMeetingResult`,
debounced solver, send-meet-request, etc.).

## Directory map

```
PowderMeet/                 iOS app target (Xcode 16 synchronized folder)
  PowderMeetApp.swift         entry point, URL-scheme auth callback
  ContentView.swift           three-tab scaffold: Map, PowderMeet, Profile
  ContentCoordinator*.swift   resort / conditions / realtime / presence / nav lifecycle
  MeetupSessionController*    active meetup: route activation, reroute on closure
  RealtimeBootstrapper.swift  sign-in / sign-out ordering for the realtime stack
  Algorithm/                  MeetingPointSolver (Dijkstra + Pareto labels), BinaryHeap,
                              TraversalContext, RouteSimplicity, RouteTimeUncertainty,
                              SolverCache, StoredRouteValidator, SunExposureCalculator
  Navigation/                 NavigationDirector, NavigationViewModel, ETAEstimator,
                              RouteGeometryLocator, RouteSwitchPolicy, RoutingOrigin
  Map/                        MountainMapView (+Style, +Animations), GeoJSONBuilder,
                              MapLayerState, TreeLayerBuilder, CinemaDirector
  Models/                     MountainDataset / MountainGraph / MountainStatus,
                              MountainGraphIntegrity, RendezvousPoint, ResortCatalog
                              (159 Epic/Ikon resorts), social lifecycle types
  Services/                   MountainRepository (sole disk cache), CanonicalGraphFetcher,
                              GraphBuilder (+Topology, +Connectivity, +TrailGroups,
                              +Elevation; legacy preview only), OverpassService,
                              SupabaseManager, FriendService, MeetRequestService,
                              RealtimeLocationService, PresenceCoordinator,
                              ConditionsService, activity parsers (Slopes/GPX/TCX/FIT),
                              SkiActivitySegmenter, TrailMatcher, LiveRunRecorder
  Theme/                      HUDTheme, HUDFont, ThemeManager, CustomAppTheme,
                              PowderGlass, PowderPage
  Views/                      MapView, MeetView (+ Views/Meet/*), ProfileView,
                              Auth/, Onboarding/, Components/, RoutingTestSheet (debug)
  Resources/ResortData/       one curated overlay JSON per resort
  Resources/SkisTopsheets.xcassets  bundled ski top-down renders
PowderMeetTests/            XCTest suite (solver, topology, dataset, parsers,
                            segmentation, calibration, rendezvous, social, presentation)
  Fixtures/GPSLogs/           real Slopes/GPX recordings parsed by ActivityCorpusParseTests
supabase/                   migrations/, tests/database/ (pgTAP), functions/
                            (snapshot-resort, build-resort-graph, get-resort-graph,
                            get-resort-3d-pack, refresh-live-status, send-push, _shared)
tools/canonical_ingest/     Python operator package: ingest, reconcile, apply, publish
scripts/                    deploy-build-resort-graph.sh
ci_scripts/                 Xcode Cloud ci_post_clone.sh
Demos/                      media behind the gallery on zlichtman.com
_local/                     gitignored: media originals, APNs keys, private GPS logs
```

## Key architectural invariants (do NOT break)

- **One immutable mountain identity:** navigation requires a canonical `MountainDataset` exact-loaded by manifest/graph-version/content SHA. `MountainStatus` is a separate observed/expires sidecar keyed by stable edge IDs.
- **Operational status expires:** never reuse an in-memory status projection past `MountainStatus.expiresAt`. Foreground resume forces a sidecar refresh; the foreground minute clock refreshes again within two minutes of expiry and throttles failed retries to five minutes.
- **Map closure truth:** closed validated segments have their own exact red dashed source/layer and closure label. Named groups compute open/partial/closed across every member edge; never let one open segment make a partially closed trail render as fully open.
- **Route source semantics:** ski-area polygons (`area=yes`) are footprints, not centerlines. Exclude private/no access with explicit ski-specific overrides. Only explicit `oneway=no` enables reverse lift travel; each direction preserves the source geometry and charges one boarding queue. Canonical ride/vertical totals apply once per direction, not per split edge.
- **Canonical rows are identities, not segments:** `osm_way_ids` are authoritative whenever present; exact-name fallback is legal only for a source-less reviewed row. Build fails atomically on missing, duplicate, multiply claimed, disconnected, or branched identities.
- **Explicit rendezvous only:** route search may traverse any eligible graph node, but a PowderMeet may terminate only at a `RendezvousPoint` validated against the current dataset's stable node IDs. Rank candidates first by the deterministic reliability score `max(tA,tB) + αweather,kind·|tA-tB| + 0.5·sqrt(varA+varB)`, then expected arrival, spread, uncertainty, catalog confidence, stop quality, and stable ID.
- **Fairness chooses a stop, never a detour:** each skier's route search retains up to eight non-dominated labels per node, accounting for mean time, total variance, current-action uncertainty, and action count. It reserves the fastest mean-time label and chooses the two approaches jointly.
- **Solver cache:** `MeetingPointSolver.solutionCache` is static. Its key includes the complete graph fingerprint (including mutable live lift waits), both profiles, both per-skier contexts, complete learned history values, the normalized solve-time bucket, and equipment physics.
- **Per-skier solver context:** the 2-skier `solve(...)` builds TWO `TraversalContext`s — one per skier — via `buildContext(for: skier.id.uuidString)` so each skier's `traverseTime` reads their own `edgeSpeedHistory` slot in `solver.edgeSpeedHistoryByProfile`. Don't fall back to a single shared context — that's how the local user's per-edge calibration used to bleed into the friend's predicted edge times.
- **Canonical TraversalContext:** anything outside the solver that needs one (route narrative, route-reason copy, ETA recompute) MUST go through `solver.makeContext(for: skierID)` — never construct a `TraversalContext` by hand. Hand-rolled contexts diverge from the solver's quantization (15-min `solveTime` bucket, cloud cover ÷10, etc.) and ignore per-skier history, so the narrative drifts from the solve.
- **Time-dependent FIFO:** lift queue curves and forecast wind penalties must keep completion time monotonic with departure time. Queue anchors interpolate continuously; wind changes only ride time through a continuous curve and never multiplies time already spent waiting.
- **Continuous conditions:** hourly forecast samples interpolate only across a normal gap. At an edge or a missing interval, hold the nearest sample for one hour, fade to current conditions over 30 minutes, then use current conditions.
- **Resort-local clock is authoritative:** Open-Meteo requests use `timeformat=unixtime`; decode hourly values as absolute UTC instants and carry its `utc_offset_seconds` through `ResortConditions` → `MeetingPointSolver` → `TraversalContext`. That DST-aware offset controls lift hours, weekday queue choice, and time-of-day demand.
- **Mountain-local sun:** solar position is computed from UTC plus the resort longitude. Never read the device timezone for sun/aspect routing; a remote trip preview and an on-mountain solve for the same instant must be identical.
- **No unsafe route fallbacks:** a strict solve respects closures, ability, dataset identity, and exact start nodes or returns an honest failure. Legacy `.forcedOpen` / `.forcedOpenNeighborSubstitution` values remain decode-only for old records and are never produced by current solving.
- **Fresh status is part of “live”:** a canonical dataset may produce a navigable `.live` meet only while its dataset-matched `MountainStatus` is usable. Missing, future-dated, or expired status returns `.operationalStatusUnavailable`; it must not silently route on base-open topology.
- **Fresh weather may optimize, never renegotiate, an active meet:** assign the fast current snapshot immediately for UI, but trigger active-route evaluation only after the hourly merge attempt completes so the current-only snapshot cannot consume the 30-second throttle just before forecast data arrives. Each phone may optimize its own remaining path to the already-agreed node through `RouteSwitchPolicy`; weather must never move that destination, weaken status or capability gates, or bypass identical-path, meaningful-gain, near-arrival, and anti-flap checks.
- **Route rehearsal is local and visibly non-live:** the pre-release location picker may run a strict two-skier solve between a tester-selected local start and a second selected node using the signed-in profile plus the fixed advanced demo partner. Every successful rehearsal is stamped `.nonCanonicalDataset`, remains preview-only, and may only populate the map result.
- **Preview maps are timeless:** any solve on a non-canonical (frozen preview) dataset runs with `solveTime = nil` — `MeetupSessionController.configureSolver` and `MeetSolver` both enforce it — because a preview map has no verified lift hours or status. Canonical data keeps arrival-time lift hours.
- **Solo landmark previews reuse strict routing:** `LandmarkRoutePolicy` allows Map → Go To only while no active meetup owns the map, the immutable dataset is canonical, current operational status is routable, and the exact target exists in both the dataset rendezvous catalog and graph. Resolve the same GPS-aware fractional `RoutingOrigin` and use configured `pathTo`; never route to an arbitrary tapped junction or introduce a relaxed fallback. Pre-release builds may additionally preview a route on a non-canonical map (`canUseUnverifiedPreview`), labeled UNVERIFIED, stamped `.nonCanonicalDataset`, never navigation.
- **Pre-release test meetups:** `PreviewMeetupPolicy` lets a TestFlight/Debug build send, accept, and activate a two-phone meetup on a mountain's frozen preview map. The request carries the preview map's own identity (`mlegacy-…`), and the receiver must rebuild that exact identity. The session is stamped `.nonCanonicalDataset`, is labeled TEST MEETUP on both phones for its whole life, never reads or requires operational status, and is validated only against that exact preview topology. App Store builds reject it with an explicit message. A canonical identity never matches a legacy dataset and vice versa.
- **Live recording keeps going while locked:** fixes reach `ContentCoordinator.handleLocationChange` through `LocationManager.onFix` straight from the delegate (SwiftUI `onChange` does not run in the background). The recorder is only stopped on background when no ski session holds background location. A failed save queues the exact row per user in `PendingLiveRunStore` for idempotent retry, and a successful save recomputes `profile_stats` as well as edge speeds.
- **Accepted-meet recovery is bounded and exact:** cold launch may query recent accepted rows involving the signed-in user and restore only the newest row whose `created_at` is within four hours and whose full `dataset_version` is present. Select its known catalog resort before graph/social hydration, then run the normal strict sender/receiver activation path.
- **Durable end intent wins recovery:** every active-session teardown initiated locally or by route invalidation must call `endRequestEventually`, which saves a user-scoped termination tombstone before clearing UI state. Retry queued expirations at bootstrap and on reachability restoration; remove a tombstone only after the server update succeeds.
- **Live route progress follows geometry:** `RouteProgressTracker` projects GPS onto the remaining route polylines, maintains monotonic within-edge progress, and measures persistent deviation against that geometry. Node identity alone is never enough to claim the skier is on-route.
- **Active ETA fails closed:** `ActiveRouteETA` re-costs the exact remaining edge sequence at the current arrival clock. If any unfinished edge is no longer traversable (for example, a lift is reached after closing), return `nil` and request a safety reroute; never omit the unavailable edge and present a deceptively short ETA.
- **Exact-path confidence is canonical:** GPS position uncertainty contributes to initial path variance, and accepted/stored paths are re-costed through `MeetingPointSolver.metrics(for:skier:)`. Planning, activation, and rerouting must preserve or recompute ETA standard deviation; never drop it at handoff or recycle a range from older conditions.
- **Directed live starts do not teleport:** `routingOrigin(to:)` retains the exact directed approach edge plus the skier's quantized polyline fraction until they reach its target. The solver, route tracker, ETA, per-leg times, route overlay, and future-position projection all charge or draw only the unskiied remainder.
- **Maneuver direction comes from geometry:** transitions between different runs resolve left/right/straight from the terminal bearing of the current edge and initial bearing of the next. Same-group fragments continue straight; never restore a hard-coded right-turn icon.
- **Sensor capture time gates routing:** store and transmit the GPS sample's actual capture time, never the later heartbeat/send time. Stale/cold friend fixes and fresh but poor-accuracy fixes may remain on the map with explicit age/offline/uncertainty treatment, but only a fresh routing-grade fix (<75 seconds, plausible future skew, acceptable accuracy) may start or change a route, train history, record a run, auto-select a resort, or drive navigation.
- **Fresh packet resort identity gates friend routing:** a live location's sender-stamped `resortId` must exactly match the selected canonical graph for planning, activation, and rerouting. Do not gate a valid packet on `UserProfile.currentResortId`; that profile field is eventually consistent and may be nil or stale while Realtime already proves current presence.
- **Lift closing time is arrival-dependent:** canonical status says whether a lift is operational now, while reviewed bundled `operatingHours` bounds whether it can be used later in the route. Carry those hours through the solver context/cache signature and reject a lift reached at or after close.
- **Activity provenance gates learning:** imported/live observations retain raw source identity, dataset version, directed matched segment sequence, exact edge-local pace observations, match method/confidence, and equipment at observation time. A physical descent stays one history/stat row.
- **Launch/auth surface is continuous and tappable:** `UILaunchScreen` uses the `LaunchBackground` asset instead of the system white default; keep that color aligned with the original theme's root background. `SplashView` and `AuthView` then reuse the same mountain mark, wordmark, contour texture, and hierarchy so cold start does not flash through unrelated visual systems.
- **One source-update path:** `Coordinator.updateDataLayers` in `MountainMapView` is hash-gated per source. Don't push source data anywhere else or the diff optimization regresses.
- **Realtime channels:** position uses Broadcast on `pos:cell:{geohash6}` and `pos:resort:{resortId}` (cross-cell friends); friends use `friends:{id}` (`postgres_changes` on `friendships`); meet requests use `meets:{id}` (`postgres_changes` on `meet_requests`). All go through `ChannelRegistry` (actor, ref-counted).
- **Typed social lifecycle:** database strings decode immediately into `FriendshipStatus` / `MeetRequestStatus`; legal meet transitions flow through `MeetRequestStateMachine`, coordinator effects consume typed events, and friend/meet/location transports use explicit lifecycle enums. A second start during `.connecting`/`.stopping` must not acquire another registry reference.
- **Social snapshot gate:** `FriendService.socialGeneration` stays `0` until `loadSocialSnapshot` applies once. `RealtimeLocationService` rejects inbound position broadcasts while `socialGeneration == 0` so friend filtering never runs against an empty friend set during cold launch (“accept everyone” window).
- **Camera framing:** resort intro lands on `entry.preferredZoom ?? entry.defaultZoom`, `entry.preferredBearing ?? 0`, `entry.preferredPitch ?? 62`. `defaultZoom` is computed from the bounding-box span in `ResortCatalog.swift`; per-resort overrides exist on the catalog entry for resorts whose default isn't framed well.
- **Stale-teardown guard:** `ContentCoordinator.teardown()` (called from `ContentView.onDisappear`) reads `SupabaseManager.shared.sessionGeneration` before tearing down realtime services — if a new session has already started, skip the teardown so we don't reset the new session's freshly-built channels.
- **Sender-stamped timestamps:** `FriendLocation.capturedAt` is set by the sender. Receiver drops payloads with `capturedAt <= stored.capturedAt`.
- **Activity data is owner-scoped:** `imported_runs` rows are readable only by their owner, and `recompute_profile_stats` / `recompute_profile_edge_speeds` (SECURITY DEFINER) refuse a caller recomputing another user's data (`assert_activity_owner`). Friends see aggregates through `profile_stats` and `profile_edge_speeds_friend_read`, never raw runs.
- **No RLS clauses that read the caller's own row in the same table.:** Production-bitten: an audit pass added a resort-scoped clause to `live_presence_friend_read` (`AND live_presence.resort_id = (caller's own live_presence.resort_id)`). It silently rejected friend rows whenever the viewer's own row was missing, stale, or not-yet-matching — cold launch before first GPS fix, between resorts, friend-just- changed-resorts, subscribe-before-first-broadcast — and `postgres_changes` events flow through RLS, so realtime stopped arriving for any pair not perfectly synchronized.

## Realtime presence lifecycle

`PresenceCoordinator` is the single state machine that orders cold launch
and resort switches. The pipeline:

```
idle
  ↓ enter(resortId:)
hydratingSocial      -- await FriendService.loadSocialSnapshot()
  ↓
subscribingChannels  -- await RealtimeLocationService.start(resortId:)
  ↓
live                 -- broadcasts now permitted
  ↓ stop() / stopAndWait() / enter(different resortId)
tearingDown          -- cancel pending broadcast + release channels
  ↓
idle
```

**The two gates that close it.**
1. **Receiver:** `RealtimeLocationService` rejects inbound broadcasts
   while `FriendService.socialGeneration == 0`. The first
   `loadSocialSnapshot` bumps the generation; broadcasts before that
   never reach the friend-filter.
2. **Sender:** `PresenceCoordinator.broadcastNow` no-ops unless
   `phase == .live`. The 5 s heartbeat in `RealtimeLocationService`
   re-fires once `.live` is reached, so liveness is never permanently
   lost — just deferred.

**Hydrate vs broadcast.** Hydrate path (`live_presence` table read +
SwiftData `FriendLocationStore` cache hit) flows through Postgres RLS
— `live_presence_friend_read` enforces "friends only" server-side, and
`profile_edge_speeds_friend_read` does the same for per-edge calibration
data. Broadcast path (`pos:cell:{geohash6}` and `pos:resort:{resortId}`
Supabase Realtime channels) does **not** hit a DB row, so server-side
RLS can't enforce friend-only delivery there. Privacy on the broadcast
path is enforced client-side: every receiver filters incoming payloads
against the social snapshot via `friendIdsProvider`. The two paths
together: RLS for stored state, client filter for the hot ephemeral
stream.

The disk cache is resort-scoped. Switching mountains clears the in-memory
friend layer and hydrates only rows stamped for the newly selected resort;
legacy rows without a resort stamp are ignored. A cached coordinate can
establish same-resort presence only when both its resort identity and its
freshness window match.

**Stop ordering.** `stop()` is synchronous for rapid resort clears; `stopAndWait()` is awaited on sign-out so a fast re-sign-in cannot overlap sessions. `ContentCoordinator.teardown()` releases realtime channels first, then friend subscriptions, then meet requests, then caches.

**Diagnostics.** `Views/RealtimeSelftestView.swift` (DEBUG only) runs
8 invariant checks on the realtime stack — wire any new presence-
adjacent state through it where a regression would otherwise be silent.

## Backend — Postgres, edge functions, cron

Everything lives in `supabase/`: ordered migrations, a pgTAP invariant suite,
and six edge functions.

### Migration reproducibility

- `20260301000000_foundation_schema.sql` reconstructs the profiles,
  friendships, meet requests, auth/profile triggers, base RLS, platform RLS
  event trigger, and avatars bucket. Its DDL is guarded and a second
  application produces no schema difference.
- A clean local database replays every migration: `supabase db reset --local
  --no-seed`, then `supabase test db supabase/tests/database`.
- Production already records migrations newer than the reconstructed
  foundation, so a rollout is previewed with `supabase db push --include-all
  --dry-run` and applied with `--include-all`. Never apply an individual file
  in Studio or change an already-applied version.

### Tables

- `profiles` — one row per user
- `friendships` — accepted + pending friend edges
- `meet_requests` — per-meet state (sender, receiver, resort, stable rendezvous node, full paths, ETAs, `manifest_version`, `dataset_version`, `graph_snapshot_date`)
- `live_presence` — TTL'd last-known position (sender_stamped `captured_at`)
- `resorts_bbox` — 159-row reference table seeded from `ResortCatalog
- `resort_snapshot_pins` — server-driven snapshot pin per resort (or `__catalog__` row for global)
- `imported_runs` — every displayable physical run from any source (`source`: slopes/gpx/tcx/fit/health/strava/garmin/live/powdermeet)
- `profile_stats` — aggregated rollup per profile (runs/days/vertical/topSpeed/distance_m/max_grade_deg/avg_speed_ms)
- `profile_edge_speeds` — (profile_id, resort_id, edge_id, conditions_fp, equipment_key) → rolling speed cache
- `device_tokens` — (profile_id, token, environment) for APNs fan-out
- `user_blocks` — bidirectional block list
- `skis_catalog` — searchable ski brand/model picker (Profile → Activity → CALIBRATION)
- `resort_canonical_manifest` — canonical pipeline: one row per `(resort_id, manifest_version)`
- `canonical_trail` — manifest-scoped trail rows with optional canonical geometry overrides
- `canonical_lift` — manifest-scoped lift rows with optional canonical geometry overrides
- `canonical_geometry_override` — append-only hand-traced geometry
- `resort_graph_blob` — immutable graph build outputs keyed by `(resort_id, manifest_version, snapshot_date, graph_version)`
- `resort_canonical_publication` — immutable publication history for exact built graph identities `(resort, manifest, snapshot, graph schema, SHA)`
- `resort_canonical_active` — one atomic active-publication pointer per resort

### Views

- `current_resort_canonical_manifest` — the manifest and exact graph identity selected by the active publication pointer; staged manifests never appear

### RPCs

Client RPCs: `get_social_snapshot`, `find_users_by_emails` / `find_users_by_phones`, `send_friend_request`, `recompute_profile_stats` / `recompute_profile_edge_speeds`, `resolve_resort_id`. Service-role only: `apply_canonical_manifest` (stages a manifest atomically without touching the active dataset) and `publish_canonical_manifest` (validates the exact built blob and advances or rolls back the active pointer). `canonical_*_with_geom()` helpers feed build-resort-graph.

### Storage buckets

| Bucket | Visibility | Written by | Read by |
|---|---|---|---|
| `resort-snapshots` | private | `snapshot-resort` | client (signed URL via response) |
| `resort-graphs` | private | `build-resort-graph` + `refresh-live-status` | client (signed URL via `get-resort-graph`) |
| `avatars` | public | profile upload | AsyncImage anywhere |

### Realtime publication

Tables in `supabase_realtime` publication: `live_presence`, `friendships`, `meet_requests`. RLS applies to change events, so a receiver only sees rows they're allowed to read. Without these in the publication, the `friends:{id}` and `meets:{id}` postgres_changes streams never replicate (verify with `select * from pg_publication_tables`).

### pg_cron jobs

| Job | Schedule | Purpose |
|---|---|---|
| `live_presence_cleanup_5m` | `*/5 * * * *` | DELETE FROM `live_presence` WHERE captured_at < now() - 15 min |
| `expire-stale-meet-requests` | `*/2 * * * *` | `select expire_stale_meet_requests()` |
| `refresh_live_status_hourly` | `5 * * * *` | POST → `refresh-live-status` edge function via pg_net's `net.http_post`; needs `app.send_push_anon_key` (set in DB config) |

### Edge functions

- **snapshot-resort** — chunked Overpass + elevation builder. Stage 0 fetches
  Overpass and writes a checkpoint blob; each later invocation processes about
  1,200 elevation coordinates, so a large resort cold-builds across several
  round-trips. Returns signed URLs valid one hour.
- **build-resort-graph** — server-side canonical graph builder. Joins the OSM
  and elevation blobs to the canonical manifest and produces a deterministic,
  immutable **staged** graph keyed by `(resort_id, manifest_version,
  snapshot_date, graph_version)`. It runs the same fail-closed integrity
  contract as the client, never infers connectivity, allocates official totals
  once across each identity's directed chain, and emits a fingerprint
  `<nodeCount>:<edgeCount>:<hex16>` that must match Swift's
  `MountainGraph.computeFingerprint`. Wire compression is raw deflate. Deploy
  with `scripts/deploy-build-resort-graph.sh`.
- **get-resort-graph** — client fetch endpoint. A default request resolves the
  one active publication; an exact meet-replay request resolves immutable
  publication history. `cache_valid` only when manifest version and content
  SHA both match.
- **get-resort-3d-pack** — signed URL plus SHA-256 for the newest USDZ pack;
  not yet consumed by the renderer.
- **refresh-live-status** — hourly cron job. Supports the official Epic terrain
  feed; ambiguous names are omitted, parser failures never overwrite a previous
  blob, manifest/count mismatches fail the refresh. Writes
  `resort-graphs/{resort_id}/live-{YYYY-MM-DDTHH}.json`.
- **send-push** — APNs fan-out for `friend_request`, `friend_added`,
  `meet_request`, `meet_started`, called from AFTER triggers through pg_net.
  Dead tokens (410) are deleted automatically. Setup is in the APNs runbook.

Security advisor exceptions are by design: the seven SECURITY DEFINER client RPCs, the PostGIS `st_estimatedextent` overloads, `postgis` in `public`, and `spatial_ref_sys` without RLS.

## Canonical pipeline

Server-authoritative resort-graph pipeline. Replaces the on-device build chain (`GraphBuilder.buildGraph` → `CuratedResortLoader.applyOverlay` → `ResortDataEnricher.enrich`) with a fetch of an immutable blob built once on the server. Truth lives in Postgres; clients decode and render.

### Determinism contract

1. **Build determinism.** TS and Swift builders use source geometry only, stable component IDs, sorted identity fields, and canonical graph version v15. The preview-only legacy client builder remains separately identified as v15-s3.
2. **Source topology only.** Exact shared source vertex IDs and explicit
   `piste:type=connection` ways create connectivity. Coordinate coincidence,
   visual crossings, and long-edge resolution points never join source ways.
3. **Cross-language fingerprint match.** Output `fingerprint` is `<nodeCount>:<edgeCount>:<hex16>` and MUST match Swift `MountainGraph.computeFingerprint` for the same inputs.
4. **Wire compression.** Server emits raw deflate (`fflate.deflateSync`); client decompresses with `compression_decode_buffer(COMPRESSION_ZLIB)`. NOT gzip-wrapped.
5. **Receiver-side meet determinism.** When an inbound meet stamps a different `manifest_version`, `MeetupSessionController.activateRouteShared` force-fetches that exact manifest via `loadResort(entry, manifestVersionOverride:)` BEFORE solving. Activation requires a canonical dataset, a rendezvous ID in that dataset's validated catalog, and exact all-or-nothing stored paths or a strict exact-start local re-solve.

6. **Ingress integrity.** Blob SHA, compressed/decoded size limits, requested
   resort, advertised v15 fingerprint, node/edge identity, endpoint geometry,
   numeric ranges, and lift queue-entry semantics all validate before a remote
   graph is cached or exposed to routing. Canonical cache envelopes carry and
   re-check the graph fingerprint.

### Client wiring

- `CanonicalGraphFetcher.swift` — cache validation includes content SHA; responses become immutable `MountainDataset` plus optional timestamped `MountainStatus`.
- `MountainRepository.swift` — sole disk-cache owner; retains exact canonical history and separately expires compatibility snapshots.
- `ResortDataManager.swift` — canonical-first and publishes dataset/status separately. The compatibility `currentGraph` is a derived projection; no direct Overpass fallback.
- `MeetRequestService.swift` — requests carry both manifest version and the full `dataset_version` identifier. Null dataset identity is legacy and cannot activate.
- `MeetView.swift` — sender stamps manifest, dataset identity, full paths, ETAs, exact starts, and snapshot date.
- `MeetupSessionController.swift` — receiver force-fetches the sender manifest, verifies the resulting graph-version/content-SHA identity exactly, then validates paths all-or-nothing before activation.

Dataset identifiers round-trip as manifest + graph-version + 64-character
content SHA. Cross-device replay uses all three when present, including
distinguishing two immutable rebuilds under the same manifest. Pre-identity
legacy requests retain manifest-level compatibility but cannot masquerade as an
exact match.

## Operator runbooks

### APNs push setup (one-time)

The push pipeline (`device_tokens` table, `send_push` triggers, `send-push` edge function) is fully deployed. Until the APNs auth key is configured, the function returns 500s; `send_push()` swallows them so writes never fail, but no actual push notifications go out.

1. **Create the APNs Auth Key.** [App Store Connect → Users and Access → Integrations → Keys](https://appstoreconnect.apple.com/access/integrations/api). Click `+`. Pick **Apple Push Notifications service (APNs)**. Confirm. Apple shows the **Key ID** (10 chars) and a one-shot Download.
2. **Download the `.p8` immediately** — Apple won't show it again. Save somewhere outside the repo (the project's `_local/secrets/apns/` is the standard spot).
3. **Note your Team ID** — top-right of any page in [the Apple Developer portal](https://developer.apple.com/account).
4. **Set Supabase secrets:**
   ```sh
   supabase secrets set \
     APNS_AUTH_KEY="$(cat AuthKey_XXXXXXXXXX.p8)" \
     APNS_KEY_ID=XXXXXXXXXX \
     APNS_TEAM_ID=YYYYYYYYYY \
     APNS_BUNDLE_ID=com.powdermeet.PowderMeet \
     APNS_ENVIRONMENT=development
   ```
   `APNS_AUTH_KEY` must include the full PEM body, including the `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----` lines. The shell-quoting `"$(cat …)"` form handles that. Switch `APNS_ENVIRONMENT` to `production` for App Store / TestFlight builds.
5. **Tell Postgres where the function lives:**
   ```sh
   psql "$DATABASE_URL" <<'SQL'
   alter database postgres set app.send_push_url     = 'https://<project-ref>.supabase.co/functions/v1/send-push';
   alter database postgres set app.send_push_anon_key = '<anon-key>';
   SQL
   ```
6. **Deploy with `--no-verify-jwt`:**
   ```sh
   supabase functions deploy send-push --no-verify-jwt
   ```
   `--no-verify-jwt` is required because pg_net's `net.http_post` from triggers runs without an authenticated user context. The function reads the service-role key from its own env separately.
7. **Verify** — send a friend request between two test accounts; tail logs with `supabase functions logs send-push --tail`. Foreground delivery shows the in-app banner; background delivery shows the iOS system banner.

**Troubleshooting:**
- *No pushes after setup* — common: expired JWT (key ID mismatch), wrong bundle id, sandbox vs production mismatch (`APNS_ENVIRONMENT` must match the build's entitlement).
- *`device_tokens lookup failed`* — service-role key not configured on the function.
- *`apns 410` followed by silence* — token retired (uninstalled / wiped); function deletes dead tokens automatically.

### Canonical ingest (per resort)
**Prereqs:**
```sh
cd <PowderMeet repo>/tools
pip install flask  # only needed for the optional geometry authoring UI
export SUPABASE_URL=https://qtzjxquzyrwavhvqarvg.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<service role key>   # never commit; pull via dashboard or the Supabase dashboard
```
**1. Find the resort's bbox + lat/lon.** From `resorts_bbox`:
```sh
psql "$SUPABASE_DB_URL" -c "select id, lat_min, lon_min, lat_max, lon_max from resorts_bbox where id = 'vail';"
```
**2. Establish the canonical identity counts.** Review the resort's current
official map or identity list and decide which unique, named, routable trail and
lift identities the manifest will claim. Once a manifest has any trail row,
every run edge it does not claim is built closed, so unnamed ways that routing
needs must be claimed by a named row; lift exits with no mapped downhill link
stay dead ends (the builder never infers connectors).
**3. Run ingest:**
```sh
CANONICAL_TRAILS=...  # unique identities in the reviewed map/list
CANONICAL_LIFTS=...   # unique routable lift identities in the reviewed map/list
python -m canonical_ingest ingest vail \
  --bbox 39.572,-106.394,39.658,-106.298 \
  --lat-lon 39.605,-106.355 \
  --expected-canonical-trails "$CANONICAL_TRAILS" \
  --expected-canonical-lifts "$CANONICAL_LIFTS" \
  --canonical-counts-reviewed \
  --headline-trails 278 --headline-lifts 32 \
  --evidence-observed-at 2026-08-09 \
  --evidence-url https://www.vail.com/the-mountain/about-the-mountain/mountain-info.aspx \
  --evidence-url https://www.vail.com/the-mountain/about-the-mountain/trail-map.aspx
```
```sh
python -m canonical_ingest ingest vail \
  --offline-fixtures \
  --bbox 39.572,-106.394,39.658,-106.298 \
  --lat-lon 39.605,-106.355 \
  --headline-trails 278 --headline-lifts 32 \
  --evidence-observed-at 2026-08-09 \
  --evidence-url https://www.vail.com/the-mountain/about-the-mountain/mountain-info.aspx \
  --evidence-url https://www.vail.com/the-mountain/about-the-mountain/trail-map.aspx
```
**4. Review the draft:**
```sh
python -m canonical_ingest review vail \
  --report-json /tmp/vail-canonical-review.json
```
**5. Geometry overrides (optional but recommended for top-N resorts):**
```sh
python -m canonical_ingest geometry vail
```
**6. Stage the reviewed manifest (dry-run first):**
```sh
python -m canonical_ingest apply vail --dry-run
python -m canonical_ingest apply vail
```
**7. Build that exact staged manifest:**
Before building, optionally replace the manifest's reviewed landmark overlay.
```sql
select public.replace_canonical_rendezvous_points(
  'vail',
  <manifest_version>,
  '[
    {
      "anchor_osm_node_id": 123456789,
      "kind": "lodge",
      "display_name": "Creekside Lodge",
      "confidence": 1.0,
      "quality": 0.98
    }
  ]'::jsonb
);
```
```sh
export MANIFEST_VERSION=<version returned by apply>
curl -X POST $SUPABASE_URL/functions/v1/build-resort-graph \
  -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"resort_id\":\"vail\",\"manifest_version\":${MANIFEST_VERSION},\"graph_version\":\"v15\"}"
```
Record the returned `snapshot_date` and lowercase `sha256`. A successful build
is staged only; clients see nothing until step 8. Check the `status` field, not
the HTTP code (a missing snapshot returns 200 with `snapshot_pending`). Set
rendezvous points and geometry overrides before the first build: an existing
blob for the same tuple is returned as-is. The function requires a
service-role token and fails closed if the manifest rows cannot be read or do
not match the expected counts.
**8. Publish the exact successful build:**
```sh
export GRAPH_SNAPSHOT_DATE=<snapshot_date returned by build>
export GRAPH_CONTENT_SHA256=<sha256 returned by build>
python -m canonical_ingest publish vail \
  --manifest-version "$MANIFEST_VERSION" \
  --graph-version v15 \
  --snapshot-date "$GRAPH_SNAPSHOT_DATE" \
  --content-sha256 "$GRAPH_CONTENT_SHA256"
```
The RPC revalidates canonical counts/names and the complete graph-blob identity,
then atomically moves the resort's active publication pointer; publishing an
older identity rolls back to it.
**9. Smoke test the client path:**
```sh
# Cache miss → fetch
curl -X POST $SUPABASE_URL/functions/v1/get-resort-graph \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"resort_id":"vail"}'

# Cache valid (after first fetch)
curl -X POST $SUPABASE_URL/functions/v1/get-resort-graph \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"resort_id\":\"vail\",\"cached_manifest_version\":${MANIFEST_VERSION},\"cached_content_sha256\":\"${GRAPH_CONTENT_SHA256}\"}"
```
Expect `{"status":"cache_valid",...}` on the second call.
**Re-applying after reality changes** (resort adds a new lift / fixes a name):
re-run steps 3–9. A changed content hash stages v(N+1), but all clients remain
on the active publication until step 8 publishes the new identity.

### Topsheet artwork import

Bundled top-down ski renders backing the equipment picker. One image set per `skis_catalog` row; resolved at runtime by `HorizontalSkiView` via `topsheet_asset_key`. Slugs are `lowercase-brand-model` with spaces / punctuation collapsed to hyphens (e.g. `atomic-bent-110`, `volkl-m6-mantra`).

**Image specs:** PNG with alpha, 1280×200, ~6.4:1 aspect, transparent outside silhouette, sRGB, 1× scale only.

**To add new topsheets:**
1. Drop licensed PNGs into a working folder, named `<brand-slug>-<model-slug>.png` (e.g. `~/topsheet-source/atomic-bent-110.png`).
2. From the project root: `python3 tools/import_topsheets.py ~/topsheet-source`. Crops/resizes each PNG → writes into `PowderMeet/Resources/SkisTopsheets.xcassets/<key>.imageset/<key>.png` with a generated `Contents.json`. Emits `tools/topsheet_keys.sql` for `topsheet_asset_key` upsert.
3. Apply the SQL via the Supabase SQL editor or `supabase db push`.
4. Build the iOS target.

Rows without a bundled asset fall through to the procedural `BrandStyle` pattern — no code change needed when an image is missing.

## Build + lint

iPhone-only target:

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Private full-day Garmin/Slopes compatibility tests are explicit opt-in audits:
set `POWDERMEET_RUN_PRIVATE_IMPORT_AUDIT=1` on the test action. The ordinary
suite skips both so a private checkout does not silently add many minutes.
Set `POWDERMEET_PRIVATE_DATASET` to an explicit local `CachedMountainDataset`
JSON as well. `ActivityImportCompatibilityTests.offlineWhistlerGraph` checks
the resort and fingerprint, preserves canonical graphs, and only applies
bundled `GraphEnricher` data to legacy snapshots. Do not restore the production
dataset loader here: it can initiate a server snapshot job during a test.
Audit attachments retain dataset identity, reconstructed counts, match tiers,
and resolved labels. These audits prove parse/segmentation/label coverage on
the supplied files, not ground-truth identity accuracy or backend persistence.

```bash
supabase db reset --local --no-seed
supabase test db supabase/tests/database

# Existing production only, after explicit approval:
supabase db push --include-all --dry-run
```

## Testing

- `xcodebuild test -project PowderMeet.xcodeproj -scheme PowderMeet -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` runs the full suite; the two private full-day import audits stay skipped unless the environment variables above are set.
- `PowderMeetTests/Fixtures/GPSLogs/` is a corpus of real Slopes and GPX recordings; `ActivityCorpusParseTests` parses every file, so a new tracker export can be dropped in and covered without code changes.
- Reliability scoring has synthetic scenarios covering fairness, uncertainty, condition-cohort isolation, closures, ability gates, and deterministic selection. Per-resort golden graph fixtures are captured through `RoutingTestSheet` once a resort has a published canonical graph.
- `Views/RealtimeSelftestView.swift` (DEBUG) runs eight invariant checks on the realtime stack; wire new presence-adjacent state through it.

## Validation status

Distribution remains held until the mountains work. Simulator validation now
passes (642 tests, nine opt-in skips). The September 23 owner-scoped activity
migration and `build-resort-graph` hardening are committed but not yet applied
or deployed. See `RELEASE_READINESS.md` for unresolved production routing,
provider coverage, and source-data gaps. The opt-in `CapturedGoToPreviewTests`
audit (`POWDERMEET_ROUTE_AUDIT_DIRECTORY`, optional `POWDERMEET_GO_TO_RESORTS`)
measures how many landmarks Go To can reach on real captured graphs.

- **Whistler Blackcomb** is the only resort with a curated overlay, a rebuilt
  real-data graph, a public-source audit, and golden routing fixtures. The
  other 158 catalog entries carry stub overlays and render previews only.
- A sendable, activatable meet requires a published canonical manifest for the
  resort; the client never falls back to a live Overpass build.
- Live navigation, reroute-on-closure, and the private Garmin/Slopes import
  audits have been verified locally and in the simulator. On-mountain routing
  has not been field-tested this season.
