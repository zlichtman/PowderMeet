# 01 Architecture

## 1. Shape

```
pipeline (Python, CI)  ──builds──▶  resort bundles (SHA-256 named, public-read storage)
                                              │
Supabase: Postgres (truth for shared state) · Realtime (private topics, server-sent)
          · Storage · pg_cron → jobs → TS edge workers (status, conditions, push)
                                              │ typed RPCs + one private topic per user
iPhone: AppCore sessions (actors) · MountainCore · MeetSolver · MapScene · DescentKit
        · PowderMeetAPI · thin SwiftUI app
```

Three rules define the shape:

1. **The server owns the mountain.** Bundles are built by the pipeline, identified by
   content hash, verified and rendered by the phone. The phone never builds a graph.
2. **The database owns everything two phones share.** Friendships, blocks, meets,
   presence fan-out, published bundles, learned pace. Writes are RPCs; reads are RLS.
3. **Each phone owns its own route.** The only shared fact about a meet's geography
   is a `rendezvous_id`. Routes, ETAs and reroutes are computed locally with one
   solver package and shared only as progress.

## 2. Repository layout

```
.
├── AGENTS.md
├── specs/                         this pack
├── apps/ios/
│   ├── project.yml                XcodeGen source for the project
│   ├── PowderMeet.xcodeproj       thin app target (generated, committed)
│   └── PowderMeet/                Composition/ (CompositionRoot, models, device services, developer
│                                  testing: 07-CLIENT §8), Theme/, Utilities/, Views/
├── packages/
│   ├── MountainCore/
│   ├── MeetSolver/
│   ├── DescentKit/
│   ├── MapScene/                  pure render model and diffing
│   ├── MapboxAdapter/             the only MapboxMaps importer (own package so the rest builds on Linux)
│   ├── PowderMeetAPI/             protocol + DTOs + FakeBackend
│   ├── SupabaseBackend/           the only Supabase importer (own package)
│   ├── AppCore/
│   └── Support/                   targets: CZlib, CSQLite (system libraries), PMLogging
├── backend/supabase/
│   ├── config.toml
│   ├── migrations/
│   ├── functions/                 status-refresh, conditions-refresh, push-drain, avatar-sweep, _shared
│   ├── tests/database/            pgTAP
│   └── seed/                      test users and fixtures for local runs
├── pipeline/
│   ├── pyproject.toml             package powdermeet_pipeline, CLI pm-pipeline
│   ├── powdermeet_pipeline/
│   ├── tests/
│   └── fixtures/
└── .github/workflows/             packages.yml, backend.yml, pipeline.yml, publish-resort.yml, build-all.yml
```

Xcode project uses synchronized folders; packages are local SPM dependencies.

## 3. Packages and public surfaces

Each package lists its public types. Code MUST keep these names.

### MountainCore (depends on Support for `CZlib`)
- `ResortBundle` (decoded, immutable, `Sendable`), `BundleID` (64-hex `String` newtype), `BundleLoader.load(data:expectedID:) throws -> ResortBundle` (SHA check, gunzip, decode, `BundleIntegrity.validate`).
- `Graph`: `Node`, `Edge`, `Group`, `NodeID`, `EdgeID`, `GroupID`, `Difficulty`, `EdgeKind`, `LiftInfo`, `OperatingHours`; adjacency never changes with status.
- `Rendezvous`, `RendezvousID`.
- `ResortStatus`, `GroupState` (`open, closed, hold, scheduled`), `StatusMode`, `StatusFreshness` (`fresh, stale, unavailable` from `expires_at` vs now).
- `Conditions`, `ConditionsSample`.
- `ResortInfo` (catalog row: id, name, timezone, bbox, camera).
- `Geo`: haversine, bearing, polyline projection, `Geohash`; `Coordinate`, `GeoPoint`, `BoundingBox`, `Fix`.
- `BundleIntegrity` (port of `MountainGraphIntegrity`) and `BundleIntegrityReport`.

### MeetSolver (depends on MountainCore)
- `SkierProfile`, `Ability` (enum), `PaceModel`, `RoutingOrigin`, `SkierInput`.
- `SolveInput` (`Hashable`, `Sendable`), `SolveOptions`, `StatusPolicy` (`strict, degraded`).
- `MeetOptions`, `MeetOption`, `Route`, `RouteLeg`, `ETA` (mean, sd), `SolveFailure`.
- `MeetSolver.solve(_:) -> Result<MeetOptions, SolveFailure>`
- `MeetSolver.route(for:to:in:) -> Result<Route, SolveFailure>`
- `MeetSolver.recost(_:from:at:in:) -> ETA?` (nil = untraversable remainder)
- `RouteProgress.start(_:in:)`, `RouteProgress.project(fix:onto:in:after:) -> Progress` (a value, no tracker object) and `RouteSwitchPolicy`.
- `Maneuvers.build(for:in:) -> [Maneuver]`.
- `SolveCache` (LRU keyed by `SolveInput` hash; owned by the caller).

### DescentKit (depends on MountainCore)
- `ActivityParser` protocol; `GPXParser`, `TCXParser`, `FITParser`, `SlopesParser`.
- `ParsedActivity`, `TrackPoint`, `Descent`, `DescentSegmenter`, `DescentHasher`.
- `TrailMatcher.match(descent:in:) -> DescentMatch`, `MatchObservation`, `RunSection`.
- `MatcherVersion` constant.

### MapScene (depends on MountainCore, MeetSolver)
- `RenderInput` (bundle, status, routes, friends, selection, time, theme), `RenderModel`, `SceneDiff`, `SceneBuilder.build(_:) -> RenderModel`, `SceneDiffer.diff(old:new:) -> SceneDiff`.
- Package `MapboxAdapter`: `MapboxMapController` (applies diffs, camera queue), `MapCommand`, `MapEvent`.

### PowderMeetAPI (depends on MountainCore)
- `BackendClient` protocol (every RPC in `04-SCHEMA.md` section 6, bundle and status fetch, realtime event stream `AsyncStream<ServerEvent>`), DTOs mirroring tables, `ServerEvent` enum, `BackendError`.
- `FakeBackend` (in-memory, scriptable, used by AppCore tests and as the developer sandbox's private server, which also ships in Release: 07-CLIENT §8).
- Package `SupabaseBackend`: the only Supabase import.

### AppCore (depends on all of the above except MapboxAdapter)
- `AppSession` (actor), `ResortSession` (actor), `MeetSession` (actor), their `State` enums and `Event` enums, `Dependencies` struct, `PowderMeetError`, `Toasts`, `FlightRecorder`.
- `LocationProvider` protocol (`AsyncStream<Fix>`), `Clock` protocol, `Reachability` protocol, `PushRegistrar` protocol.

### Support
- `CZlib`, `CSQLite` system-library targets; `PMLogging` (category table, ring buffer).

## 4. Dependency rules

```
Support (CZlib) ← MountainCore
MountainCore ← MeetSolver ← MapScene
MountainCore ← DescentKit
MountainCore ← PowderMeetAPI ← AppCore → (MeetSolver, MapScene, DescentKit)
MapboxAdapter → MapScene (and MapboxMaps)        app only
SupabaseBackend → PowderMeetAPI (and Supabase)   app only
```
No package imports UIKit, SwiftUI, MapboxMaps or Supabase. `swift build` of every
package MUST succeed on Linux in CI.

## 5. Concurrency model

- Swift 6 language mode, strict concurrency, `SWIFT_DEFAULT_ACTOR_ISOLATION` left at
  nonisolated for packages. UI-facing `@Observable` projections are `@MainActor`.
- Sessions are actors. Each owns a task tree started in `run()` and ended by
  cancellation. A state transition is one actor method; effects are child tasks that
  observe `Task.isCancelled`. No generation counters, no "stale guard" after awaits:
  if an await returns after cancellation, the method checks `Task.isCancelled` and
  returns.
- Solver and scene building run in detached tasks owned by the session with a
  budget; results are applied only if the session's `inputVersion` still matches
  (one integer per session, compared once, set only in the transition that changed
  inputs). This is the only version check allowed and it is local to the session.
- Streams: `AsyncStream` for fixes, server events, status and conditions.
  `LocationProvider` multicasts fixes to any number of consumers.

## 6. Error model

```swift
public enum PowderMeetError: Error, Sendable {
  case auth(AuthFailure)          // signedOut, sessionExpired, appleSignInFailed, and the email-account cases
  case network(NetworkFailure)    // offline, timeout, server(status:), decoding
  case data(DataFailure)          // bundleUnavailable(resortID), bundleCorrupt(BundleID), statusUnavailable,
                                  // backupFailed, mapNotDownloaded(resortID), mapNotRemoved(resortID), phoneFull,
                                  // healthUnreadable, recordingNotRemoved
  case routing(SolveFailure)      // from MeetSolver
  case meetRouting(SolveFailure, MeetParty) // a meet's solve, naming you or the partner (07 section 5)
  case meet(MeetFailure)          // notFriends, blocked, partnerBusy, meetGone, alreadyActive, rejected(reason)
  case permission(PermissionFailure) // location, notifications, motion, health
  case profile(ProfileFailure)    // nameTaken, nameNotAllowed, nameInvalid
  case social(SocialFailure)      // tooManyTries, photoUnreadable
}
```
Every case has `userMessage: String` and `recovery: Recovery` (`retry, signIn,
openSettings, pickResort, none`). Surfaces: `Toasts` queue for transient, inline state
for flow failures, `Alerts` for blocking. `try?` is forbidden on user-initiated paths.

## 7. Environments and configuration

- One hosted Supabase project, `PowderMeet` (DECISION 9), used for development,
  TestFlight and, after the launch reset, production. CI tests run against a local
  Supabase (`supabase start`), never against the hosted project. `Secrets.xcconfig`
  holds its URL, publishable key and the Mapbox public token. Service-role keys exist
  only in Supabase secrets and `_local/secrets/` on the maintainer's Mac.
- `config.toml` is committed and is the source for `verify_jwt`, realtime settings and
  cron. Dashboard-only settings are listed in `04-SCHEMA.md` section 12 and checked
  by a CI script against the Management API where possible.
- Feature flags: a `flags` JSON in `resorts`/`profiles` is NOT used; flags are
  compile-time (`#if`).

## 8. Versioning

- Bundle `schema_version` integer; the client declares `supportedBundleSchemas`.
- RPC compatibility: additive only within a major; breaking changes add a new RPC
  name (`meet_propose_v2`). `ServerEvent` envelope has `v`.
- App version gates: `min_app_build` in `app_config` table; the app shows an update
  wall when below it.
