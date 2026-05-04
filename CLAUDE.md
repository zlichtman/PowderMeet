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
- **Build:** Open `PowderMeet.xcodeproj` in Xcode. Target family is universal
  (`TARGETED_DEVICE_FAMILY = "1,2"`). **iPhone is the primary in-field device**
  (one-handed on a chairlift, in a pocket with gloves) — run on an iPhone sim
  first; use an iPad sim only when verifying the larger-screen layout.
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
├── PowderMeetApp.swift           App entry; RootView switches Auth ⇄ Content
├── ContentView.swift             Scaffold: 3 tabs + header + resort bar + sheets
├── ContentCoordinator.swift      @Observable lifecycle owner: resort/conditions/
│                                 realtime/presence/nav-services/meetup session.
│                                 ensureRealtimeLocationService passes
│                                 try? FriendLocationStore() as persistentStore
│                                 so cold launch picks up last-known friend
│                                 dots before realtime hydrates.
├── Algorithm/                    Pure pathfinding + solver
│   ├── MeetingPointSolver.swift    Dijkstra variants; α wait-time penalty;
│   │                               static solutionCache keyed by graphFingerprint
│   │                               + per-skier edgeSpeedHistoryFingerprint.
│   │                               Per-skier edgeSpeedHistoryByProfile dict.
│   │                               makeContext(for:) is the public façade —
│   │                               every external caller (route narrative,
│   │                               reason builder) MUST use it; never
│   │                               construct a TraversalContext by hand.
│   │                               Skill-gated failure detection: relaxed-
│   │                               Dijkstra retry sets lastFailureReason =
│   │                               .skillGatedPath when topology is fine
│   │                               but the strict pass was blocked by
│   │                               difficulty/glade gates.
│   │                               MeetingResult.solveAttempt enum stamps
│   │                               which fallback tier produced the route.
│   ├── RouteProjection.swift       Time→position interpolation on a route
│   ├── SunExposureCalculator.swift Sun angle × slope aspect shading
│   └── SolverConstants.swift       Tunable: tolerances, α, scoring weights
├── Models/
│   ├── MountainGraph.swift         Nodes/edges; representativeEdge; precomputed
│   │                               fingerprint; binary-search atTime
│   ├── ResortCatalog.swift         Per-resort bbox, defaultZoom (bounds-derived), passProducts
│   ├── MountainNaming.swift        Single source of truth for node/edge labels —
│   │                               canonical/withChainPosition/bareName styles;
│   │                               every consumer (picker, profile HUD, friend
│   │                               cards, route steps, map POIs) goes through it
│   ├── ProfileStats.swift          Aggregated season stats (runs/days/vertical/topSpeed)
│   ├── ActiveMeetSession.swift     Live-meetup state + RouteTracker
│   └── ResortConditions.swift      Weather/forecast bundle + hourly lookup
├── Services/
│   ├── ResortDataManager.swift     Loads + caches graphs (in-memory + disk)
│   ├── GraphBuilder.swift          OSM + SlopeCache → MountainGraph
│   ├── GraphCacheManager.swift     On-disk graph cache
│   ├── LocationManager.swift       CoreLocation; always-auth; onFirstFix; bg session
│   ├── RealtimeLocationService.swift  Broadcast pos on `pos:cell:{geohash6}` plus
│   │                                  resort-wide `pos:resort:{resortId}`; REST
│   │                                  hydrates `live_presence`; monotonic guard
│   ├── ChannelRegistry.swift       actor; ref-counted RealtimeChannelV2 owner
│   ├── FriendService.swift         Friends channel `friends:{id}` (postgres_changes)
│   ├── MeetRequestService.swift    Meet requests; channel `meets:{id}`
│   ├── FriendLocationStore.swift   SwiftData last-known cache (cold-start hydrate)
│   ├── PresenceCoordinator.swift   State machine: hydrate social → subscribe →
│   │                               live; gates broadcasts on phase == .live
│   ├── RouteProgressTracker.swift  Live-meetup route state: advanced / skipped /
│   │                               completed / deviated events
│   ├── ConditionsService.swift     Weather API + hourly history
│   ├── ActivityImporter.swift      GPX/TCX/FIT/Slopes/.powdermeet → MatchedRun →
│   │                               imported_runs + recompute_profile_stats +
│   │                               recompute_profile_edge_speeds RPC. Loads + curates
│   │                               the matching graph BEFORE persisting so
│   │                               `MountainNaming.edgeLabel` resolves canonical
│   │                               trail names (no "Imported Run" fallback).
│   ├── LiveRunRecorder.swift       @Observable @MainActor — passive on-device run
│   │                               detection. Subscribes to LocationManager fixes;
│   │                               sliding-window classifier (mirrors
│   │                               TrailMatcher.classifyWindow); on run-end,
│   │                               persists imported_runs row with source = .live
│   │                               then debounce-fires recompute_profile_edge_speeds.
│   │                               Gated by `profiles.live_recording_enabled`.
│   ├── SupabaseManager.swift       .shared singleton; auth/profile/stats wrappers;
│   │                               sessionGeneration counter for stale-teardown;
│   │                               currentEdgeSpeeds dict (per-edge skill memory,
│   │                               loaded after every import / restore / delete);
│   │                               clearImportedRuns also recomputes edge speeds
│   │                               so DB and in-memory cache stay coherent.
│   └── Choreography/
│       ├── RouteChoreographer.swift  DSL-driven route-reveal sequence
│       ├── AnimationTimeline.swift   `at(.ms(x), "tag") { … }` builder
│       ├── HapticService.swift       CHHapticEngine wrapper
│       └── AudioService.swift        arrival_bell.caf playback (asset optional)
├── Map/
│   ├── MountainMapView.swift       UIViewRepresentable wrapping MapboxMaps.MapView.
│   │                               Coordinator owns map state; `updateDataLayers`
│   │                               is the SINGLE source-update entry point
│   │                               (struct-gated per source — don't bypass)
│   ├── MapLayerState.swift         Hashable layer-state structs:
│   │                               `MapTrailLayerState` / `MapFriendLayerState` /
│   │                               `MapRouteLayerState`. Replaces the old
│   │                               hand-rolled `last*Hash` diff fields so the
│   │                               compiler enforces field membership when a
│   │                               new input gets added.
│   ├── GeoJSONBuilder.swift        Pure fn: graph + state → GeoJSON dicts.
│   │                               Lifts emit [lon,lat,elev]; sea-referenced
│   │                               so Peak-to-Peak gondolas float over valleys
│   └── CinemaDirector.swift        Resort-intro choreography + viewport idle.
│                                   Active-meetup viewport transitions
│                                   intentionally absent — see "Camera framing"
│                                   under invariants.
├── Navigation/
│   ├── NavigationDirector.swift    Orchestrates CinemaDirector + Choreographer
│   ├── NavigationViewModel.swift   @Observable: maneuver + ETA for HUD
│   ├── ETAEstimator.swift          EMA speed, confidence-blended estimate
│   ├── ManeuverIconResolver.swift  SF Symbol for next-maneuver row
│   └── FriendSignalClassifier.swift live / stale / cold from capturedAt age
├── Views/
│   ├── MapView.swift               ResortMapScreen — wraps MountainMapView
│   ├── CompactRouteSummary.swift   Top bar during active meetup
│   ├── EdgeInfoCard.swift          Bottom card: trail/edge + conditions
│   ├── TimelineView.swift          Day scrubber (drives sun/forecast overlays)
│   ├── ResortPickerSheet.swift     Resort switcher (run/lift counts on the
│   │                               currently-loaded resort only, derived from
│   │                               `ResortDataManager.runCount`/`liftCount`)
│   ├── ProfileView.swift           Avatar + name + skill, live status, 2×2 stats,
│   │                               Friends row, Settings row
│   ├── ProfileTabContents.swift    Account · Activity tab contents
│   │                               (no algo toggles — legacy name was
│   │                               `AlgorithmSettingsSheet.swift`).
│   │                               Activity layout, top→bottom: VIEW LOGS
│   │                               (also owns in-flight import progress +
│   │                               cancel chip), CONNECT APPLE HEALTH,
│   │                               IMPORT ACTIVITY FILE, LIVE RECORDING.
│   ├── Components/
│   │   ├── ActivityImportRows.swift    ConnectAppleHealthRow,
│   │   │                               ImportActivityFileRow, ViewLogsRow,
│   │   │                               + shared ActivityImportTypes.supported
│   │   │                               UTType list. ViewLogsRow renders
│   │   │                               "UPLOADING · 3/10" using
│   │   │                               ActivityImportSession.processedCount
│   │   │                               / totalCount, swaps to spinner +
│   │   │                               cancel-X with fixed-frame columns
│   │   │                               so the row doesn't reflow. Static
│   │   │                               import rows so tapping HK never
│   │   │                               appears to mutate the file row.
│   │   └── SkillLevelPicker.swift     Single-row 4-pill picker
│   │                                   (GRN/BLU/BLK/2BLK), selected pill
│   │                                   fills accent red. Fixed-size cells.
│   ├── FriendsSheet.swift          Friends list + search + pending requests
│   ├── DeleteAccountSheet.swift    Typed-confirmation account deletion
│   ├── RealtimeSelftestView.swift  #if DEBUG — 8 invariant checks
│   ├── RoutingTestSheet.swift      DEV: pick a node as your "live location"
│   ├── RouteCard.swift             Meeting-result card. Renders an amber
│   │                               PREVIEW pill when result.solveAttempt
│   │                               != .live (forced-open or
│   │                               neighbor-substitution fallback)
│   ├── ImportedRunsView.swift      "LOGS" full-screen viewer — per-day
│   │                               summary rows + search bar + per-run
│   │                               drill-in. Brand-colored source pill
│   │                               (HEALTH=Apple red, STRAVA/GPX=orange,
│   │                               GARMIN/TCX/FIT=teal, SLOPES=blue,
│   │                               POWDERMEET=accent, LIVE=amber)
│   ├── FriendOffscreenIndicator.swift  Edge-of-screen friend chips
│   ├── SplashView.swift            Launch placeholder
│   ├── RootView.swift              Auth ⇄ Content gate
│   ├── Onboarding/                 First-run flow (no resort step — auto-detect)
│   ├── Auth/                       Email + Sign in with Apple, sign-up, reset.
│   │                               Apple flow: raw nonce → Apple, SHA-256(nonce)
│   │                               → Supabase via signInWithIdToken
│   │                               (Utilities/CryptoHelpers.swift)
│   └── Meet/                       MeetView subviews — sectioned compositor:
│                                   IncomingMeetRequestsSection (raises a
│                                   "DIFFERENT RESORT" confirm before accept
│                                   when the request is at another resort),
│                                   PendingFriendRequestsSection,
│                                   MeetingOptionsSection (paging + show-route;
│                                   first card labeled "TOP MATCH" not
│                                   "BEST MEETING POINT"),
│                                   FriendsListSection, PowderMeetActionButton,
│                                   plus card primitives (Active/Friend/Incoming/
│                                   Pending/MeetingOption + RouteStepConsolidator
│                                   + FriendSearchSheet)
├── Theme/HUDTheme.swift            Shared colors, route palette, typography
├── Utils/Geohash.swift             Pure Swift encode + 9-cell neighbor lookup
├── Utilities/                      Debouncer, UnitFormatter, CryptoHelpers, …
└── Resources/
    ├── Models/                     .glb hero meshes — source TBD; in-app fallbacks
    ├── ResortData/                 Baked resort JSON + slope caches
    └── Sounds/                     arrival_bell.caf

supabase/migrations/                SQL migrations — apply via `supabase db push`
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
| Per-edge skill memory | `imported_runs` (any source incl. live) → `recompute_profile_edge_speeds(uid)` RPC → `profile_edge_speeds` table → `SupabaseManager.loadEdgeSpeedHistory` → `currentEdgeSpeeds` → MeetView seeds `solver.edgeSpeedHistoryByProfile[myProfile.id]` (friend gets `[:]`) → solver builds per-skier `TraversalContext` via `buildContext(for:)` → `UserProfile.traverseTime` uses `rollingSpeedMs` when `observationCount >= 3`, else falls back to bucketed difficulty. `clearImportedRuns` wipes the table AND fires a recompute so `currentEdgeSpeeds` empties in lock-step. |
| Cross-resort meet accept | `IncomingMeetRequestCard` raises a "DIFFERENT RESORT" confirm sheet when `request.resortId != resortManager.currentEntry?.id`. Same-resort accepts skip the confirm. The actual switch happens in `ContentCoordinator.activateRouteShared` (loads the resort, reseats presence). |
| Skill-gated failures | `MeetingPointSolver.solve` retries Dijkstra with `ignoreSkillGates: true` when the strict pass returns no reachable intersection. If the relaxed pass succeeds, sets `lastFailureReason = .skillGatedPath` instead of `.noReachableIntersection`. UserProfile gates that respect `ignoreSkillGates`: difficulty hard-block + glade hard-block. Open/closed status + gradient soft-penalty still apply. |
| Live recording | `Services/LiveRunRecorder.swift` (passive on-device run detection while the app is open). Toggle in Profile → ACTIVITY → LIVE RECORDING (writes `profiles.live_recording_enabled`). |
| Resort snapshot pipeline | `supabase/functions/snapshot-resort/index.ts` is a chunked-elevation builder. Stage 0 fetches Overpass + writes a checkpoint blob; each subsequent invocation processes ~1200 elevation coords. Big resorts (Vail / Whistler / Palisades) cold-build across ~5 round-trips. Client (`ResortDataManager.driveSnapshotPipeline`) loops on `status: "elevation_pending"`. |
| Resort picker | `Views/ResortPickerSheet.swift` splits catalog into active list (grouped by region) + COMING SOON tail. `ResortEntry.comingSoonIds` is the audited set of resorts with no `piste:type=downhill` / `aerialway` data in OSM today. |

## Build + lint

Primary check — iPhone (the device this app actually ships on):

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Verify the iPad layout too before shipping UI changes:

```bash
xcodebuild -scheme PowderMeet -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M4)' build
```

```bash
supabase db push    # or paste migration into SQL editor
```

## Future work — deferred items

Carried over from the now-deleted `docs/ENGINEERING_AUDIT.md`. Everything below is intentionally unshipped; pick up when the use case warrants. Each item names its scope and the cheapest path to the fix.

### Per-resort golden graph fixtures (test infra)

Diff against expected node/edge counts + `MountainGraph.fingerprint` whenever `GraphBuilder` thresholds change. Foundation in `PowderMeetTests/MountainGraphTests.swift` already pins the determinism + invariants; what's missing is fixture capture per catalog resort.

Path:
1. Add a DEBUG-only "EXPORT GRAPH FIXTURE" button on `Views/RoutingTestSheet.swift` that serialises `resortManager.currentGraph` to JSON in `Documents/`.
2. Visit each catalog resort once, tap export, copy file into `PowderMeetTests/Fixtures/<resortId>.json`.
3. Add a parametrised test that loads each fixture and asserts no drift after rebuild.

### Phase 4.3 — per-point speed validation (low-priority polish)

Outlier rejection in `ActivityImporter.computedAvgSpeed` / `computedPeakSpeed`: when `GPXTrackPoint.speed` (the per-sample value Garmin FIT/TCX emit) disagrees with the haversine-derived per-segment speed by > some threshold, drop the segment. Without a Garmin-export fixture the threshold is guesswork; capture a real export, observe the noise floor, then implement.

### Cross-source dedup (user-deferred)

`physical_dedup_key = lower(resort)|edge|(epoch/300)`, partial unique index where edge_id is non-null, RPC chooses the higher-priority source per `(profile, physical_dedup_key)`. Plan was originally in a Claude plan note that's since been overwritten — recover from git history when reviving. Keeps Slopes + Apple Health duplicates of the same workout from creating two `imported_runs` rows.

### Conditions_fp accuracy follow-ups

`ActivityImporter` writes `'default'` for disk imports because it doesn't know the historical weather at run time. If you want disk-imported runs to also bucket properly:
- Look up `ConditionsService` historical archive for each run timestamp, fingerprint, stamp. Heavy network cost; only pays off for users with many imports.
- Or accept the current state and let `LiveRunRecorder` (which DOES know live conditions) be the only authoritative source of bucketed data.

## Working in this codebase

1. `git status -s` and `git log -20` before assuming what's landed.
2. Touching map code? Read `MountainMapView.swift` first to absorb the
   Coordinator + hash-gated `updateDataLayers` pattern before adding layers.
3. The directory map above tells you where each concern lives — don't bulk-grep.
