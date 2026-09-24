# Functional pass — September 23, 2026

GitHub `main` is `v1.0.0` plus one squashed commit of the Codex session work
(build 202 on TestFlight); the standalone build-63 bump commit was removed.
The fix pass below shipped as **1.0.0 (203)**: archived Release, uploaded to
App Store Connect with automatic signing (upload succeeded; Apple processing).
Only the known MapboxCommon/MapboxCoreMaps missing-dSYM warnings appeared.

Production readback today: **0 canonical manifests, 0 graph blobs, 0
publications**, 1 profile, 0 meet requests, 0 imported runs. Every mountain
therefore loads its frozen preview map, and live Go To / meetups remain gated.
Whistler is off season (Epic feed) until late November, so a published
dataset would still report off-season rather than route.

Fixed in the app:

- **TestFlight test meetups** (`PreviewMeetupPolicy`): send, accept, and
  activate a two-phone meetup on the preview map, labeled TEST on both phones,
  stamped non-live, status-free, exact-identity only. App Store builds refuse.
- **Preview solves are timeless**: meet previews, rehearsal, and test meetups
  no longer fail in the evening because lift hours applied to preview maps.
- **Meetup test location**: a fresh GPS fix off the mountain no longer blocks
  a tester's chosen location (matches `resolveMyOrigin`).
- **Go To**: a background status merge during an early tap re-solves once
  instead of failing with "conditions changed".
- **Live trail logging while locked**: fixes flow from the location delegate;
  the recorder keeps running during a ski session, re-arms when the toggle is
  switched back on, survives leaving and re-entering the ski area, retries
  offline saves from a per-user queue, and updates Profile stats.
- **Import feedback** is shown inline in Profile → Activity (Apple Health
  errors and empty pulls included), not only as iOS notifications.
- **Weather**: two forecast days (one day ended at resort-local midnight, so
  evening scrubs had no data) and the LIVE readout falls back to the current
  observation instead of "NO FORECAST AT THIS HOUR".
- **Canonical meet replay**: a pinned-version fetch now carries current status,
  so accepting a meet pinned to the live publication no longer fails first.

Applied to production with explicit approval:

- `20260923170000_owner_scoped_activity_data.sql` (via `supabase db push
  --include-all` after a dry run): `imported_runs` was readable by anyone with
  the anon key (`USING (true)`); now owner-only. The recompute RPCs now refuse
  to rebuild another user's data. pgTAP extended. Readback confirmed the
  policies and grants; a rolled-back probe confirmed a cross-user recompute
  fails with 42501 and the owner's own recompute succeeds.
  Exposure: the 365 runs imported between 18:18 and 21:42 UTC today were
  readable with the anon key until the fix. The API gateway logs show only the
  owner's own app (authenticated, PowderMeet/202) touched `imported_runs`
  in that window; no anonymous or GraphQL reads.
- The local file `20260922012500_restore_powdermeet_house_ski.sql` was renamed
  to `20260922012247_…`, the version production recorded for the identical
  statement (it had been applied outside `db push`), so history is in sync.
- `build-resort-graph` v8: requires a service-role token and fails closed when
  manifest rows cannot be read or do not match expected counts (previously an
  RPC error built an all-open, non-canonical graph that publish would accept).
  JWT verification remains enabled; an anon-key call now returns 403.

Still required for live routing: a reviewed canonical manifest per resort
(every routable trail claimed; Whistler has 509 named candidates, 106 unnamed
ways, 15 lift exits with no mapped downhill link and no connector tooling),
then build, publish, and in-season status.

# 1.0.0 (62) testing release — September 21, 2026

The user explicitly authorized GitHub and TestFlight publication after the earlier
hold. Release archive succeeded and App Store Connect accepted build 62 for
processing. This supersedes earlier distribution-hold statements below; it does
not resolve the documented mountain data or physical-device testing gaps.

PowderMeet House was restored to the authenticated ski catalog with the existing
`powdermeet-default` topsheet. No physical ski dimensions or performance bonuses
were invented. The new catalog row was read back as an authenticated user.

Apple accepted the upload with missing vendor dSYM warnings for MapboxCommon and
MapboxCoreMaps; those warnings affect vendor crash symbolication, not upload
acceptance. TestFlight processing/tester availability has not yet been confirmed.

The entries below preserve the implementation and validation history.

# Release held — September 21, 2026

The user requires the original branded UI and functional mountains and mountain
picker before distribution. Simulator test builds have now run to validate the
work. No release archive, phone installation, TestFlight upload, history rewrite,
app commit, push, or GitHub release has been made for these pending changes.

## Latest demo verification — September 21, 2026

Distribution remains on hold until the user tests the app. Nothing was committed,
pushed, archived, or uploaded to TestFlight during this verification.

- Fixed the map starting a second Core Location provider for its invisible puck.
  Mapbox now receives app-owned coordinates through a custom location data model
  supplied at map creation. Browsing a map cannot independently request GPS
  permission or start a second location session. The app's explicit location
  authorization and background-session ownership remain in LocationManager.
- Fixed friend/meet acceptance treating zero-row server updates as success.
  Require an exact returned row and pending-state/recipient guards; meetup
  responses also reject expired requests. Failed optimistic removals restore
  only the affected cards and cannot replace a new account's state.
- Three new real-Supabase-client transport tests pass, including cancelled,
  mismatched and expired requests, permission failures, and successful receipts.
- Deployed database test passed with two temporary authenticated users: friend
  request, both snapshots, acceptance, both friend lists, meetup acceptance,
  cancellation and stale acceptance. All fixtures were rolled back. This does
  not verify physical push notifications or WebSocket delivery.
- Full iPhone suite: 626 executed, 8 optional skips, zero failures.
- The actual iPhone solver decoded all 159 exported source graphs and found
  sampled local routes for 103 resorts. The remaining 56 are unresolved; a
  sampled pass does not establish complete geographic coverage, current terrain
  status, or live navigation readiness.
- Actual Mapbox app rendering was captured for local route previews. Initial
  test-only black rendering was corrected by attaching the test window to the
  simulator's real window scene. Production rendering was not replaced by a mock.
- Source audit finds no glassEffect or thin/regular material backgrounds.

Evidence: `_local/release-validation-2026-09-21/demo/` and
`_local/route-acceptance/`. The source graph export and visual tests are opt-in;
normal app launches keep authentication and service startup unchanged.

The central blocker remains unpublished, reviewed mountain routing datasets
and their operational status. The 103 local samples must not be presented as
103 completed live-routing resorts. End-to-end phone testing remains pending.

## Implemented

- Recovered actual pre-glass source from `7f24eae`, rather than approximating the
  old design. Restored original compact headers, Done buttons, auth screens,
  map controls, full-width mountain bar, profile tabs, skill and terrain choices,
  and sheets. Retained subsequent functional fixes.
- Retained the approved branded ski, one branded typeface, simplified color
  choices, and all eight app icon variants.
- Picker searches names, aliases, full region names, countries, and passes,
  handles whitespace/diacritics, preserves all regional groups, and permits all
  159 catalog selections. Removed unsubstantiated hard-coded map completeness
  ratings and the obsolete disabled-mountain list.
- Corrected 36 misplaced geographic bounds. Their completed immutable snapshots
  are stored under `2026-09-20`; the server and baked per-resort pins agree.
  Evidence: `tools/resort_bounds_review.json`. This is geographic source evidence,
  not canonical trail-inventory approval.
- Large-mountain loading follows real progress rather than giving up after 12
  chunks. It rejects stalled jobs, changed snapshot identities and invalid
  progress; cancellation is preserved.
- Memory/disk preview caches must match the mountain, snapshot pin and current
  graph builder. A failed request cannot resurrect an old empty/wrong-area map.
- The snapshot query now includes explicitly mapped ski connections (previously
  omitted), records extraction version 2, and is covered by a regression test.
  Existing frozen snapshots require a new controlled extraction before routing
  review; this does not mutate already pinned source files.
- Source fetches reject partial Overpass responses and use bounded fallback
  attempts. Elevation fetches retry temporary errors and reject missing samples.
- Fixed tiny negative aspect variances in both graph builders; graph version was
  v14. The subsequent v15 corrections and validation are recorded below.
- Corrected the OpenSkiMap importer’s domain, worldwide-file filtering and modern
  OSM source identifiers. Disconnected lines are no longer concatenated into
  fabricated geometry. OpenSkiMap and Overpass are not independent evidence.

## Validation

- 61 shared server tests passed.
- 44 canonical-ingest Python tests passed.
- The isolated Swift progress policy passed interpreter checks for large mountains,
  stalled jobs, regressions and invalid counters. That early interpreter-only check did not compile the app; later simulator checks are recorded below.
- The latest simulator suite executed 616 tests: 610 passed, 6 opt-in tests
  skipped, no failures. This includes picker search, snapshot progress, location
  sessions, graph integrity, and provider identity regression tests.
- All migrations replayed in an isolated local database; all 45 pgTAP assertions
  passed. Colima mount incompatibility made the CLI test wrapper discover zero
  files, so the actual pgTAP file was copied into the isolated database and run
  directly with error-stop enabled; every assertion and the plan were checked.
- Inspected captured auth, appearance, and mountain-picker views: original red/
  charcoal branding, eight icon variants, no font picker. Full interactive app
  verification remains pending because the host Mac is locked.
- All 159 source maps downloaded, and all 159 parsed graphs pass numeric,
  identity and geometry integrity checks (zero failures). This does not test
  geographic completeness or route reachability.
  Local current reports: `_local/resort-rollout/coverage.json`,
  `_local/resort-corrected/coverage.json`, and
  `_local/resort-rollout/graph-audit.json`.
- Server readback confirmed all 36 corrected snapshot pins and both source files
  for each corrected mountain. A final backend readback confirmed 159 active
  OSM/elevation pairs and 36 corrected pins. Combined result with source hashes:
  `_local/resort-rollout/final-readiness.json`.

## Still prevents release

1. Refresh source snapshots with the corrected ski-connection query and review
   complete geographic coverage. Downloaded snapshots are not proof that every
   trail, lift or sector is represented. Some combined ski areas still need
   boundary/ownership review.
2. Review actual trail/lift identities, source geometry and usable connections
   for every mountain. Many lift exits lack an explicit downhill link. Do not
   invent connections or mark candidate source inventories as reviewed.
3. Publish validated canonical mountain datasets and matching operational status.
   Direct backend readback found **zero canonical manifests and zero graph blobs**.
   The canonical publication/rendezvous schema migrations are now deployed.
   Whistler has local curated fixtures, not a published production dataset.
4. Go To currently reports why routing is unavailable; that is an error-handling
   repair, not completed routing. Complete routes require the preceding data.
5. Complete interactive app and physical background-session checks after the
   source-data work. Automated app tests and selected visual captures now pass;
   this is not proof that every resort can route. Then preserve a local history
   backup, make the one-commit GitHub history, and archive/upload TestFlight.

The previous v1.0.1/build 61 release does not satisfy these requirements.

## September 20 release request follow-up

The requested release is now prepared as marketing version **1.0.0**, build
**62** (the build number stays above the previously distributed build 61).
This version edit is not a build, release, tag, or claim of readiness.

Before deployment, a production readback on September 21 UTC returned zero
canonical manifests, zero graph blobs, and no publication or rendezvous tables.
The tables have since been deployed; datasets are still unpublished.
The existing graph audit flags 1,672 lift exits without an explicit immediate
downhill link across 155 of 159 source graphs. These are review flags, not
validated missing-route counts; the frozen source files predate the corrected
connection query, so refreshed source geometry must be assessed before any
connection decisions.

Do not replace the GitHub release or squash/push the app history until the
preceding routing and app checks pass. The requested final GitHub history is
one 1.0.0 commit; preserve a recoverable local backup before rewriting it.


## September 21 implementation and deployment

- Fixed stale UI presentation tests after removal of the glass section picker.
- Fixed incorrect Windham-to-Hunter feed attribution and real provider names
  with trailing spaces; regression tests cover cross-resort and summer exclusion.
- Deployed all eight previously pending database migrations in repository order.
  Readback confirms all eight; a second dry-run reports the database up to date.
  Application public tables retain RLS. Publication and rendezvous tables exist.
- Deployed `build-resort-graph` version 6, `get-resort-graph` version 3, and the
  previously outdated `refresh-live-status` implementation. Graph format is v14;
  JWT verification remains enabled. The hourly status schedule is active.
- Deployed-service smoke checks: Whistler correctly returns no published dataset;
  status refresh returns `no_resorts`. There are still zero active canonical
  datasets. These results verify deployment, not usable navigation.
- Source refresh: Kashimayari completed a staged September 21 snapshot with
  extraction version 2. It has one connected graph, but 14 of 15 downhill ways
  have no source name. Official lift names corroborate five source lifts; the
  official status page's last terrain update is March 23, not a current status.
- Whistler edge extraction repeatedly failed on upstream timeouts/504. An
  operator-side extraction completed, retaining its June 1 upstream timestamp
  and reusing terrain elevations only at exact coordinate keys. No snapshot pin
  was changed. Its query returned zero explicit connection ways; the graph has
  85 components and 16 lift-exit review flags. Both refreshed graphs pass numeric
  integrity; neither has been approved as a canonical dataset.
- Evidence-pinned resort reviews are saved under
  `tools/canonical_ingest/reviews/{whistler,kashimayari}-2026-27.json`.
- Server live-status mappings cover 30 of 159 catalog IDs. The alternate
  MtnPowder feed lists 147 entries, but only 38 include terrain areas (including
  summer entries); a provider name alone does not establish usable coverage.

Still required: verified identities, real source connections and safe rendezvous
locations; canonical publication; operational-status integrations for uncovered
resorts; complete interaction/device verification. Unreviewed inventories,
proximity-based graph links, or fabricated open statuses must not be used to
make the release appear complete.


## September 21 routing root-cause corrections (v15)

This supersedes the v14 connectivity figures above, not the requirement for
canonical review. No archive, TestFlight upload, GitHub commit or release was made.

- Both source parsers now exclude `area=yes` piste footprints from route graphs.
  Whistler had 69 such polygons; following their perimeters created false routes
  and misleading isolated components. Centerlines remain unchanged.
- Private/no-access routes are excluded, with ski-specific access taking
  precedence. Whistler's private Kadenwood Gondola is no longer public routing.
- Explicit `oneway=no` lift geometry now supports both directions. This fixes
  return travel on source-tagged gondolas including Peak 2 Peak. Source identity,
  geometry, one queue per direction, and complete ride time per direction are
  preserved through source splitting and canonical overlay reconciliation.
  The app also retains the permission through both elevation-enrichment paths.
- Legacy preview overlays now recognize `_vx`/`_rev` source IDs and allocate
  reviewed lift durations across segments instead of charging a full ride per
  segment. This does not promote previews to canonical navigation.
- Added server-side MtnPowder terrain integration for 16 explicitly matched
  catalog resorts: **46 of 159** now have configured status providers. All 16
  were checked against the real feed; summer-only/forecast-only/wrong-resort,
  incomplete combined areas, stale/future updates, and ambiguous names fail
  closed. Source observation time bounds expiration. A mapping is not proof of
  canonical publication or current ski operations.
- Re-ran all 159 source graphs: zero construction/integrity failures. Whistler
  now has **17 components and 15 lift-exit review flags**, down from 85 and 16.
  Across the catalog there are 1,669 lift-exit flags in 155 resorts, and 157
  resorts have more than one weakly connected component. These are review flags,
  not 1,669 confirmed missing trails. Reverse gondola edges cannot hide them.
  Reports now include exact source way IDs, terminal IDs, and coordinates.
- Corrected the geometry review tool's invalid Flask import, which previously
  claimed Flask was missing even when installed.
- Validation: **621 app tests executed, 6 skipped, 0 failures; 73 server tests;
  46 import tests**. All three changed backend entry points type-check.
  Full app regression tests caught and verified the elevation flag preservation
  fix. Prior database validation remains 45 passing assertions; no new schema
  changes were required.
- Deployed and read back active `build-resort-graph` version 7,
  `get-resort-graph` version 4, and `refresh-live-status` version 5; JWT
  verification remains enabled. Build/get now use graph format v15. The
  production canonical-resort count remains zero.

### Remaining execution path

1. For each resort, compare its exact source ways with its current official
   trail/lift inventory; separate footprint-only, private, closed, unnamed, and
   genuinely disconnected terrain. The source review records retain hashes and
   source timestamps; extraction date is not observation date.
2. Resolve each lift-exit flag using an actual mapped connector or a reviewed
   source trace anchored to exact existing source nodes. Verify boarding and
   unloading directions. Do not connect the nearest line automatically.
3. Reconcile canonical identities and safe stopping landmarks, then stage/build
   the immutable manifest and publish the exact successful content hash.
   Verify expected cross-sector trips, closures, ability limits and Go To using
   that published dataset. Repeat for every catalog resort.
4. Add and validate trail-and-lift status adapters for the remaining **113**
   resort IDs; lift-only or forecast feeds cannot substitute for trail status.
5. Finish interactive app checks and physical background-location checks on the
   unlocked Mac/phone. Only after acceptance: preserve recoverable history,
   produce the requested single 1.0.0 commit, and upload build 62 to TestFlight.

The immediate Go To blocker remains **zero published canonical datasets**.
The fixes above remove actual software defects; they do not approve missing
source geometry or establish that all resorts are ready.


## Fresh Apple app and clean GitHub release — September 21 request

Requested sequence remains: finish routing and device acceptance first, then
one GitHub commit and a clean 1.0.0 release. A new Apple record does not fix or
replace the missing routing datasets.

### Preserved before cleanup

A verified Git bundle of all local refs, binary working-tree patch, copies of
all 21 then-untracked files, remote refs, and complete v1.0.1 release metadata
are in `_local/release-reset-backup-2026-09-21/`. No refs were rewritten.
GitHub currently has one release, `v1.0.1` (build 61), with no binary assets.
No release, tag, Apple app, or tester group has been deleted or renamed.

### Existing record versus fresh identity

The existing bundle ID is `com.powdermeet.PowderMeet`, team `28LJG7MXT3`.
Apple's removal instructions state that removing an app releases its name and
that an uploaded bundle ID and old SKU cannot be reused for another record.
Expiring builds stops new tester installation; it is not a new app identity.

A fresh record can retain the display name **PowderMeet**, subject to name
availability, and start at **1.0.0 (1)** with a newly registered bundle ID and SKU.
Candidate identifiers (not yet registered or applied): `com.powdermeet.ios` and
`PowderMeet-iOS-2026`. The existing-record path remains **1.0.0 (62)**.

Before retiring the old record:

1. Inspect its App Store/TestFlight state, tester groups and Apple sign-in
   grouping. Rename/retire the old listing only as part of securing the exact
   PowderMeet name for the replacement; do not delete first and assume reuse.
2. Register the new app ID with Push Notifications, Sign in with Apple and
   HealthKit, create its provisioning profiles, and create the new app record.
3. Update app/test identifiers and signing. Add the new Apple audience to
   Supabase auth; preserve/group Apple user identity as appropriate after
   inspecting the account. A new installation does not inherit local app data.
4. Push currently uses one `APNS_BUNDLE_ID` for all stored device tokens. New and
   old bundle tokens must not be mixed under a single topic: migrate token
   ownership or isolate the new app's token registrations before switching.
5. Both installed apps would claim `powdermeet://reset`. Retire the old device
   installation or use distinct verified callback routing during transition.
6. Validate sign-in, password recovery, push, HealthKit, location and routing
   on the new identity; then upload 1.0.0 (1) and recreate its tester access.
   Only then expire/retire the old app record as requested.
7. With functional acceptance complete, create a single parentless 1.0.0
   commit from the reviewed source, update main with a lease against the
   recorded remote head, remove superseded GitHub release/tag references,
   and create only the matching 1.0.0 release. Keep the local recovery bundle.

Current Apple-account blocker: computer-control permission is not granted,
so App Store Connect could not be inspected. No configured App Store Connect
API credentials were found in the standard local locations or release
configuration. APNs keys are not App Store Connect API credentials.

Authoritative Apple instructions checked September 21:
- https://developer.apple.com/help/app-store-connect/create-an-app-record/remove-an-app/
- https://developer.apple.com/help/app-store-connect/test-a-beta-version/stop-testing-a-build/
