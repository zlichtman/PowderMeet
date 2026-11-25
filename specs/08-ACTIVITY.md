# 08 Activity and pace learning

## 1. Scope

Parsers, descent detection, live recording, Apple Health import, one-row-per-descent
history, trail matching as a re-runnable derivation, and a simple server-side pace
model that visibly affects ETAs. No equipment cohorts, no client-side blending
(DECISION 4). Section 4.1 calibrates the profile's baseline on the phone from the same
evidence; the server model (4.2) is measured against that baseline.

## 2. DescentKit

- `ActivityImporter.importActivity(fileName:data:) -> ImportedActivity` is the one call
  the app makes for a file. It detects the format (by extension, then by content, so a
  mislabelled file still imports), parses, segments, and returns the descents with the
  source app, the file's own totals (`DeclaredTotals`) and a list of `ImportWarning`.
  It throws `ActivityImportError`, every case of which the import screen can show:
  `unrecognizedFormat`, `unreadable`, `noTrack`, `noTimestamps`, `noElevation`,
  `noDescents(reason)`. An import never crashes and never returns an empty result.
  `ActivityImporter.importRecording(_ ParsedActivity)` does the same for a recording that
  is not a file (an Apple Health route), keeping the activity's `source`; its
  `ImportedActivity.format` is nil.
- `ActivityParser` implementations: `GPXParser`, `TCXParser`, `FITParser`,
  `SlopesParser` (zip + SQLite + metadata) and `SkizParser` (Ski Tracks: zip with
  `Nodes.csv`, `Segment.csv`, `Track.xml`). Foundation, `CSQLite` and `CZlib` only.
  Parsers report what the file says, including the app or device that wrote it (GPX
  `creator`, TCX creator, FIT manufacturer) and any run list. FIT developer fields that
  carry altitude or speed are read; FIT laps are reported as a declared count only,
  because watches' lap counts are not reliable run counts. Ski Tracks has no entry in
  the `source` list of `02-DOMAIN.md` section 8, so its descents are stored as `gpx`.
- `DescentSegmenter.segments(_ activity: ParsedActivity) -> [Descent]`: one segmenter
  for imports and live recording (the live recorder feeds a rolling buffer into the
  same function). It ignores track, segment and lap boundaries and finds runs in the
  points: elevation smoothed over ±8 s, climbs and descents separated by a 20 m
  reversal, each descent trimmed to where the skier is moving. A pause never splits a
  run and a lift ride always does. A descent is not a run when it is a drive (fast on a
  shallow grade), a lift or gondola ridden down (slow, steady, straight), too small or
  too slow. A provider's own run list (Slopes, Ski Tracks) decides which stretches are
  runs wherever the track agrees; listed runs that are drives or lift rides are
  dropped, a listed run that hides lift rides is split into its laps, and clear runs
  the list missed are added. Run ends always come from the track, so the same day gives
  the same descents whichever app it comes from.
- Top speed (`GPXSpeedStats.peakSpeed`): the highest speed held for at least 3 s, that is
  the maximum over every 3 s window of the lowest phone-reported speed inside it, so a
  one-fix GPS spike cannot become a run's top speed. A file with no speed values uses
  straight-line distance over 4 s windows, and a window counts only when the window one
  fix later agrees. A speed the file itself states (Slopes' `topSpeed`) is kept only when
  it is no more than 3 m/s above the held speed. Nothing is above 30 m/s. On the corpus
  no run is more than 3.4 m/s above Slopes' own figure; it may be lower, because Slopes
  does not require the speed to be held.
- Elevation: fixes without it are interpolated in time and the import is flagged when
  5 % or more needed it. A file with none, or whose elevation spans under 1 m, is imported only if
  it carries a provider run list, flagged `elevationMissing`; otherwise it fails with
  `noElevation`. Times with no zone are the clock at the resort: the parser reads them
  as UTC and flags them (`timeZoneAssumedUTC`), and once the track places the file at a
  published resort `ImportedActivity.readingUnzonedTimes(in:)` reads them in its zone
  and drops the flag. With no resort around the track they stay UTC and flagged.
- The corpus (`packages/DescentKit/Tests/DescentKitTests/Fixtures/GPSLogs/<format>/`,
  listed in that folder's `README.md`) is 37 Slopes days and 2 Garmin GPX days.
  `expected.json` holds, per file, the source app, the descent count and the total
  vertical, and whether that truth is the file's own run list or a hand reading of the
  elevation profile. It never holds this package's output. Tolerance: descents within
  1 (or 5 %), vertical within 8 %; and with the Slopes run lists ignored, within 2
  descents (or 10 %).
- `DescentHasher.contentHash(_ descent: Descent) -> String`: SHA-256 of the track
  normalized to 1 Hz, coordinates rounded to 1e-5, elevations to 1 m, times to the
  second, after trimming stationary head and tail. It identifies a re-import of the
  same file. It does not survive a second app's export, which rounds times and
  positions differently.
- `DescentDeduplicator`: recognises a descent already in the history from another app
  or device. Two descents are the same run when the time they share is more than 60 %
  of the shorter one and their tracks are within 60 m (median) over that time. The
  client runs this before upload. The server also dedups on time overlap > 80 % with
  an existing descent of the same owner.
- `TrailMatcher.match(descent:in bundle:) -> DescentMatch`: hidden Markov map matching
  (Viterbi over the run and connection edges within 50 m of each fix, resampled every
  10 m, plus an off-map state; a state costs its distance and heading disagreement, a
  step costs the mismatch between the route along the graph and the distance the fixes
  moved, and moving onto another trail, by its bundle group or else its name, costs
  more than onto the next way of the same trail, so drift does not walk a track onto
  a parallel trail and back). The main trail is the one advanced furthest along
  the graph, so a stop or jitter on the spot does not decide it. In the sections, a
  blip off the map under 20 s between two stretches of one trail stays on that trail,
  and a trail touched for under 10 s between two stretches off the map was crossed,
  not skied. Ways that touch without a shared node may be joined at a penalty, and a
  stretch off the map is an unnamed section, not a rejection: the stricter rule (one
  directed connected run sequence or nothing) rejects a whole descent for any one
  such moment and matched only 26 % of the corpus. It produces
  `[MatchedEdge]` with enter/exit times, moving and stopped seconds, the ordered
  `RunSection`s of the whole descent (each named or unnamed trail, connection or
  off-map stretch with its times, which the activity log and per-run pace read),
  coverage (share of the distance on the map; under half is no match) and a
  confidence in [0,1] that is documented as a score, not a probability;
  `MatcherVersion` increments on any change.
- `PlaceLocator(bundle:)` and `locate(_ SkierPosition, after: PlaceReading?) ->
  PlaceReading`: the run or lift a single position is on, for labels (rules in
  `02-DOMAIN.md` section 7). It shares the matcher's `SegmentGrid`, built once per bundle.

### 2.1 Live recording

- `LiveRunBuffer` (DescentKit, a `Codable` value) takes fixes one at a time (accuracy
  50 m or better, at most one a second) and every 30 s of track runs `DescentSegmenter`
  over what it holds. A run is handed out only once it is closed: a climb of 30 m after
  its end (a lift), a gap of 10 minutes without fixes (where the segmenter cuts anyway),
  or `flush()`. A pause at the bottom never closes a run, because the skier may carry on
  down; this keeps one run from being uploaded twice in two lengths. Nothing that starts
  before the last handed-out end is handed out again.
- `LiveRecorder` (AppCore actor, one per signed-in user while recording is on) reads the
  phone's own fixes (`LocationProvider.deviceFixes`: a developer teleport or rehearsal
  is never recorded), records only at a published resort (`ResortVicinity`: enter within
  1 km of its bounding box, leave beyond 2 km), flushes on leaving, and stores closed
  runs with `ActivityLibrary.storeLive` (source `live`, the same match, duplicate check
  and upload as a file, the check against the newest 200 stored runs; offline, the
  outbox). The buffer and the day's figures are written to one file
  per user, so a relaunch resumes; turning recording off flushes, stores and removes it.
- The on/off choice is kept on the phone per account (it is about this phone's GPS, and
  two phones recording one skier would only be deduplicated), and survives relaunch.

### 2.2 Apple Health

Downhill skiing and snowboarding workouts with a route (Apple Watch, Slopes, Strava,
Garmin Connect write them) are read with read-only HealthKit access and imported with
`ActivityLibrary.importRecordings` (source `healthkit`). The first read takes all of
them; later reads start a day before the last one. HealthKit does not say whether
access was refused, so an empty read says how to allow it. A workout whose route
cannot be read is counted and reported; that read does not move the starting point of
the next one, so the workout is read again.

### 2.3 Backup (`.powdermeet`)

`ActivityLibrary.exportBackup(user:)` writes `ActivityBackup`: JSON
`{"powdermeet_backup": 1, "created_at", "app_build", "descents": [...]}` with the marker
first, each entry a stored descent as `descent_upsert` took it (`content_hash`, `source`,
`started_at`, `ended_at`, `resort_id`, `device`, `stats`, `track` in base64), read a page
at a time with `descentRecords(offset:limit:)`, plus the runs still waiting in the
phone's outbox. That is everything the user made that is not derived: matches are
re-run against the current map on import, the pace model is recomputed from the
descents, and the profile, friends and meets belong to the account. History reads at most
`ActivityLibrary.historyLimit` (5,000) descents; the backup reads pages until a short
one comes back, so it holds every stored descent. The file is for
leaving an account (deleting it deletes the descents) and for runs that never reached
the server; a new phone signed in to the same account has the rest already.

In the app: Activity → Data → Back up writes the file to a temporary folder as
`ActivityBackup.fileName(on:)` and opens the share sheet; the copy is removed when the
sheet closes. The type is exported as `com.powdermeet.backup` (extension `powdermeet`,
conforming to `public.json` and `public.data`) with a document type, so a backup opened
from Files or Mail arrives through `onOpenURL` like any activity file, and the Import
picker accepts it.

`importFiles` recognises a backup (extension `.powdermeet`, or either format's marker)
and restores it instead of parsing GPS. Restoring adds and never replaces: an entry is
sent with its stored `content_hash` and track bytes unchanged, and one the account
already has by hash or by time is skipped, so importing a file twice adds nothing. A
damaged entry, or one the server refuses as `invalid`, is skipped and counted.

Backups in the older PowderMeet format (`export_schema_version` 1 to 5, non-finite
numbers written as `"nan"`, `"+inf"`, `"-inf"`) are read too. Their runs carry no GPS,
so each becomes a descent with an empty track (`DescentTrackCodec.encodeEmpty`),
`started_at = run_at`, `ended_at = run_at + duration_s`, the content hash SHA-256 of
the fixed prefix `ActivityBackup.legacyHashNamespace` and the run's `dedup_hash`, its
figures, trail name and difficulty in `stats`, no match and no `pace` (its trail was
matched on a different map, so it does not teach calibration). A source
`DescentSource` has no name for is stored as `gpx`. The file's profile, stats and
photo are not restored: the account has its own. Because the server also dedups on
time overlap, a restored run keeps the real recording of the same run, imported later,
from being stored.

### 2.4 Bad and hostile input

- A live run closes on a climb only when three fixes in a row sit 30 m above its last
  known bottom height (a lift); one altitude glitch does not close a run.
- A height outside −500 to 9,000 m, or more than 50 m from the median of the four
  known heights either side (more when those are far apart in time, at 15 m/s), counts
  as missing and is interpolated.
- A fix kept without a speed check (the first, or the first after a 90 s gap) that
  the next three mutually agreeing fixes all find impossible is dropped, not them.
- A file whose named sport is a bike ride or a run (GPX track `type`, TCX
  `Activity Sport`, FIT `sport`) fails with `noDescents(onlyVehicleOrLift)`; a file
  that names no sport, or names walking or hiking (it may be a ski tour), imports.
- An archive entry over 64 MB, a run list whose windows together hold more than twice
  the track, or a legacy database read that passes 50 million SQLite steps or
  2 million rows fails as `unreadable`. Slopes and Ski Tracks entries are found by
  name inside any folder, and `__MACOSX/` and `._` entries are ignored.

## 3. Upload and storage

- `AppCore.ActivityLibrary` is the import path: for each file it calls
  `ActivityImporter`, resolves each descent's resort (the published resort whose
  bounding box holds the middle of the track), opens that resort's active bundle
  (cached, else downloaded and verified), matches, and uploads. A descent already in
  the history by content hash is sent again so its `stats` refresh; one that repeats
  a stored descent by time (`DescentDeduplicator`, time only, since stored tracks are
  not read back) is skipped. The file's result is a `FileReport` in plain words.
  `importFiles` reads, parses and matches up to `ActivityLibrary.importConcurrency` (3)
  files at once, then de-duplicates and saves them one at a time in the order given,
  because two files can hold the same day; the reports, the saved runs and the progress
  count are the same as one file at a time. Each resort's bundle is opened once per
  batch, however many files want it. Cancelling stops before the next file is saved;
  runs already saved stay.
- Client calls `descent_upsert` with the descent once per descent; idempotent on
  `(owner_id, content_hash)`. Offline uploads queue in `OutboxQueue`. The track is
  `DescentTrackCodec`'s gzip of `{"v":1,"t0":<unix s>,"p":[[dt_s, lat, lon, ele_m|null],…]}`.
- The upload carries `stats` (`02-DOMAIN.md` section 8). The history screen, the four
  lifetime figures on the Profile and the calibration below read `stats` from
  `descents`; none of them needs a track.
- The server stores raw descents. Matching runs on the client only, in `DescentKit`,
  so there is one matcher implementation. The client computes the match for its
  current bundle and sends it inside the same `descent_upsert` call (the optional
  `match` object); the server stores it in `descent_matches` keyed by `(bundle_id,
  matcher_version)` and recomputes aggregates in the `pace_recompute` job.
  Re-matching after a bundle or matcher change happens on the client the next time
  the descent is viewed, or on an explicit "refresh history" action, and is uploaded
  the same way. `stats.matcher_version` is the `MatcherVersion` the run was named and
  paced with (absent before version 3). After each history load the app re-matches,
  in the background and one run at a time, every stored run with an older or no
  version whose resort's map is on the phone (`ActivityLibrary.rematchOlderRuns`): it
  sends the stored track and content hash again with the new match and `stats`, so the
  row is updated, never duplicated, and a pass cut short resumes where it stopped. A
  run whose track has no points is only stamped with the version.

## 4. Pace model

### 4.1 Baseline calibration (client)

Imported runs reach ETAs at once through the profile: after every history load the app
recomputes `profiles.baseline_speeds` with `PaceCalibration` and saves it when it
changed.

```
observed[d]  = Σ length_m / Σ moving_s over stats.pace[d] of every descent
baseline[d]  = preset[ability][d] × clamp( (n_d · observed[d] / preset[d] + 8) / (n_d + 8), 0.5, 1.6 )
```
`n_d` is the number of descents with evidence for difficulty `d`. The result is always
derived from the ability preset and the whole history, never from the stored value, so
importing twice, deleting and changing ability cannot drift it; a difficulty with no
evidence keeps the preset and a difficulty the ability has no pace for is never added.
The Profile says how many runs it used ("calibrated from N runs"). Only matched
descents teach: a run at a resort with no bundle has no `pace`.

The server model below measures its `difficulty_factor` against this calibrated
baseline, so the two do not double-count: on the phone's own evidence the factors start
near 1, and they carry what the baseline cannot (per-edge pace and the stop rate).

### 4.2 Server model (SQL `pace_recompute`, migration 0015)

Inputs: `pace_observations` derived from `descent_matches` (per matched edge: elapsed,
moving, length, observed_at, the edge's difficulty as the phone sent it, conditions_id
when available). `baseline[d]` is the owner's `profiles.baseline_speeds`. An
observation is used when it has a difficulty with a baseline, at least 5 s moving and
20 m long; its speed ratio is clamped to 0.3...3. A stop is an edge whose elapsed time
exceeds its moving time by 20 s or more; the stop rate shrinks toward the solver's
default 0.4 per km. `pace_recompute_drain()` runs the queued jobs every minute.

```
difficulty_factor[d] = shrink( mean over edges of difficulty d of (observed_speed / baseline[d]), n_d, k = 8 )
edge_factor[e]       = shrink( mean over observations on e of (observed_speed / (baseline[d(e)] × difficulty_factor[d(e)])), n_e, k = 5 )
stops_per_km         = shrink( total stops / total km, n_descents, k = 10 )
shrink(x, n, k)      = (n · x + k · 1.0) / (n + k)         // toward neutral 1.0 (or default stop rate)
```
Observations older than 2 seasons are down-weighted by half per season. Conditions
enter as a multiplicative adjustment applied at solve time from the solver's
conditions multiplier, not as a partition key. The result is one `pace_models` row per
owner, recomputed within a minute of a new descent.

## 5. Explanation

The app shows "Your ETA" explanations from the model: "you ski blues 12 % faster than
the default; 1.8 stops per km". Friends see only the aggregate through
`pace_models_friend_read`.

## 6. Tests

- One corpus test over `expected.json` (descents and vertical per file, within the
  tolerance above), and the same Slopes days with the run list ignored.
- One test per import bug fixed, on synthetic tracks; one corpus day re-exported as
  GPX, TCX, FIT and Ski Tracks must be recognised as the same day.
- Matcher direction and ambiguity tests.
- pgTAP: `descent_upsert` idempotency and overlap dedup; `pace_recompute` on a fixture
  set produces expected factors within tolerance; friend can read the model, stranger
  cannot; raw descents are owner-only.

## 7. Badges

Achievement badges on the profile (`Badges` in AppCore; the full list with its artwork
brief is `docs/BADGES.md`). 42 badges in six groups; eleven have three tiers (bronze,
silver, gold). Nothing about them is sent, and only which have been announced is
stored (below): `Badges.earned` works them out
from `ActivityHistory` each time, with the meets reached, the catalog's country,
passes and zone for each resort, whether the pace model has a backed level, and
whether the build is a beta. So a badge always agrees with the logs, a deleted log
takes its badges with it, and friends do not see each other's badges yet.

The meets reached are read from the server (`meet_history`, the 200 newest meets of
any status) on sign-in, after a meet ends and on reconnecting after a failed read,
and held in memory only (`AppModel.meetHistory`): the server keeps the record, and a
partner's deleted account takes its meets with it. A meet-up reached is a meet the
server completed with `end_reason = 'arrived'` (both skiers there); one ended by
hand, even side by side, is not (`Badges.reached`). Until the first read the meet
badges count nothing, rather than none reached.

Earned today (26): First Meet (one meet-up reached); Crew (3, 10, 25 different
friends met); Regulars (10, 50, 100 meet-ups); First Chair Crew (one reached before
9:30 on the resort's clock, from `ended_at` and the catalog's zone); First Tracks; Explorer (3, 10, 25 resorts);
Passport (2, 4, 6 countries); Home Mountain (10, 25, 50 days at one resort); Epic and
Ikon; Green Light (25 greens), True Blue (50 blues), Black Diamond (25 blacks), Double
Trouble (10 double blacks); Century (100, 500, 1,000 runs); Vertical (10,000, 100,000,
1,000,000 ft); Everest (29,032 ft in a day); Marathon (26.2 mi in a day); Long Hauler
(100, 500, 1,000 mi); Need for Speed (40, 50, 60 mph); Opening Day (a day from
September to November); Closing Day (May to July); Regular (5, 20, 50 days in a
season, which runs July to June); Streak (3, 5, 7 days in a row); Logbook (10 days);
Proven; Early Adopter. A day skied at two resorts is one day.

A badge earned, or a tier reached, is announced once: after each history load (an
import, a live run stored, a sign-in) and once the catalog is on the phone, which
Passport and Epic and Ikon read, `BadgeMoments.check` compares the standings with the
keys this phone has seen for the account (`activity.badgesSeen.<user>` in
UserDefaults, a badge's id or `<id>.<tier>` for every tier reached) and the app posts
one message in the transient-message slot, a rosette and "New badge · Silver
Explorer" (two or three names, else the first two "and 2 more"), read out by
VoiceOver as it appears. With nothing stored yet (the first launch of a build that
announces badges, a new phone) everything already earned is stored and nothing is
said. The stored set only grows, so a deleted log earned again is not announced
twice; a deleted account removes it (`aBadgeIsAnnouncedOnceWhenItIsFirstEarned`).

The thresholds are imperial, and they are what earns a badge. A skier who reads metric
(Settings → Appearance → Units, lengths and speeds apart as `UnitChoice` splits them)
sees the rules and counts in metres, kilometres and km/h (`Badge.rule(in:)`,
`Badges.Earned.progress(in:)`): the imperial figures converted, not rounded to friendlier
metric ones (Vertical's first step is 3,048 m, Everest 8,849 m, Marathon 42.2 km), the
count rounded down and the step up so a row never reads as reached before it is.

The other 16 are listed and marked "Soon" (`Badge.isLive` false): Right On Time
(the partner's arrival time is unreadable once a meet ends), Summit Meeting and Lodge
Lizards (the place's kind is in that resort's map, not the meet row), Found You and
the weather badges (no weather is kept with a meet or a ski day: the client reads
only the latest conditions), and the ones that need tracking or per-run terrain
(Whole Mountain, Halfway There, Lift Collector, Steep Seeker, North Face, Mogul Hound,
Corduroy, Bell to Bell). Regulars and Crew count within the 200 newest meets the
server returns.
