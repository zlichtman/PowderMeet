# Test fixtures

`GPSLogs/` is a corpus of real ski-day recordings (Slopes archives and GPX
tracks) that `ActivityCorpusParseTests` parses end to end. Drop a new `.slopes`,
`.gpx`, `.tcx`, or `.fit` file into the folder and it is covered on the next
test run; no registration step is needed because the folder ships with the
test bundle as a folder reference.
