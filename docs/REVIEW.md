# Reviewing PowderMeet

A guide for a reviewer seeing the whole repository for the first time: what to read,
where the risk is, what is already known, and what to hand back.

## What it is

An iPhone app for two skiers at the same resort. It picks where to meet on the
resort's real lifts and runs, routes each skier there on terrain they can ski, and
shows them each other on the map until they meet. Resort maps are built from
OpenStreetMap by a Python pipeline and published to a live Supabase backend. Skiers
can import their GPS logs, which are matched to trails and set their pace.

## Read in this order

1. `AGENTS.md`: the rules every change here follows. The quality bar in it is also the
   review bar.
2. `specs/README.md`, then `specs/00-PRODUCT.md`, `01-ARCHITECTURE.md` and
   `10-INVARIANTS.md`. The specs are the contract: where code and spec disagree,
   that is a finding.
3. The spec for each area you review (table below).
4. `docs/ROADMAP.md`: what is open, in flight or deliberately dropped. Don't report a
   listed item as new; do say if it is worse than the roadmap says.
5. `docs/DEVELOPING.md`: layout and how to build.

| Area | Code | Spec |
|---|---|---|
| Who can see whom: friendships, locations, meets | `backend/supabase/migrations`, `backend/supabase/tests` | 03, 04 |
| The meet between two phones | `packages/AppCore` (`MeetSession`), `packages/PowderMeetAPI`, `packages/SupabaseBackend` | 03, 07 |
| Where to meet and how to get there | `packages/MeetSolver`, `packages/MountainCore` | 02, 06 |
| Resort maps | `pipeline/`, `pipeline/decisions/` | 05 |
| GPS import and trail matching | `packages/DescentKit` | 08 |
| Map drawing | `packages/MapScene`, `packages/MapboxAdapter` | 07, 12 |
| Screens | `apps/ios/PowderMeet` | 12, 13 |
| Edge workers (lift status, weather, push, photo cleanup) | `backend/supabase/functions` | 04, 11 |

## Where the risk is, most important first

1. **Privacy.** A location reaches only accepted friends, through row-level security
   and the RPCs in spec 04, and arrives only on the user's private Realtime topic.
   Check every policy and RPC that touches location, friendship or a meet for the
   four cases: self, friend, stranger, blocked. Deleting an account or replacing a
   photo must leave nothing behind (`account_delete`, the `avatar-sweep` worker).
   Contacts leave the phone only as hashes.
2. **Secrets.** Nothing secret in the tree or its history: `apps/ios/Secrets.xcconfig`
   is git-ignored and holds public client values only; server keys live in Supabase
   secrets and `_local/` (ignored).
3. **The meet state machine.** Two phones, flaky networks, app suspended mid-meet: a
   meet must never get stuck, show the wrong partner, or keep sharing after it ends.
4. **Routing safety.** Routes must keep to the skier's ability and avoid closed lifts
   and runs. The app says it is not a safety tool, but a route down a black for a
   green skier is still a serious bug.
5. **Concurrency and performance.** Swift 6 strict concurrency. Every
   `@unchecked Sendable` or `nonisolated(unsafe)` needs a stated reason. Nothing heavy
   runs on the main actor, and the map keeps its frame rate while panning.
6. **Errors.** No `try?` on a path the user started. Failures become
   `PowderMeetError` values with plain words.
7. **Third-party terms.** The Mapbox logo stays on the map, unstyled; attribution is
   shown. Resort trail-map artwork is never committed or shipped.

## Known, not yet fixed

These are in the roadmap; listed here so they aren't reported as discoveries.
- The fake backend is compiled into Release as the developer sandbox's private server
  (decided; the gate in `specs/07-CLIENT.md` section 8 keeps it from being built).
- Runs imported before matcher version 3 keep their old stored match until imported
  again; the "refresh history" re-match in spec 08 isn't built.
- GPS files whose times carry no time zone are read as UTC.

Decided, not findings: the real ski-day GPS logs in
`packages/DescentKit/Tests/DescentKitTests/Fixtures/GPSLogs` are public on purpose
(maintainer, 21 Nov 2026). They carry dates, resorts and tracks, no names.

## Rules while reviewing

- The Supabase project is live. Read it, don't write to it, and never
  run the Supabase CLI against it. Backend tests run locally (`supabase db start`,
  then `supabase test db` in `backend/`).
- Package tests run per package with a scratch path outside iCloud Drive, e.g.
  `swift test --package-path packages/MeetSolver --scratch-path ~/Library/Caches/PowderMeet/spm/MeetSolver`.
  Pipeline tests: `uv run pytest` in `pipeline/`.
- One `xcodebuild` at a time, output under `~/Library/Caches/PowderMeet/`.
- Don't commit or push. The review is a report.

## What to hand back

One list, most severe first. Each finding has:
- **Severity:** blocks the beta, should fix before the App Store, or minor.
- **Where:** `path:line`.
- **What goes wrong:** a concrete case (inputs or steps, then the wrong result).
- **Fix:** one or two lines.

Then, separately, anything in the specs that is wrong or out of date.
