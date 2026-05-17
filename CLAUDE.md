# PowderMeet — Claude orientation

Ski-meetup iOS app that finds the optimal meeting point between two skiers on a
mountain. "FATMAP merged with Find My" — Mapbox satellite-streets base, stylized
overlays, realtime presence, pathfinding across a directed trail/lift graph.

For setup (secrets, Mapbox token, Supabase schema), see `README.md`.

## Stack

- **iOS:** Swift 6 + SwiftUI, Xcode 16 Synchronized Folders. New `.swift` files
  auto-register; no `.pbxproj` edits needed.
- **Map:** MapboxMaps SDK (satellite-streets-v12 style).
- **Backend:** Supabase — auth, Postgres, Realtime (Broadcast + postgres_changes).
- **On-device cache:** SwiftData (`FriendLocationStore`, `LocationHistoryStore`).
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
PowderMeet/
├── PowderMeetApp.swift           App entry; wires RootView + SupabaseManager
│                                 + ResortDataManager + ActivityImportSession;
│                                 observes auth + scenePhase
├── ContentView.swift             Scaffold: 3 tabs + header + resort bar
│                                 + offline-banner + sheets (pure routing)
├── ContentCoordinator.swift      @MainActor @Observable lifecycle owner:
│                                 resort/conditions/realtime/presence/
│                                 meetup-session. Owns FriendService,
│                                 LocationManager, MeetRequestService,
│                                 LocationHistoryStore, FriendQualityStore,
│                                 MapBridge. ensureRealtimeLocationService
│                                 passes try? FriendLocationStore() as
│                                 persistentStore so cold launch picks up
│                                 last-known friend dots before realtime
│                                 hydrates.
├── MeetupSessionController.swift  Owns meetup-session lifecycle + the four
│                                 navigation services (NavigationDirector,
│                                 NavigationViewModel, RouteChoreographer,
│                                 BlendedETAEstimator). Receiver path also
│                                 force-fetches sender's manifest_version
│                                 before solving (canonical-pipeline
│                                 determinism).
├── RealtimeBootstrapper.swift    Lazy-constructs RealtimeLocationService +
│                                 PresenceCoordinator; lifted from
│                                 ContentCoordinator for clarity.
├── Algorithm/
│   ├── BinaryHeap.swift              Generic min-heap for Dijkstra
│   ├── ConditionsFingerprint.swift   Bucket weather/conditions for solver caching
│   ├── MeetingPointSolver.swift      Dijkstra variants; α wait penalty;
│   │                                 static solutionCache keyed by
│   │                                 graphFingerprint + per-skier
│   │                                 edgeSpeedHistoryFingerprint. Per-skier
│   │                                 edgeSpeedHistoryByProfile dict.
│   │                                 makeContext(for:) is the public façade —
│   │                                 every external caller (route narrative,
│   │                                 reason builder) MUST use it; never hand-
│   │                                 roll a TraversalContext. Skill-gated
│   │                                 failure: relaxed-Dijkstra retry sets
│   │                                 lastFailureReason = .skillGatedPath.
│   │                                 MeetingResult.solveAttempt stamps which
│   │                                 fallback tier produced the route.
│   ├── RouteInstructions.swift       Turn-by-turn narrative from a route
│   ├── RouteProjection.swift         Time→position interpolation on a route
│   ├── SolverConstants.swift         Tunables: tolerances, α, scoring weights
│   └── SunExposureCalculator.swift   Sun angle × slope aspect shading
├── Models/
│   ├── ActiveMeetSession.swift           Live-meetup state + RouteTracker
│   ├── ActivityModels.swift              Codable structures for activity import
│   ├── BrandStyle.swift                  Render-style enums for procedural ski art
│   ├── ImportedRunRecord.swift           SwiftData model for imported runs
│   ├── MountainGraph.swift               Nodes/edges; representativeEdge;
│   │                                     precomputed fingerprint; atTime
│   ├── MountainGraph+NetworkGeometry.swift   Network-geometry extensions
│   ├── MountainGraph+ResortStats.swift       Resort-wide stats computation
│   ├── MountainGraph+RunTrailGroups.swift     Trail clustering extensions
│   ├── MountainNaming.swift              Single source of truth for node/edge
│   │                                     labels (canonical / withChainPosition
│   │                                     / bareName). Every consumer (picker,
│   │                                     profile HUD, friend cards, route
│   │                                     steps, map POIs) goes through it.
│   ├── PerEdgeSpeed.swift                Per-edge rolling speed observation
│   ├── PowderMeetExport.swift            .powdermeet backup envelope schema
│   ├── ProfileStats.swift                Aggregated stats (runs/days/vertical/topSpeed)
│   ├── Resort.swift                      Resort + BoundingBox value types
│   ├── ResortCatalog.swift               Per-resort bbox, defaultZoom, passProducts
│   ├── ResortConditions.swift            Weather bundle + hourly lookup
│   ├── SkiCatalogEntry.swift             skis_catalog row decode
│   ├── TrailChainGeometry.swift          Geometric chain ordering for trail polylines
│   └── UserProfile.swift                 Profile + skill-level + traverseTime model
├── Services/
│   ├── ActivityImporter.swift            GPX/TCX/FIT/Slopes/.powdermeet →
│   │                                     MatchedRun → imported_runs +
│   │                                     recompute RPCs. Loads + curates the
│   │                                     matching graph BEFORE persisting so
│   │                                     MountainNaming resolves canonical
│   │                                     trail names (no "Imported Run").
│   ├── ActivityImportSession.swift       In-flight import progress (survives
│   │                                     tab switches via app-scope state)
│   ├── CanonicalGraphFetcher.swift       Server-built canonical graphs behind
│   │                                     feature flag. Auto-builds on
│   │                                     not_built; fall through to legacy
│   │                                     pipeline on fetch error.
│   ├── ChannelRegistry.swift             actor; ref-counted RealtimeChannelV2 owner
│   ├── ConditionsService.swift           Weather API + hourly history
│   ├── ContactsService.swift             Contacts framework — friend-discovery
│   ├── CuratedResortData.swift           Bundled resort JSON + slope caches +
│   │                                     overlay (drift target — see Future work)
│   ├── ElevationService.swift            DEM elevation lookups via Mapbox
│   ├── EpicTerrainScraper.swift          Vail/Epic terrain ingestion (open/closed)
│   ├── FITParser.swift                   FIT format (Garmin) parser
│   ├── FriendLocationStore.swift         SwiftData last-known friend cache
│   ├── FriendService.swift               friends:{id} channel (postgres_changes
│   │                                     on `friendships`); social-snapshot
│   │                                     hydrate; block + cancel paths
│   ├── GPXParser.swift                   GPX format parser
│   ├── GraphBuilder.swift                OSM + SlopeCache → MountainGraph
│   │                                     (legacy on-device pipeline; canonical
│   │                                     pipeline replaces this server-side)
│   ├── GraphCacheManager.swift           On-disk graph cache (Documents/resorts/)
│   ├── GraphDiagnostics.swift            Graph validation + debugging
│   ├── GraphEnricher.swift               Enrich graph with run/lift counts +
│   │                                     curated data (bypassed for canonical
│   │                                     blobs — they ship overlay-applied)
│   ├── HealthKitImporter.swift           Apple Health workout importer
│   ├── LiftieService.swift               Liftie API for live lift status
│   ├── LiveRunRecorder.swift             Passive on-device run detection.
│   │                                     Sliding-window classifier; persists
│   │                                     imported_runs row with source = .live;
│   │                                     debounces recompute_profile_edge_speeds.
│   │                                     Gated by profiles.live_recording_enabled.
│   ├── LocationHistoryStore.swift        SwiftData location-history timeline
│   ├── LocationManager.swift             CoreLocation; always-auth; onFirstFix;
│   │                                     bg session; battery-throttle profiles
│   │                                     (low-power + thermal state).
│   ├── MeetRequestService.swift          meets:{id} channel (postgres_changes
│   │                                     on `meet_requests`); 8 s send timeout;
│   │                                     stamps manifest_version on send.
│   ├── MtnPowderService.swift            MtnPowder API for resort live status
│   ├── OverpassService.swift             Overpass OSM client (legacy fallback)
│   ├── PresenceCoordinator.swift         State machine: hydrate social →
│   │                                     subscribe → live. Gates broadcasts
│   │                                     on phase == .live.
│   ├── Reachability.swift                NWPathMonitor wrapper. Drives offline
│   │                                     banner + force-broadcast on reconnect.
│   ├── RealtimeLocationService.swift     Broadcast pos on pos:cell:{geohash6}
│   │                                     plus resort-wide pos:resort:{resortId};
│   │                                     REST hydrates `live_presence`;
│   │                                     monotonic guard.
│   ├── ResortDataEnricher.swift          Background enrichment (run/lift counts)
│   │                                     after legacy graph load
│   ├── ResortDataManager.swift           Loads + caches graphs (in-memory + disk).
│   │                                     Canonical branch when isEnabled(for:);
│   │                                     drives snapshot pipeline for legacy.
│   ├── RouteProgressTracker.swift        Live-meetup route state: advanced /
│   │                                     skipped / completed / deviated events
│   ├── SlopesMetadata.swift              Slopes-app data structures
│   ├── SlopesParser.swift                .slopes file parser
│   ├── SupabaseManager.swift             .shared singleton; auth/profile/stats
│   │                                     wrappers; sessionGeneration counter
│   │                                     for stale-teardown; currentEdgeSpeeds
│   │                                     dict (per-edge skill memory).
│   ├── TCXParser.swift                   TCX format (Garmin) parser
│   ├── TrailMatcher.swift                Sliding-window trail classification
│   ├── ZipReader.swift                   ZIP extraction for archives
│   ├── Choreography/
│   │   ├── AnimationTimeline.swift       at(.ms(x), "tag") { … } builder
│   │   ├── AudioService.swift            arrival_bell.caf playback
│   │   ├── HapticService.swift           CHHapticEngine wrapper
│   │   └── RouteChoreographer.swift      DSL-driven route-reveal sequence
│   └── Notifications/
│       └── Notify.swift                  Local + APNs surface; deep-link tap
│                                         router; ensureAuthorized prompt.
├── Map/
│   ├── CinemaDirector.swift              Resort-intro choreography + viewport idle.
│   │                                     Active-meetup viewport transitions
│   │                                     intentionally absent — see Camera framing.
│   ├── FriendChipLayoutEngine.swift      Layout for friend position chips
│   ├── GeoJSONBuilder.swift              Pure fn: graph + state → GeoJSON dicts.
│   │                                     Lifts emit [lon,lat,elev] sea-referenced
│   │                                     so Peak-to-Peak gondolas float over valleys.
│   │                                     Stamps signal/diskOpacity/signalLabel
│   │                                     on friend features for stale-state
│   │                                     visual differentiation.
│   ├── MapboxOfflineCache.swift          OfflineManager + TileStore v11
│   │                                     wrapper. On resort change, prewarms
│   │                                     satellite tiles for the bbox at
│   │                                     zoom 10–16; idempotent in-session.
│   ├── MapLayerState.swift               Hashable layer-state structs
│   │                                     (MapTrailLayerState / MapFriendLayerState
│   │                                     / MapRouteLayerState). Compiler-enforced
│   │                                     diff gating.
│   ├── MountainMapView.swift             UIViewRepresentable wrapping
│   │                                     MapboxMaps.MapView. Coordinator owns
│   │                                     map state; updateDataLayers is the
│   │                                     SINGLE source-update entry point
│   │                                     (struct-gated per source — don't bypass).
│   │                                     onMapLoadingError → retry ladder;
│   │                                     exhaust → MapBridge.styleLoadFailed
│   │                                     → ResortMapScreen renders overlay.
│   ├── MountainMapView+Animations.swift  Pulse / route reveal / arrival bloom /
│   │                                     snowfall particles
│   └── MountainMapView+Style.swift       Mapbox layer registration + paint;
│                                         friend-dot styling (cold dots
│                                         desaturate to gray, "LOST SIGNAL"
│                                         pill past 10 min stale).
├── Navigation/
│   ├── ETAEstimator.swift                Protocol + BlendedETAEstimator
│   ├── FriendSignalClassifier.swift      live / stale / cold from capturedAt;
│   │                                     FriendQualityStore ticks every 30 s
│   ├── ManeuverIconResolver.swift        SF Symbol for next-maneuver row
│   ├── NavigationDirector.swift          Orchestrates CinemaDirector + Choreographer
│   └── NavigationViewModel.swift         @Observable: maneuver + ETA + signal for HUD
├── Views/                                (top-level + subdirs)
│   ├── BlockedUsersSheet.swift           Manage blocked users
│   ├── CompactRouteSummary.swift         Top bar during active meetup
│   ├── DeleteAccountSheet.swift          Typed-confirm account deletion
│   ├── EdgeInfoCard.swift                Bottom card: trail/edge + conditions
│   ├── FriendDistanceBar.swift           Horizontal friend-distance strip
│   │                                     (replaced FriendOffscreenIndicator)
│   ├── FriendsSheet.swift                Friends list + search + pending requests
│   ├── ImportedRunsView.swift            "LOGS" full-screen viewer; brand-colored
│   │                                     source pill (HEALTH=Apple red,
│   │                                     STRAVA/GPX=orange, GARMIN/TCX/FIT=teal,
│   │                                     SLOPES=blue, POWDERMEET=accent, LIVE=amber)
│   ├── MapView.swift                     ResortMapScreen (wraps MountainMapView)
│   ├── MeetView.swift                    Five-section compositor + solver
│   │                                     orchestration + send-meet-request flow
│   ├── ProfileTabContents.swift          Account · Activity tab contents
│   │                                     (VIEW LOGS / CONNECT HEALTH /
│   │                                     IMPORT FILE / LIVE RECORDING)
│   ├── ProfileView.swift                 Avatar + name + skill, stats grid,
│   │                                     Friends row, Settings row
│   ├── RealtimeSelftestView.swift        DEBUG: 8 invariant checks
│   ├── ResortPickerSheet.swift           Resort switcher; "AT YOUR LOCATION"
│   │                                     section when bbox-detect ambiguous;
│   │                                     COMING SOON tail
│   ├── RootView.swift                    Auth ⇄ Content gate
│   ├── RouteCard.swift                   Meeting-result card; PREVIEW pill
│   │                                     when solveAttempt != .live
│   ├── RoutingTestSheet.swift            DEV: pick a node as "live location";
│   │                                     EXPORT GRAPH FIXTURE button
│   ├── SentRequestsSheet.swift           Outgoing friend requests
│   ├── SplashView.swift                  Launch placeholder
│   ├── TimelineView.swift                Day scrubber (sun/forecast)
│   ├── Auth/                             Email + Sign in with Apple, sign-up,
│   │                                     reset. Apple flow: raw nonce → Apple,
│   │                                     SHA-256(nonce) → Supabase via
│   │                                     signInWithIdToken (CryptoHelpers).
│   ├── Components/
│   │   ├── ActivityImportRows.swift      ConnectAppleHealthRow,
│   │   │                                 ImportActivityFileRow, ViewLogsRow.
│   │   │                                 ViewLogsRow renders "UPLOADING · 3/10"
│   │   │                                 from ActivityImportSession; fixed-frame
│   │   │                                 columns so the row doesn't reflow.
│   │   ├── HUDDoneButton.swift           Reusable Done/close button
│   │   ├── HUDSecureField.swift          Password input
│   │   ├── HUDSectionHeader.swift        Section header styling
│   │   ├── SkiPairView.swift             Ski/snowboard pair display
│   │   ├── SkiPickerSheet.swift          Equipment picker
│   │   └── SkillLevelPicker.swift        4-pill picker (GRN/BLU/BLK/2BLK)
│   ├── Onboarding/                       4-step flow: Profile → Contacts →
│   │                                     Location → Notifications. Notifications
│   │                                     step blocks CONTINUE until iOS records
│   │                                     a permission answer.
│   └── Meet/                             Sectioned compositor + card primitives:
│                                         IncomingMeetRequestsSection (raises
│                                         "DIFFERENT RESORT" confirm before
│                                         accept when request.resortId differs),
│                                         PendingFriendRequestsSection,
│                                         MeetingOptionsSection (paging +
│                                         show-route; first card "TOP MATCH"),
│                                         FriendsListSection,
│                                         PowderMeetActionButton (with retry
│                                         banner on send failure).
│                                         Plus: ActiveMeetupCardView,
│                                         FriendRowView, FriendSearchSheet,
│                                         IncomingMeetRequestCard,
│                                         LiveFriendsDrawer, MeetFlow,
│                                         MeetingOptionCardView (renders
│                                         amber pill for non-.live solveAttempt),
│                                         MeetPrefetcher,
│                                         MeetSolver (3-tier fallback: live →
│                                         forced-open → neighbor-substitution),
│                                         PendingRequestCard,
│                                         RouteStepConsolidator.
├── Theme/HUDTheme.swift                  Color tokens, spinner tints, route palette
├── Utils/Geohash.swift                   Pure Swift geohash encode + 9-cell neighbors
├── Utilities/                            AppLog, BuildEnvironment, CryptoHelpers,
│                                         Debouncer, ISO8601Parser, PhoneNormalizer,
│                                         UIColor+Hex, UnitFormatter
├── Resources/
│   ├── Models/                           .glb hero meshes (source TBD)
│   ├── ResortData/                       Baked resort JSON + slope caches
│   ├── SkisTopsheets.xcassets/           Licensed top-down ski renders. One
│   │                                     image set per skis_catalog row;
│   │                                     name = topsheet_asset_key. Resolved
│   │                                     by HorizontalSkiView. PNG with alpha,
│   │                                     1280×200, sRGB, transparent outside
│   │                                     silhouette. Add via
│   │                                     `python3 tools/import_topsheets.py
│   │                                     <source-folder>` (see Operator
│   │                                     runbooks). Rows without a bundled
│   │                                     asset fall through to BrandStyle.
│   └── Sounds/arrival_bell.caf
├── PowderMeet.entitlements               aps-environment, applesignin, healthkit
└── Info.plist                            BG modes (location, remote-notification),
                                          location/contacts/camera/health usage
                                          descriptions, com.powdermeet.backup UTI

PowderMeetTests/                          11 test files: MountainGraph,
                                          MeetFlow, MeetPrefetcher, MapLayerState,
                                          ConditionsFingerprint, Geohash,
                                          Haversine, BoundingBox, ISO8601Parser,
                                          PhoneNormalizer, Smoke. Fixtures
                                          directory pending (golden graphs).

supabase/
├── migrations/                           43 .sql files; apply via `supabase db push`
└── functions/
    ├── _shared/                          graph_builder.ts + curated_overlay.ts
    │                                     + graph_types.ts + types.ts (TS ports
    │                                     of Swift services for build-resort-graph)
    ├── snapshot-resort/                  Chunked OSM + elevation builder
    ├── build-resort-graph/               Server canonical graph builder
    ├── get-resort-graph/                 Client-side cache-validate + fetch
    ├── refresh-live-status/              Hourly cron sidecar with vendor live status
    └── send-push/                        APNs fan-out for peer events

tools/
├── canonical_ingest/                     Python package: source-fuse Skimap +
│                                         OpenSkiMap + Overpass + official into
│                                         a draft manifest, reconcile counts,
│                                         apply via apply_canonical_manifest RPC.
│                                         CLI: `python -m canonical_ingest
│                                         {ingest|review|apply|geometry} <id>`.
│                                         See "Operator runbooks → Canonical
│                                         ingest" below.
├── import_topsheets.py                   One-shot: licensed PNGs → 1280×200
│                                         imageset under SkisTopsheets.xcassets +
│                                         topsheet_keys.sql for catalog upsert.
│                                         See "Operator runbooks → Topsheet import".
├── scrape_topsheets.py                   Topsheet sourcing pipeline: rembg + de-pair
│                                         + crop to 1280×200. Modes: --from-urls
│                                         (operator-curated TSV) or DDG search
│                                         (heavily rate-limited). Most production
│                                         sourcing uses curl + powder7.com URL
│                                         pattern + this script's --reprocess.
├── playwright_topsheets.py               Headless-browser variant for sites with
│                                         bot protection (Atomic, Salomon, evo —
│                                         all PerimeterX). Stealthed Chromium +
│                                         DDG-Lite/Bing fallback search. Mostly
│                                         superseded by per-brand curl scripts.
├── topsheets                             Short bash wrapper around playwright_topsheets.
├── topsheet_urls.tsv                     Operator-curated <slug><TAB><url> for
│                                         scrape_topsheets --from-urls path.
├── topsheet_keys.sql                     Generated by import_topsheets — upsert
│                                         topsheet_asset_key on skis_catalog.
└── prewarm_snapshots.py                  Pre-bake pinned resort snapshots via
                                          snapshot-resort. Reads ResortCatalog.swift
                                          for the 159 entries; idempotent.

scripts/
└── deploy-build-resort-graph.sh          Stages _shared/*.ts into the function
                                          directory, deploys, restores layout.
                                          Requires SUPABASE_ACCESS_TOKEN.

ci_scripts/
└── ci_post_clone.sh                      Xcode Cloud post-clone: writes
                                          ~/.netrc with MAPBOX_DOWNLOADS_TOKEN
                                          (Shared Env Var) so SPM resolves
                                          MapboxMaps.

_local/                                   ⚠️ Gitignored umbrella for files that
                                          never enter the repo:
                                          ├── media/      demo videos / screenshots
                                          ├── secrets/    APNs .p8 keys
                                          └── gps-logs/   personal GPX/Slopes
                                                          test data
                                          Single ignore rule (`_local/`) in
                                          .gitignore so contributors only
                                          remember one.

Secrets.xcconfig                          Committed. SUPABASE_URL +
                                          SUPABASE_ANON_KEY + MAPBOX_ACCESS_TOKEN
                                          (all client-public). The truly-secret
                                          MAPBOX_DOWNLOADS_TOKEN lives in
                                          ~/.netrc + Xcode Cloud env, never here.
Secrets.xcconfig.example                  Template for fresh clones.
```

## Key architectural invariants (do NOT break)

- **Deterministic graph:** two devices at the same resort must build identical
  graphs. Phantom-trail closure is server-whitelisted; no local closure.
- **Solver cache:** `MeetingPointSolver.solutionCache` is static, keyed with
  `graphFingerprint`. Don't key without the fingerprint — stale graphs collide.
- **Per-skier solver context:** the 2-skier `solve(...)` builds TWO
  `TraversalContext`s — one per skier — via `buildContext(for: skier.id.uuidString)`
  so each skier's `traverseTime` reads their own `edgeSpeedHistory` slot
  in `solver.edgeSpeedHistoryByProfile`. Don't fall back to a single
  shared context — that's how the local user's per-edge calibration
  used to bleed into the friend's predicted edge times. Single-skier
  callers (LiveRunRecorder, RoutingTestSheet) can still set
  `solver.edgeSpeedHistory` directly; per-profile dict takes priority.
- **Canonical TraversalContext:** anything outside the solver that needs
  one (route narrative, route-reason copy, ETA recompute) MUST go through
  `solver.makeContext(for: skierID)` — never construct a `TraversalContext`
  by hand. Hand-rolled contexts diverge from the solver's quantization
  (15-min `solveTime` bucket, cloud cover ÷10, etc.) and ignore per-skier
  history, so the narrative drifts from the solve.
- **Honest fallback labeling:** when `MeetView.solveMeeting` falls back
  to Attempt 2 (force all edges open) or Attempt 3 (neighbor-node
  substitution), it stamps `result.solveAttempt = .forcedOpen` /
  `.neighborSubstitution`. `RouteCard` renders an amber PREVIEW pill for
  anything other than `.live`. Don't drop the stamp — the user needs to
  know the route may pass through closed terrain.
- **One source-update path:** `Coordinator.updateDataLayers` in
  `MountainMapView` is hash-gated per source. Don't push source data anywhere
  else or the diff optimization regresses.
- **Realtime channels:** position uses Broadcast on `pos:cell:{geohash6}` and
  `pos:resort:{resortId}` (cross-cell friends); friends use `friends:{id}`
  (`postgres_changes` on `friendships`); meet requests use `meets:{id}`
  (`postgres_changes` on `meet_requests`). All go through `ChannelRegistry`
  (actor, ref-counted). Don't open a `RealtimeChannelV2` directly outside the
  registry. **DB:** `friendships` and `meet_requests` must be in the
  `supabase_realtime` publication or those `postgres_changes` streams never
  replicate (verify with `pg_publication_tables` in SQL).
- **Social snapshot gate:** `FriendService.socialGeneration` stays `0` until
  `loadSocialSnapshot` applies once. `RealtimeLocationService` rejects inbound
  position broadcasts while `socialGeneration == 0` so friend filtering never
  runs against an empty friend set during cold launch (“accept everyone”
  window). `PresenceCoordinator` sequences snapshot hydrate, channel subscribe,
  and `broadcastNow` so sends don’t race ahead of wiring.
- **Camera framing:** resort intro lands on `entry.preferredZoom ??
  entry.defaultZoom`, `entry.preferredBearing ?? 0`, `entry.preferredPitch
  ?? 62`. `defaultZoom` is computed from the bounding-box span in
  `ResortCatalog.swift`; per-resort overrides exist on the catalog entry
  for resorts whose default isn't framed well. Two camera setup sites:
  `MountainMapView.updateUIView` (resort change) and `initialCamera()`
  (first construction). Keep them in sync.
  **No camera move on PowderMeet accept.** Eight prior fix attempts at
  framing-routes-then-follow-puck all kept landing the camera on a stale
  Mapbox internal location subject ("middle of nowhere"). The current policy
  is: route lines animate in place, the meeting pin pulses, the user pans
  themselves. Cross-resort accepts still play the resort intro because
  otherwise the tiles swap out from under a camera pointing at the old
  resort. Don't reintroduce `enterOverview` / `enterActiveMeetup` /
  `frameRoutesForMeetupOverview` without a complete different model for
  the location subject.
- **Stale-teardown guard:** `ContentCoordinator.teardown()` (called from
  `ContentView.onDisappear`) reads `SupabaseManager.shared.sessionGeneration`
  before tearing down realtime services — if a new session has already
  started, skip the teardown so we don't reset the new session's
  freshly-built channels.
- **Sender-stamped timestamps:** `FriendLocation.capturedAt` is set by the
  sender. Receiver drops payloads with `capturedAt <= stored.capturedAt`.
- **No RLS clauses that read the caller's own row in the same table.**
  Production-bitten: an audit pass added a resort-scoped clause to
  `live_presence_friend_read` (`AND live_presence.resort_id = (caller's
  own live_presence.resort_id)`). It silently rejected friend rows
  whenever the viewer's own row was missing, stale, or not-yet-matching
  — cold launch before first GPS fix, between resorts, friend-just-
  changed-resorts, subscribe-before-first-broadcast — and `postgres_changes`
  events flow through RLS, so realtime stopped arriving for any pair not
  perfectly synchronized. Reverted in
  `supabase/migrations/20260426_revert_resort_scoped_live_presence_rls.sql`.
  Cross-resort isolation belongs in the client (which can react to its
  own session state) or in a column the broadcaster sets at write time
  — never in an RLS predicate that re-reads the caller's row.

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

**Why it exists.** Before the coordinator, three lifecycles ran
concurrently — `loadSocialSnapshot`, `RealtimeLocationService.start`,
and `broadcastNow` (fired by `LocationManager.onFirstFix` and the 5 s
heartbeat). If a position broadcast went out before the social snapshot
had been applied on the *receiving* side, the receiver's
`friendIdsProvider` closed over an empty friend set and accepted
anyone in cell. That's the "accept-everyone-during-cold-launch" trap.

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

**Stop ordering.**
- `PresenceCoordinator.stop()` is synchronous — used for rapid
  resort-clears (`ContentCoordinator.handleSelectedEntryChange` when
  the new entry is nil). Underlying channel release runs off-main; a
  follow-on `enter()` will wait via its own teardown.
- `PresenceCoordinator.stopAndWait()` is `async` — used by
  `RealtimeBootstrapper.teardown()` on sign-out / account deletion.
  Awaits both `RealtimeLocationService.waitForStop()` and the
  cancelled enter pipeline before clearing state, so a fast
  re-sign-in can't overlap the old session's channels with the new
  session's.
- `ContentCoordinator.teardown()` orders the awaits: realtime channels
  released first (so position broadcasts can't outlive sign-out),
  then `friendService.stopRealtimeSubscription`, then
  `meetRequestService.reset`, then in-memory caches. Reversing this
  order let postgres_changes events repopulate caches after the
  reset — fixed before, asserted by the order in code now.

**Diagnostics.** `Views/RealtimeSelftestView.swift` (DEBUG only) runs
8 invariant checks on the realtime stack — wire any new presence-
adjacent state through it where a regression would otherwise be silent.

## Backend — Postgres + edge functions + cron

Everything CLAUDE references is in `supabase/`. There are 43 migrations
and 5 edge functions. The state below was reconciled against the
actual files, not just memory.

### Tables

| Table | Purpose |
|---|---|
| `profiles` | one row per user; `display_name`, `skill_level`, `live_recording_enabled`, preset speeds (`speed_green`/`speed_blue`/`speed_black`/`speed_double_black`/`speed_terrain_park`), avatar URL |
| `friendships` | accepted + pending friend edges; in `supabase_realtime` publication |
| `meet_requests` | per-meet state (sender, receiver, resort, meeting_node, etas, `manifest_version`, `graph_snapshot_date`); status pending/accepted/declined/expired; in publication; CASCADE on account-deletion |
| `live_presence` | TTL'd last-known position (sender_stamped `captured_at`); BEFORE trigger overwrites client-supplied resort_id with server-derived `resolve_resort_id(lat, lon)`; pg_cron sweeps rows older than 15 min every 5 min; in publication |
| `resorts_bbox` | 159-row reference table seeded from `ResortCatalog.swift`; backs `resolve_resort_id` |
| `resort_snapshot_pins` | server-driven snapshot pin per resort (or `__catalog__` row for global); public read RLS |
| `imported_runs` | every imported run from any source (`source` column: slopes/gpx/tcx/fit/health/strava/garmin/live/powdermeet); columns: edge_id, difficulty (both nullable since 20260428), trail_name, distance_m, max_grade_deg, peak_speed_ms, source_file_hash for dedup |
| `profile_stats` | aggregated rollup per profile (runs/days/vertical/topSpeed/distance_m/max_grade_deg/avg_speed_ms) |
| `profile_edge_speeds` | (profile_id, resort_id, edge_id, conditions_fp) → rolling speed cache. `recompute_profile_edge_speeds` rebuilds from `imported_runs` with **60-day half-life exponential decay** + Welford-style variance (`rolling_speed_variance_ms2`). Friend-readable via `profile_edge_speeds_friend_read` (accepted friendship + not blocked) |
| `device_tokens` | (profile_id, token, environment) for APNs fan-out; owner-only RLS |
| `user_blocks` | bidirectional block list. RLS on `friendships` / `live_presence` / `profile_edge_speeds` excludes both directions |
| `skis_catalog` | searchable ski brand/model picker (Profile → Activity → CALIBRATION). `topsheet_asset_key` references bundled images |
| `resort_canonical_manifest` | canonical pipeline: one row per `(resort_id, manifest_version)`; expected counts; validator notes (carries content_hash for no-op detection) |
| `canonical_trail` | manifest-scoped trail rows with optional canonical geometry overrides |
| `canonical_lift` | manifest-scoped lift rows with optional canonical geometry overrides |
| `canonical_geometry_override` | append-only hand-traced geometry; survives manifest-version bumps |
| `resort_graph_blob` | immutable graph build outputs keyed by `(resort_id, manifest_version, snapshot_date, graph_version)`; `sha256` for client integrity check |

### Views

- `current_resort_canonical_manifest` — latest applied manifest_version per resort

### RPCs (selected)

- `get_social_snapshot(resort_id)` — atomic friends + pending + presence snapshot with monotonic generation stamp; sequenced by `social_snapshot_gen_seq`
- `find_users_by_emails(text[])` / `find_users_by_phones(text[])` — contact-suggestion lookups
- `send_friend_request(addressee_id)` — atomic check + insert; prevents race-window duplicates
- `recompute_profile_stats(uid)` / `recompute_profile_edge_speeds(uid)` — rebuild aggregates from `imported_runs`
- `expire_stale_meet_requests()` — driven by pg_cron every 2 min
- `resolve_resort_id(lat, lon)` — bbox lookup (used by `live_presence` trigger)
- `apply_canonical_manifest(resort_id, expected_trail_count, expected_lift_count, validator_notes, trails JSONB, lifts JSONB)` — service-role only; atomic single-transaction manifest + trails + lifts insert; no-op if content_hash unchanged
- `canonical_trails_with_geom()` / `canonical_lifts_with_geom()` / `latest_geometry_overrides()` — server-side GeoJSON wire-format helpers consumed by build-resort-graph

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
| `refresh_live_status_hourly` | `5 * * * *` | POST → `refresh-live-status` edge function via `pg_net.http_post`; needs `app.send_push_anon_key` (set in DB config) |

### Edge functions

#### snapshot-resort
Chunked-elevation builder. Stage 0 fetches Overpass + writes a checkpoint blob; each subsequent invocation processes ~1200 elevation coords. Big resorts (Vail / Whistler / Palisades) cold-build across ~5 round-trips. Client (`ResortDataManager.driveSnapshotPipeline`) loops on `status: "elevation_pending"`. Returns signed URLs valid 1 h. Deploy: `supabase functions deploy snapshot-resort`.

#### build-resort-graph
Server-side canonical graph builder. Joins OSM blob + elevation blob (from snapshot-resort) to canonical manifest (`canonical_trail`, `canonical_lift`, `canonical_geometry_override`) to produce a deterministic, immutable graph blob keyed by `(resort_id, manifest_version, snapshot_date, graph_version)`. TS port of Swift `GraphBuilder` + `applyOverlay`; iteration order is sorted-Map (stronger than the Swift `Dictionary` original). Output fingerprint `<nodeCount>:<edgeCount>:<hex16>` MUST match Swift's `MountainGraph.computeFingerprint`. Compression: raw deflate (`fflate.deflateSync`); client decodes with `compression_decode_buffer(COMPRESSION_ZLIB)` — NOT gzip-wrapped. Deploy: `scripts/deploy-build-resort-graph.sh` (stages _shared/*.ts; restores afterward).

#### get-resort-graph
Client-side fetch endpoint. Decision tree: `cache_valid` (cached version matches; only refresh live-status URL) / `fetch` (download new blob via signed URL) / `not_built` (manifest exists but no blob — caller drives a build via `build-resort-graph`). Cache lasts indefinitely between manifest_version bumps; when an operator bumps manifest, all clients pick up the new blob on next foreground.

#### refresh-live-status
Hourly cron-driven job. Pulls live lift/trail status from Epic / MtnPowder / Liftie (Liftie 403's via Cloudflare for server IPs — best-effort). Writes per-resort sidecar at `resort-graphs/{resort_id}/live-{YYYY-MM-DDTHH}.json`. Sidecar exists separate from structural blob so the immutable graph doesn't need hourly rebuild. Client merge: structural defaults open; sidecar flips closed + stamps wait minutes.

#### send-push
APNs fan-out for four peer events: `friend_request`, `friend_added`, `meet_request`, `meet_started`. Called by AFTER triggers on `friendships` + `meet_requests` via `pg_net.http_post`. Looks up recipient `device_tokens`, signs JWT with APNs auth key, POSTs to APNs HTTP/2 per token. Deletes dead tokens (`410`) automatically. Foreground delivery: `Notify.swift`'s `UNUserNotificationCenterDelegate` intercepts and renders an in-app banner. Tap → deep-link → ContentView switches to the right tab. Setup is in **Operator runbooks → APNs setup** below.

### Security advisor — intentional exceptions

Big sweep landed in `20260504_security_definer_lockdown.sql` (revoked anon/authenticated EXECUTE on 11 trigger / cron / internal functions) and `20260504_function_search_path_pin.sql`. Remaining flagged items are by-design or structural:

- **7 SECURITY DEFINER functions still flagged client-callable** — `delete_user_account`, `find_users_by_emails`, `find_users_by_phones`, `is_display_name_taken`, `recompute_profile_edge_speeds`, `recompute_profile_stats`, `send_friend_request`. All genuine client RPCs; advisor warns by design.
- **3 PostGIS `st_estimatedextent` overloads** — extension functions, not ours to fix.
- **`postgis` extension in `public` schema** — moving it would require requalifying every PostGIS call site. Defer.
- **`spatial_ref_sys` RLS** — PostGIS reference table without RLS; cosmetic.

## Canonical pipeline

Server-authoritative resort-graph pipeline. Replaces the on-device build chain (`GraphBuilder.buildGraph` → `CuratedResortLoader.applyOverlay` → `ResortDataEnricher.enrich`) with a fetch of an immutable blob built once on the server. Truth lives in Postgres; clients decode and render.

### State of play

- **Backend deployed** in Supabase project `qtzjxquzyrwavhvqarvg`: 5 tables, 1 view, 4 RPCs (above), `resort-graphs` Storage bucket, 3 edge functions (`build-resort-graph`, `get-resort-graph`, `refresh-live-status` — all real impls, not skeletons), `meet_requests.manifest_version` column, `refresh_live_status_hourly` pg_cron job.
- **Client wired** behind `CanonicalGraphFetcher.shared.useCanonicalGraphFetch` (default off) + per-resort autodiscovery (`enabledResortIds`, populated from `current_resort_canonical_manifest` at cold launch — every resort with an applied manifest auto-flips on).
- **End-to-end verified** on Vail: build_time 4.4 s, 770 nodes / 1452 edges (1003 runs, 30 lifts, 419 traverses), 994/1003 named runs, real lift names. 148 KB compressed → 1.33 MB JSON (9× compression). Raw-deflate decode round-trips cleanly. `get-resort-graph` cache_valid + fetch transitions verified.
- **What's left** — see Future work → "Routing / graph — operator-driven canonical rollout" below: ingest top 5 manifests, two-device determinism verify, ingest top 25, then cleanup pass to delete the legacy on-device pipeline.

### Determinism contract

1. **Build determinism.** TS `graph_builder.ts` produces byte-identical output across runs given the same input (sorted Map iteration; stronger than Swift original's `Dictionary` iteration order).
2. **Cross-language fingerprint match.** Output `fingerprint` is `<nodeCount>:<edgeCount>:<hex16>` and MUST match Swift `MountainGraph.computeFingerprint` for the same inputs.
3. **Wire compression.** Server emits raw deflate (`fflate.deflateSync`); client decompresses with `compression_decode_buffer(COMPRESSION_ZLIB)`. NOT gzip-wrapped.
4. **Receiver-side meet determinism.** When an inbound meet stamps a different `manifest_version`, `MeetupSessionController.activateRouteShared` force-fetches that exact manifest via `loadResort(entry, manifestVersionOverride:)` BEFORE solving. Both devices route on byte-identical graphs.

### Client wiring

- `CanonicalGraphFetcher.swift` — `invokeEdgeFunction` uses URLRequest pattern (mirrors snapshot-resort). Auto-builds on `not_built`: triggers `build-resort-graph`, retries fetch. `triggerBuild(resortId:)` is also exposed for explicit pre-builds. Cache filename: `{resortId}-m{version}-{snapshot}-{graphVersion}.json`.
- `ResortDataManager.swift` — `loadOrBuildGraph` prepends a canonical branch when `CanonicalGraphFetcher.shared.isEnabled(for: resortId)`. The `lastLoadFromCanonical` flag gates `GraphEnricher.enrich` and background `ResortDataEnricher` to legacy resorts only — canonical graphs already have overlay applied server-side, re-applying locally re-introduces version drift. `loadResort(_:snapshotOverride:manifestVersionOverride:)` exposes the receiver-side force-fetch path.
- `MeetRequestService.swift` — `MeetRequest` + `NewMeetRequest` carry `manifestVersion: Int?` (CodingKey `"manifest_version"`). `sendRequest(...)` threads it. Null = legacy meet, non-null = canonical; server retains every historical version.
- `MeetView.swift` — sender stamps `manifestVersion: resortManager.currentManifestVersion` alongside `graphSnapshotDate`.
- `MeetupSessionController.swift` — receiver path force-fetches sender's `request.manifestVersion`. Cross-resort: passes through to `loadResort(entry, manifestVersionOverride:)`. Same-resort with version mismatch: explicit re-fetch before solving.

## Operator runbooks

These three workflows require operator-side actions (terminal commands, dashboard clicks, file drops). Everything you'd previously read in a per-function README lives here now.

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
   `--no-verify-jwt` is required because `pg_net.http_post` from triggers runs without an authenticated user context. The function reads the service-role key from its own env separately.
7. **Verify** — send a friend request between two test accounts; tail logs with `supabase functions logs send-push --tail`. Foreground delivery shows the in-app banner; background delivery shows the iOS system banner.

**Troubleshooting:**
- *No pushes after setup* — common: expired JWT (key ID mismatch), wrong bundle id, sandbox vs production mismatch (`APNS_ENVIRONMENT` must match the build's entitlement).
- *`device_tokens lookup failed`* — service-role key not configured on the function.
- *`apns 410` followed by silence* — token retired (uninstalled / wiped); function deletes dead tokens automatically.

### Canonical ingest (per resort)

End-to-end workflow for taking a resort from "no canonical data" to "deterministic graph blob shipping to clients."

**Prereqs:**
```sh
pip install rapidfuzz flask
export SUPABASE_URL=https://qtzjxquzyrwavhvqarvg.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<service role key>   # never commit; pull via dashboard or Supabase MCP
```
Service-role key is required because `apply_canonical_manifest` revokes execute from anon + authenticated.

**1. Find the resort's bbox + lat/lon.** From `resorts_bbox`:
```sh
psql "$SUPABASE_DB_URL" -c "select id, lat_min, lon_min, lat_max, lon_max from resorts_bbox where id = 'vail';"
```
Or cross-reference `Models/ResortCatalog.swift`.

**2. Confirm the official trail + lift counts.** Open the resort's site (vail.com, parkcitymountain.com, etc.) — `reconcile.py` refuses to produce a draft if sources disagree without operator override. Source-of-truth-by-policy.

**3. Run ingest:**
```sh
python -m canonical_ingest ingest vail \
  --bbox 39.572,-106.394,39.658,-106.298 \
  --lat-lon 39.605,-106.355 \
  --expected-trails 195 \
  --expected-lifts 31
```
Output: `tools/canonical_ingest/drafts/vail.json`. Exits 3 with per-source counts on disagreement.

**4. Review the draft:**
```sh
python -m canonical_ingest review vail
```
Surfaces rows below confidence 0.7. Per row: **Accept** (no edit), **Reject** (edit JSON: `"notes": "REJECT: <reason>"`), or **Rename** (edit JSON: change `"name"`). Iterate until trail / lift counts match step 2 exactly.

**5. Geometry overrides (optional but recommended for top-N resorts):**
```sh
python -m canonical_ingest.geometry_tool vail
```
Flask + Leaflet UI on `localhost:8765`. Inspect candidate geometries from each source per row, pick / draw / save → writes to `canonical_geometry_override` (survives manifest-version bumps). Skip rows where every source agrees on geometry.

**6. Apply (dry-run first):**
```sh
python -m canonical_ingest apply vail --dry-run
python -m canonical_ingest apply vail
```
Calls `apply_canonical_manifest` RPC (single transaction across manifest + trails + lifts). Returns the new `manifest_version`. Content-hash unchanged → no-op.

**7. Trigger the build:**
```sh
curl -X POST $SUPABASE_URL/functions/v1/build-resort-graph \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"resort_id":"vail"}'
```

**8. Smoke test the client path:**
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
  -d '{"resort_id":"vail","cached_manifest_version":1}'
```
Expect `{"status":"cache_valid",...}` on the second call.

**Re-applying after reality changes** (resort adds a new lift / fixes a name): re-run steps 3–7. content_hash differs → `apply` writes v(N+1) → all clients with v(N) cached see `manifest_version` advance on next foreground and refetch. Old blobs are retained server-side for cross-version meet-request determinism.

### Topsheet artwork import

Bundled top-down ski renders backing the equipment picker. One image set per `skis_catalog` row; resolved at runtime by `HorizontalSkiView` via `topsheet_asset_key`. Slugs are `lowercase-brand-model` with spaces / punctuation collapsed to hyphens (e.g. `atomic-bent-110`, `volkl-m6-mantra`).

**Image specs:** PNG with alpha, 1280×200, ~6.4:1 aspect, transparent outside silhouette, sRGB, 1× scale only.

**To add new topsheets:**
1. Drop licensed PNGs into a working folder, named `<brand-slug>-<model-slug>.png` (e.g. `~/topsheet-source/atomic-bent-110.png`).
2. From the project root: `python3 tools/import_topsheets.py ~/topsheet-source`. Crops/resizes each PNG → writes into `PowderMeet/Resources/SkisTopsheets.xcassets/<key>.imageset/<key>.png` with a generated `Contents.json`. Emits `tools/topsheet_keys.sql` for `topsheet_asset_key` upsert.
3. Apply the SQL via the Supabase SQL editor or `supabase db push`.
4. Build the iOS target.

Rows without a bundled asset fall through to the procedural `BrandStyle` pattern — no code change needed when an image is missing.

## Common workflows

| Task | Where |
|---|---|
| Add a map layer | `MountainMapView.swift` — add SourceID + LayerID + `addLayers` block + `updateDataLayers` gated update |
| Retune solver | `SolverConstants.swift` — tolerances, α wait-penalty, scoring weights |
| Add a resort | `Models/ResortCatalog.swift` — `ResortEntry(...)`. Bounds drive `defaultZoom` automatically; set `preferredZoom/Bearing/Pitch` only if the default is framed poorly |
| Adjust style palette | `Theme/HUDTheme.swift` |
| New realtime event | `ChannelRegistry` → `prepare` / `subscribe` / `release` pattern. Never bypass |
| DB schema change | `supabase/migrations/<date>_<name>.sql` → `supabase db push` |
| Activity import | `Services/ActivityImporter.swift` + `Services/*Parser.swift` (GPX/TCX/FIT/Slopes/.powdermeet). One picker handles every format. PowderMeet backups detected by extension or JSON-content sniff (`exportSchemaVersion` key) and re-upsert imported_runs with their original `source` preserved. |
| Profile stats | `imported_runs` table → `recompute_profile_stats(uid)` RPC → `profile_stats` row → `SupabaseManager.loadProfileStats` |
| Per-edge skill memory | `imported_runs` (any source incl. live) → `recompute_profile_edge_speeds(uid)` RPC → `profile_edge_speeds` table → `SupabaseManager.loadEdgeSpeedHistory` → `currentEdgeSpeeds` → MeetView seeds `solver.edgeSpeedHistoryByProfile[myProfile.id]` AND `[friend.id]` (friend's dict comes from `SupabaseManager.loadFriendEdgeSpeeds(for:)`, gated by friends-only RLS `profile_edge_speeds_friend_read`; cached per-session in `friendEdgeSpeeds`). Solver builds per-skier `TraversalContext` via `buildContext(for:)` → `UserProfile.traverseTime` uses `rollingSpeedMs` when `observationCount >= 3`, else falls back to bucketed difficulty. `clearImportedRuns` wipes the table AND fires a recompute so `currentEdgeSpeeds` empties in lock-step. |
| Cross-resort meet accept | `IncomingMeetRequestCard` raises a "DIFFERENT RESORT" confirm sheet when `request.resortId != resortManager.currentEntry?.id`. Same-resort accepts skip the confirm. The actual switch happens in `ContentCoordinator.activateRouteShared` (loads the resort, reseats presence). |
| Skill-gated failures | `MeetingPointSolver.solve` retries Dijkstra with `ignoreSkillGates: true` when the strict pass returns no reachable intersection. If the relaxed pass succeeds, sets `lastFailureReason = .skillGatedPath` instead of `.noReachableIntersection`. UserProfile gates that respect `ignoreSkillGates`: difficulty hard-block + glade hard-block. Open/closed status + gradient soft-penalty still apply. |
| Live recording | `Services/LiveRunRecorder.swift` (passive on-device run detection while the app is open). Toggle in Profile → ACTIVITY → LIVE RECORDING (writes `profiles.live_recording_enabled`). |
| Resort snapshot pipeline | `supabase/functions/snapshot-resort/index.ts` is a chunked-elevation builder. Stage 0 fetches Overpass + writes a checkpoint blob; each subsequent invocation processes ~1200 elevation coords. Big resorts (Vail / Whistler / Palisades) cold-build across ~5 round-trips. Client (`ResortDataManager.driveSnapshotPipeline`) loops on `status: "elevation_pending"`. |
| Snapshot pin (which date the client requests) | `resort_snapshot_pins` Postgres table is the canonical source. `SupabaseManager.resolvedPinnedSnapshotDate(for:)` resolves: per-resort server pin → catalog-wide server pin (`__catalog__` row) → per-resort baked override → IPA-baked default. Loaded at cold launch + on foreground, cached to UserDefaults so first launch after install still falls through to the baked default but every subsequent cold launch picks up the latest server value. Bumping `__catalog__` re-pins all 159 resorts; insert a per-resort row to bump just one. |
| Resort picker | `Views/ResortPickerSheet.swift` splits catalog into active list (grouped by region) + COMING SOON tail. `ResortEntry.comingSoonIds` is the audited set of resorts with no `piste:type=downhill` / `aerialway` data in OSM today. Multi-resort GPS ambiguity: when ≥2 catalog bboxes contain the user's GPS, `ContentCoordinator.bootstrap` populates `pendingResortChoices` and the picker renders an "AT YOUR LOCATION" header section above the regional groupings. |
| Add a canonical resort manifest | "Operator runbooks → Canonical ingest" above. Operator-driven 8-step workflow (bbox → official counts → ingest → review → optional geometry overrides → apply → trigger build → smoke test). |
| Add ski topsheet artwork | "Operator runbooks → Topsheet artwork import" above. PNG → `python3 tools/import_topsheets.py <folder>` → SQL upsert. |
| Configure APNs push delivery | "Operator runbooks → APNs push setup" above. One-time setup: download `.p8`, set Supabase secrets, configure DB function URL + key, deploy with `--no-verify-jwt`. |
| Tile pre-cache (offline-on-mountain) | `Map/MapboxOfflineCache.swift`. On every `handleSelectedEntryChange` to a non-nil entry, calls `prewarm(resort:)` which fires `loadStylePack` + `loadTileRegion` for the resort bbox + 500 m buffer at zoom 10–16. Idempotent in-session. Failures degrade gracefully — live tiles still stream the old way. |
| Battery throttle on cold mountain | `LocationManager.PowerProfile` (.normal / .lowPower / .critical). Observers on `NSProcessInfoPowerStateDidChange` + `ProcessInfo.thermalStateDidChangeNotification` re-apply accuracy + filter. `RealtimeLocationService.currentBroadcastInterval` widens the cadence floor under throttle (1.5 s lowPower, 4 s critical); table-upsert interval stretches (60 s / 120 s). `force=true` callers (heartbeat, first-fix, foreground) bypass the floor. |
| Network reachability + offline banner | `Services/Reachability.swift` (NWPathMonitor singleton). `ContentView` reads `Reachability.shared.isReachable` and renders a thin red bar between header and content when offline. `unsatisfied → satisfied` transition posts `.powderMeetNetworkBecameReachable`; `RealtimeLocationService` listens and force-broadcasts last position so friends see a fresh dot the instant signal returns. |

## Build + lint

iPhone-only target:

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

```bash
supabase db push    # or paste migration into SQL editor
```

## Working in this codebase

1. `git status -s` and `git log -20` before assuming what's landed.
2. Touching map code? Read `MountainMapView.swift` first to absorb the
   Coordinator + hash-gated `updateDataLayers` pattern before adding layers.
3. The directory map above tells you where each concern lives — don't bulk-grep.
4. **There are exactly two docs in the repo: this file and `README.md`.**
   Anything you'd previously have written into a per-feature `README.md`
   or a `HANDOFF_*.md` or a separate `RUNBOOK.md` belongs in here under
   the appropriate section. No `docs/` folder, no per-function READMEs.
   When you add or move project structure (new folder, new tooling
   package, new gitignore rule, new build/deploy script), update both
   this file's directory map AND `README.md`'s "Repository layout"
   section in the same commit. Without that the next session has no
   idea the structure exists, duplicates accumulate, and people get
   confused.

## Future work — deferred items

Single canonical TODO list for PowderMeet. If a deferred item exists, it lives here — no other AUDIT / TODO / scratch lists. Each item names its scope and the cheapest path to the fix. Code-surface estimates use file count / lines / migrations / RPCs — never time units.

Ordered by readiness, not importance: operator-driven workflows first, deferred-until-use-case last. (Visual / UX polish — map stylistic pass + the small UX wins — all shipped.)

### 1. Recently-shipped follow-ups

Loose ends from the just-landed map stylistic pass:
- **Per-point DEM source for tree-line filter.** `TreeLayerBuilder` reserves `treeLineMeters` on `ResortEntry` (default 2400 m), but the per-tree elevation lookup is deferred (no client-side DEM). When a DEM source lands, drop the marker comment in `generateFeatureCollection` and apply the filter; trees above tree-line should disappear.
- **Phase 3 perf check on Whistler.** Symbol count caps at 10k per resort, but real-device frame time hasn't been measured. If pitch-camera scrolling drops below 16 ms on Whistler, lower density to 1 tree per 300 m² first, then revisit the near-camera snow emitter as the next-cheapest cut.

### 2. Operator workflows — your hands needed

These are operator-driven (terminal commands, dashboard toggles, on-snow device runs) — not coding work. Each unblocks downstream cleanup.

#### Canonical resort-graph rollout

Backend + client pipeline shipped (see "Canonical pipeline" section above). Implicitly closes the legacy "curated overlay drift" risk: once IPA-bundled overlay JSON is gone, two devices on different app versions can't diverge on the same resort.

- **Top-5 ingest** — Vail done. Remaining: Park City, Palisades Tahoe, Whistler Blackcomb, Mammoth. Per-resort: 1 operator session via "Operator runbooks → Canonical ingest" above.
- **Two-device determinism verification** — install on two physical iPhones at the same resort. Compare cached blob sha256, log `MountainGraph.graphFingerprint`, run `MeetingPointSolver` from the same start+end nodes; routes must match edge-for-edge, time-to-second. Hard-blocked on physical hardware.
- **Cache-durability + manifest-update verification** — leave a cached client untouched on a v(N) resort for several days; confirm `get-resort-graph` returns `cache_valid` on each cold launch (no blob redownload, only live-status sidecar refresh). Then bump the manifest server-side (insert a `canonical_trail` row + reapply); confirm the v(N)-cached device sees `manifest_version` advance on next foreground and refetches.
- **Top-25 ingest** — same workflow. Per-resort autodiscovery flips canonical on for each as its manifest lands; no separate "global flag flip" step.
- **Cleanup pass** — only after a clean stabilization window with zero canonical-fetch fallbacks: delete `Services/ResortDataEnricher.swift`, bundled `Resources/ResortData/*.json`, `tools/prewarm_snapshots.py`; thin `GraphBuilder.swift` / `CuratedResortData.swift` / `GraphCacheManager.swift`. **Do not do this before the canonical path proves itself in production for a real ski week** — legacy pipeline is the safety net.

#### Per-resort golden graph fixtures (capture step)

`PowderMeetTests/MountainGraphTests.swift` pins determinism + invariants. DEBUG export button shipped (`Views/RoutingTestSheet.swift` → "EXPORT GRAPH FIXTURE"). Remaining: visit each catalog resort in the running app, tap export, copy each `<resortId>-fixture.json` from the simulator's Documents directory into `PowderMeetTests/Fixtures/`, then add a parameterised test that loads each fixture and asserts no drift after rebuild.

#### Supabase Pro upgrade walkthrough (Free → Pro)

When the project moves Free → Pro, walk these in order. Most are dashboard toggles; re-run the security advisor after each batch.

**Auth (dashboard → Authentication):**
- **Leaked password protection** — HaveIBeenPwned check on signup + password change. Pro-only. Currently the only red `auth_leaked_password_protection` advisor item.
- **Custom SMTP / sender domain** — Free uses Supabase-branded `noreply@mail.app.supabase.io`, rate-limited and prone to spam filters. BYO SMTP (Resend / Postmark / SES) under Pro with a custom From. Wire up *before* turning on email confirmations seriously.
- **Email confirmation on signup** — turn on `Confirm email`. Pair with custom SMTP under Pro to avoid deliverability complaints.
- **Email change confirmation** — same toggle row; re-confirm new email before swapping.
- **MFA — TOTP enforcement** — basic TOTP is Free; Pro adds enrollment policies + recovery codes. Revisit if account-takeover comes up.

**Ops / observability:**
- **Function logs retention** — Free keeps 1 day; Pro keeps 7. Useful for debugging the `send-push` APNs delivery path post-launch.
- **Database backups (PITR)** — Pro = 7-day point-in-time recovery. Turn on as soon as real users are on the system.
- **Read-only Postgres replicas** — only if query throughput becomes a problem; not urgent.

**Compute / scale (only if needed):**
- **Compute add-ons** — bump from shared compute if `snapshot-resort` starts timing out under load.
- **Storage bandwidth** — Free is 5 GB egress/month; resort snapshots + avatars accumulate. Check usage before launch.
- **Database branching** — ephemeral DB branches for migration PR review. Worth it once we test schema changes against prod-shaped data.

### 3. Routing depth — deferred until use case lands

The current solver is good enough for 2-skier meets on real-world graphs. The items below are real upgrades, but each is gated on either a product feature shipping or a concrete user complaint. Don't pre-build.

**Algorithm correctness:**
- **Skill-tier recency filter** — recency-weighted edge speeds shipped (60-day half-life decay in the recompute RPC). Skill-tier change is a discontinuity decay alone can't fully capture. Stamp `skill_level_at_run` on `imported_runs` at write time; filter recompute by `skill_level = current`. Surface: 1F / ~15L / 1M / 1R. Wait until decay alone proves insufficient.
- **Closure-until timestamps** — currently `isOpen=false` is binary. Add `closure_until: timestamptz` to edge attributes; gate "closed at arrival_time" instead of "closed now." Surface: 1F / ~20L. Spec-gated on resort feeds carrying expected reopen times — most don't.
- **Group meet 1-median (n-skier)** — for 3+ users, `argmin Σ wᵢ·tᵢ(m)` (or max, or weighted CVaR). Multi-source Dijkstra populates all `tᵢ(m)` in one pass. Surface: 1F / ~80L. Spec-gated on group-meet feature.

**Algorithm efficiency:**
- **Bidirectional Dijkstra** — 2-skier solve currently runs two single-source Dijkstras to completion. Bidirectional terminates when frontiers cross — 5–20× fewer expansions on Whistler-scale graphs. Defer until time-dependent + variance changes settle. Surface: 1F / ~150L.
- **A\*** with elevation-corrected straight-line heuristic (admissible, cheap). Pairs naturally with bidirectional. Surface: 1F / ~30L.
- **Bucket queue (Dial's)** — bounded edge costs make this `O(V+E+C)` vs heap's `O((V+E) log V)`. ~2–3× speedup. Surface: 1F / ~80L. Skip until profiling shows the heap is hot.

**Personalization:**
- **Learned edge-cost ML** — replace hand-coded `traverseTime` penalty model (moguls 0.7, ungroomed 0.6) with per-user gradient-boosted model on `(edge_features, conditions, user_features) → observed_time`. Falls back to hand-coded when data is thin. Big project: training + offline eval + deploy + Swift inference. Defer until concrete user complaints; rolling-average personalization is the cheaper first signal.
- **Active-learning bandit on edge speed** — when an edge is load-bearing AND high-variance, slightly bias suggestions toward routing that edge to gather data. Compounds slowly; pays off over months. Surface: 1F / ~50L. Pairs with CVaR.
- **Friend co-skiing inference** — `(skierA, skierB, edge) → joint_observed_time` as a prior. Schema-heavy. Defer until per-user model is mature.

**UX / output quality:**
- **Joint-utility scoring with forward rollouts** — current "hub bonus + elevation penalty" is heuristic for "good place to keep skiing together." Real model: shallow forward rollout (1–2 runs) per candidate, scored by joint utility. Reframes from "arrive at a point" to "have a good hour together." Surface: 2–3F / ~200L. Product call before shipping.

### 4. Activity imports — needs real production data

Each item below has a clear shape but can't be threshold-tuned without real cross-source recordings to validate against. Defer until production users start importing varied data.

- **Per-point speed validation (Phase 4.3)** — needs a real Garmin export to set the outlier threshold for `GPXTrackPoint.speed` vs haversine disagreement.
- **1 Hz temporal resampling** — needs a real Slopes+Health side-by-side recording of the same day to verify whether resampling actually improves cross-provider fairness or just smooths noise.
- **Conditions_fp historical lookup for disk imports** — would replace the `'default'` bucket on imported runs with a historical-weather lookup; ~1 API call per imported run is heavy and the value is only realised for users with large libraries.
- **Cross-source dedup** — Slopes file + Apple Health of the same workout = two `imported_runs` rows. `physical_dedup_key = lower(resort)|edge|(epoch/300)` partial-unique-index + RPC priority chooser. Surface: 1F / ~30L / 1M / 1R. Risk: wrong key collapses real distinct runs. Needs Slopes+Health overlap test data.

### 5. Test infrastructure

#### Solver behavioral fixtures

After CVaR scoring (or any objective change) lands, build per-scenario fixtures: synthetic graph + skier configs + expected output range, so a future regression that breaks "this scenario should produce a route with imbalance ≤ 30 s" is caught by tests. Surface: 1F / ~150L.

(For per-resort golden graph fixtures, see Operator workflows above — that's a capture-step task, not authoring work.)
