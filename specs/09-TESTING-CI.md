# 09 Testing and CI

> Testing is lean: `AGENTS.md` "Tests" lists what is written, and overrides this
> matrix. There is no protocol simulation, UI test, benchmark or nightly job. CI runs
> on GitHub Actions on push to `main`, filtered by path.

## 1. Matrix

| Layer | Tests | Runner | Trigger |
|---|---|---|---|
| Packages (Support, MountainCore, MeetSolver, DescentKit, MapScene, PowderMeetAPI, AppCore) | `swift test`: unit, goldens, properties | GitHub Actions `ubuntu-latest` (`swift:6.2` container), one job that tests each package in turn. `MapboxAdapter` and `SupabaseBackend` need Apple frameworks and are built only by the app | push to `main` touching `packages/` |
| Backend | `supabase db start` → `db reset` → pgTAP (`supabase test db`) against the local database only; a second job type-checks, lints and tests the edge workers with Deno | `ubuntu-latest` | push to `main` touching `backend/` |
| Pipeline | pytest (determinism, goldens, thresholds, reconcile) and Whistler through the CLI from its frozen extract | `ubuntu-latest` | push to `main` touching `pipeline/` |
| App | `xcodebuild build`; TestFlight archive | the maintainer's Mac | before each TestFlight upload |
| Device | checklist below | the maintainer | before each TestFlight that changes meet or navigation |

Package tests are the default inner loop and need no simulator. Nothing in CI loops
the simulator.

## 2. Workflows

- `.github/workflows/packages.yml`: every package in turn on one Linux job.
- `.github/workflows/backend.yml`: Supabase CLI, local database, pgTAP; Deno checks and tests of the workers.
- `.github/workflows/pipeline.yml`, `publish-resort.yml` and `build-all.yml` (05-PIPELINE section 3). `build-all.yml` and `publish-resort.yml` run only when started by hand.

## 3. Device checklist (per published resort)

1. Fresh install, sign in, onboarding, location "always" prompt appears only when
   navigation starts.
2. Resort appears in the picker with its status mode; map renders offline after one
   load (airplane mode).
3. Two phones, two accounts, friends: presence visible both ways within 5 s; a third
   account that is not a friend sees nothing.
4. Propose → accept → both navigating; audio prompt on first maneuver with screen
   locked.
5. Kill app A; relaunch → same meet resumes. Airplane mode on B for 5 min → A shows
   "last seen".
6. Inject a closure on the hosted project (`resort_status` row) → reroute or
   `status_blocks_route` within 2 min on both.
7. Arrive; confirm; both show completed with times. `client_events` shows the funnel.
8. Record a run; it appears once in history; re-import the same run from a Slopes file;
   still once.
9. Export the flight recorder; attach to the test notes.

## 4. Fixtures

- `packages/MountainCore/Tests/Fixtures/whistler-blackcomb.<sha>.json.gz` and
  `bundle.schema.json`.
- The solver's reference scenarios, built in code in `packages/MeetSolver/Tests` on
  small synthetic bundles.
- `packages/DescentKit/Tests/DescentKitTests/Fixtures/GPSLogs/<format>/*` + `expected.json`
  (one folder per file type; `Fixtures/README.md` lists what each log covers).
- `backend/supabase/seed/` test users (self, friend, stranger, blocked) and one
  published resort.
