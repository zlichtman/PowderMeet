# GPS corpus

Real ski days recorded by the maintainer, read by `CorpusTests`, `ImportTests`,
`MatchQualityTests` and the AppCore activity tests. `expected.json` holds the truth
for each file (descent count and vertical, from the file's own run list or a hand
reading of the elevation profile) and the digest of every descent's content hash.

Logs sit in one folder per file type (`slopes/`, `gpx/`; `fit/` and `tcx/` when a real
one is added) and are named `<date>-<resort>[-<resort>…].<ext>`, the resort slugs
being the ids in `pipeline/resorts.yaml` where the resort has one. A second
recording of the same day takes a `-2`. Adding, removing or renaming a log changes
the counts in `CorpusTests` and the hash digest in `expected.json`.

Every Slopes file here is the zip with `GPS.csv`, `RawGPS.csv` and `Metadata.xml`.
Files from 2024 and 2025 carry no device model in their source app; 2026 files come
from two iPhones (`iPhone17,1`, `iPhone17,2`).

## slopes/

| File | Covers |
|---|---|
| 2024-01-09-whistler-blackcomb | Short day (3 runs); the track alone finds one run too many. |
| 2024-01-10-whistler-blackcomb | Whistler, full day. |
| 2024-01-14-breckenridge | Breckenridge. |
| 2024-01-16-breckenridge | Breckenridge; the importer finds one run fewer than the list (within tolerance). |
| 2024-01-17-keystone | Keystone; the track alone finds one extra run. |
| 2024-02-03-whitetail | Small eastern hill, short day (4 runs). |
| 2025-01-03-big-sky | Big Sky. |
| 2025-01-04-big-sky | Big Sky; the track alone finds one extra run. |
| 2025-01-06-big-sky | Slopes left out a run the elevation profile shows (truth from the profile). |
| 2025-01-07-big-sky | Very short day (3 runs). |
| 2025-01-10-copper-mountain | Copper; the track alone misses one run. |
| 2025-01-11-copper-mountain | Copper, short day (3 runs). |
| 2025-01-12-arapahoe-basin-keystone-copper-mountain | Three resorts in one day; a listed "run" is a 38 km drive. |
| 2025-01-13-copper-mountain | Copper, full day; the track alone misses one run. |
| 2025-01-14-arapahoe-basin | Arapahoe Basin. |
| 2025-12-25-alpine-valley-wisconsin | Tiny Midwest hill, 78 short laps. |
| 2026-01-08-heavenly | Heavenly, long day (26 runs). |
| 2026-01-10-sierra-at-tahoe-heavenly | Two resorts in one day. |
| 2026-01-10-sierra-at-tahoe | The same day on the second phone, Sierra only. |
| 2026-01-11-palisades-tahoe-granlibakken-homewood-heavenly | Four resorts named in one day. |
| 2026-01-11-palisades-tahoe | Two listed runs are a lift ridden down (truth from the profile). |
| 2026-01-12-kirkwood | One skier's day at Kirkwood. |
| 2026-01-12-kirkwood-2 | A second skier the same day, partly together: must not be taken for the same recording. |
| 2026-01-14-snowbasin | Re-exported as GPX, TCX, FIT and Ski Tracks in `ImportTests` to check one day from many apps. |
| 2026-01-14-whistler-blackcomb | Whistler. |
| 2026-01-15-alta | Alta. |
| 2026-01-15-whistler-blackcomb | Whistler. |
| 2026-01-16-snowbird | Ends on a lift ride; a last run to the valley and a canyon drive follow (truth from the profile). |
| 2026-01-16-whistler-blackcomb | Whistler; the hardest day for the track alone (two runs off). |
| 2026-01-17-brighton | Brighton; the track alone finds one extra run. |
| 2026-01-19-solitude | Slopes left out a lift-served descent (truth from the profile). |
| 2026-01-20-snowbird | Ends on a lift ride, then a last run and the canyon drive (truth from the profile). |
| 2026-01-23-park-city | Park City. |
| 2026-02-01-whitetail | Small eastern hill, newer phone. |
| 2026-03-17-snow-king | Listed lift ride and run each hide several laps, which must be split (truth from the profile). |
| 2026-03-18-jackson-hole-snow-king | Two resorts in one day. |
| 2026-03-20-jackson-hole | Jackson Hole, long day (27 runs). |

## gpx/

| File | Covers |
|---|---|
| 2026-03-12-whistler-blackcomb | Garmin Explore, no run list: seven lift rides and descents read from the profile. |
| 2026-04-25-whistler-blackcomb | Garmin Explore, no run list; the recording starts at the top. |
