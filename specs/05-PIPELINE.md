# 05 Resort data pipeline

The pipeline is the only producer of resort bundles. It is a Python package
(`pipeline/powdermeet_pipeline`, CLI `pm-pipeline`), run in GitHub Actions on Linux or
on a laptop one resort at a time. Every stage is a pure function of its inputs with a
cached output keyed by the input hashes, so a rerun with the same inputs produces the
same bytes.

The pipeline runs unattended over every resort in the catalog (DECISION 2). No stage
needs a person: it accepts what the sources support, publishes a resort when
automated validation passes, and lists everything else in the report with the
reason. A `decisions/<resort_id>.yaml` file is optional and only corrects what the
sources say about one mountain.

## 1. Stages

```
extract ──▶ reconcile ──▶ build ──▶ validate ──▶ publish
   │            │           │          │            │
 extract/    manifest/    bundle/    report/     Supabase rows + storage
 <id>.json   v<N>.json    <sha>.json.gz  <sha>.md  (bundle_publish RPC)
```

### extract `pm-pipeline extract <resort_id> [--date YYYY-MM-DD]`
- Inputs: `resorts.yaml` entry (bbox, center, timezone, official URLs, provider).
- The catalog bbox only says where to look. Extract reads OpenSkiMap first (its two
  world files are downloaded once into `.cache/openskimap/` and scanned locally),
  picks the ski area in the catalog box whose name shares a distinctive word with the
  resort's, or else the largest one there, and reads OSM for that ski area's extent.
  Letters and digits are separate words ("Hakuba47" meets "Hakuba 47"), and a word
  several candidate areas share ("Hakuba") counts only when no area shares a word of
  its own. A catalog entry may list its areas under `ski_areas` instead, for linked
  areas OpenSkiMap keeps apart (Hakuba Goryu and Hakuba 47).
  A way that OpenSkiMap puts only in some other ski area is left out of the graph
  (flag `way_skipped`, reason `other_ski_area`), so a neighbouring resort does not
  leak in. Lifts that carry no skiers are left out the same way: a lift OpenSkiMap
  cites in no ski area at all (a village cable car or summer lift, like Riddes -
  Isérables at Verbier; reason `no_ski_area`), and a lift named for a tubing hill
  (reason `not_a_ski_lift`). A lift or run that every OpenSkiMap feature citing it
  calls proposed, planned, under construction, disused or abandoned is left out too
  (reason `not_operating`: Zermatt's planned Breitboden - Rosenritz chair). The
  bundle's `bbox` is the extent of the built graph.
  A ski area often reaches past the catalog box, and OSM is read for all of it, so
  when that box is wider than the first OpenSkiMap read (the catalog box and a
  0.05° margin) OpenSkiMap is read again for the whole box and `openskimap.bbox`
  records it. Otherwise a way out there has no ski area to its name and is built
  as ours: Les Contamines' gondolas at Megève, Zell am See's Sonnkogelbahn at
  Saalbach. `extract --openskimap-only` does the same for the latest extract,
  keeping its OSM, official lists and elevation, and `build-all --reuse-extracts`
  does it in one pass for every extract frozen before this rule.
- Fetches once and freezes: OSM features in bbox with `piste:*`, `aerialway=*`,
  `landuse=winter_sports`, `amenity`, `building`, `natural=peak`, `tourism`
  (Overpass; or an `osmium` cut of a regional PBF when `--pbf` is given, preferred for
  reproducibility; it reads every node of a network way with all its tags, as
  Overpass does, but no relations, so a place mapped only as a multipolygon relation
  is missing), OpenSkiMap runs and lifts, official trail and lift lists (one
  adapter per resort group: Epic, Alterra, generic HTML table). An official list that
  names one trail twice with different difficulties keeps both rows; reconcile then
  treats it as having no single official value (flag `difficulty_conflict`).
- Also freezes the elevation of every node a way references, sampled from the DEM
  (see build), so reconcile and build never touch the network and a rebuild months
  later gives the same bytes even if the DEM provider has changed its tiles.
- Output `extract/<resort_id>/<extract_id>.json` with `extract_id =
  osm-<ISO time>-<resort_id>-<sha6>`. Both reconcile and build read this one file.
  The file name drops the `:` of the ISO time (artifact stores refuse it); the id
  inside the file keeps it.
- Official adapters built so far: Epic (`FR.TerrainStatusFeed`) and MtnPowder (the
  shared Alterra feed, cached for an hour; which feed entries make up a resort is
  `official.names` in `resorts.yaml`). The names an adapter returns are the names the
  status provider of the same name reports, so they become that provider's
  `status_aliases`. There is no Liftie adapter: Liftie refuses automated requests
  from the networks tried, so no resort is assigned to it. Epic sites name the page
  `terrain-and-lift-status.aspx` or `lift-and-terrain-status.aspx`; after a 404 on
  the catalog URL the other spelling is tried. Before opening day an Epic page often
  lists lifts and no winter trails; the lifts are kept (a page with neither is
  off-season and counts as unavailable). When the official list cannot be fetched
  the extract carries the newest list an earlier extract of the resort holds
  (`carried_from`, with the original `fetched_at`, and the new failure in
  `fetch_error`), or else is frozen without one and says so. `official.checked_at`
  is when the lists were last asked for, fetched or not; the newest extract of a
  resort (the one `--reuse-extracts` and `--official-only` start from) is the one
  with the latest OSM time, then the later of `checked_at` and the time OpenSkiMap
  was read; for Epic a saved copy
  of the page can be passed with `--official-html`. `extract --official-only`
  fetches only the official lists again and freezes them with the latest extract's
  OSM, OpenSkiMap and elevation data, which is how lift lists are picked up as
  resorts open without another Overpass request. Without an official list a resort
  has no status aliases and publishes as `scheduled_only`.
- Overpass is retried on HTTP errors other than 400, dropped connections,
  timeouts and answers whose `remark` reports a runtime error (a query that timed
  out or ran out of memory answers with only some elements), five more times with pauses of 30 s, 1, 2, 4 and 5 minutes.
  `PM_OVERPASS_URL` names other instances (comma-separated, tried in turn).

### reconcile `pm-pipeline reconcile <resort_id> --extract <extract_id>`
- Merges OSM,
  OpenSkiMap and official identities with evidence into a manifest of trail and lift
  identities, each with `group_id`, display name, difficulty, source way ids,
  confidence, and `status_aliases` per provider.
- Auto-accept rule: an identity with the same normalized name in two or more sources
  and a single OSM way cluster is accepted. Everything else is still built, and is
  listed in the report with what the build did about it; acceptance is information,
  never a gate. An official name that differs from a mapped name only in spacing or
  punctuation is matched to it when the match is one to one; nothing looser is
  merged. `decisions/<resort_id>.yaml` is optional. Its keys are `merges`, `accept`, `reject`, `exclude_ways`,
  `rename`, `way_names`, `difficulty`, `status_aliases`, `operating_hours`, `rendezvous`,
  `snap_tolerance_m`, `link_tolerance_m`, `links`, `areas`, `add_runs` and `review_minutes`, plus
  `resort_id`; `rendezvous` takes `reject`, `rename` and `confidence`. Any other key
  fails the run, so a misspelt one is never silently ignored, and so does an entry
  that names something which does not exist: an `accept`, `reject`, `rename` or
  `difficulty` identity, an `operating_hours` lift, a `rendezvous` id that is not
  proposed, an `exclude_ways` way not in the extract, a `status_aliases` provider
  the resort does not use, or an `areas` node that is not a lift end, station or
  junction of the built network. `operating_hours` entries take `days` (1 to 7)
  and quoted `open` and `close` times (`"08:30"`; YAML reads an unquoted 15:30 as
  a number), and a `rendezvous` confidence is between 0 and 1. `way_names` renames single OSM ways, and every
  OpenSkiMap feature citing only those ways, before reconcile and build, so two lifts
  or runs in different areas that the trail maps name alike become two identities; it
  is written into the manifest when present, and a way it names that is not in the
  extract fails the run.
- Runs no one has mapped (`add_runs`): a run on the resort's list and its trail map
  with no mapped line is an entry with `name`, `difficulty` (green, blue, black or
  double_black), `from` and `to` (node ids `n<id>`: a lift end or station, or a node
  of a run or connection) and `source` (the trail map it came from). Before
  reconcile the line is traced on the same DEM the extract samples: the cheapest
  path over a grid of DEM samples (10 m, coarser past about 2.7 km) between the two
  nodes, where a metre climbed costs 30 m of path and a step across the slope up to
  2.5 times one down it, simplified to within 4 m. It is frozen into the manifest
  under `add_runs` with its elevations, so reconcile and build never touch the DEM.
  The run fails when a node is not in the graph, the ends are more than 4 km apart,
  the end is not at least 5 m below the start, the traced line is longer than 6 km,
  or it still climbs more than 10 m anywhere. Reconcile and build then read the
  extract with each drawn run added as a downhill way (way id 9×10^15 plus 10 hex
  digits of a hash of its name and ends, under 2^53, so edge ids keep the `w<id>:<k>` shape;
  inner points are vertices the pipeline adds, `v…` if a join splits the run). It
  is matched to the official list by name like any way, its difficulty is the
  entry's unless `difficulty` sets one, a trail made only of drawn runs counts as
  accepted by decision, and it is joined to the network by the gap rules below. Its
  run edges and its group carry `approximate: true` in the bundle, and the report
  lists it under the flag `run_drawn`.
- Trail difficulty: each section of a trail is paced and gated by its own
  difficulty. A `difficulty` decision wins for every edge of the trail. Otherwise,
  when the official list gives the trail one value, the manifest stores it as
  `official_difficulty` and each edge takes the harder of its own way's
  `piste:difficulty` and that value: a section mapped harder keeps the map's value,
  one mapped easier or not at all takes the feed's. A feed never makes a section
  easier than the map, so a stale feed or a wrong icon cannot send a beginner down a
  black. The trail (manifest and bundle group) shows the hardest of the official
  value and the mapped ones (OSM or OpenSkiMap), since that is what a skier must ski
  to take all of it; `difficulty_source` is `map_harder_than_official` when the map
  is the harder, `official` otherwise. Either disagreement is listed
  (`difficulty_differs_from_official`, not blocking). With no single official value,
  each edge keeps its own way's mapped difficulty (an untagged way takes the
  trail's) and the group shows the hardest (`difficulty_source: osm`).
- Status aliases: every official name of an identity becomes an alias of its group,
  verbatim, since the status worker looks names up exactly. One name maps to one
  group, so when a lift and a trail share a name the lift keeps it (live status needs
  every lift mapped). An official lift name that matches no mapped lift exactly is
  still made an alias of one when the two agree on a key: the name without the
  resort's own name, articles, `#n` lift numbers and Epic's trailing ` - Mountain -
  Zone` qualifiers, with a final roman numeral read as a digit ("Powderhorn II" /
  "Powderhorn 2", "Chateau Carpet - Blackcomb" / "Chateau Carpet", "Gondola" /
  "Heavenly Gondola", "Apollo" / "Apollo #27"), and failing that also without
  lift-type words such as Express, Chair, Quad, Lift, Carpet, T-Bar ("Stella Express" /
  "Stella"), and failing that also without a trailing lift number ("Broadway Express
  1" / "Broadway Express"). Number words are digits ("High 5" / "High Five"), "Mtn",
  "Mt" and "Hi" are spelled out, and the resort's initials count as its name ("Lower
  BC Mtn Express" / "Lower Beaver Creek Mountain Express Lift"). A name that is only
  the resort's name and lift-type words is keyed on the whole name ("Wildcat
  Express" / "Wildcat Express Quad" at Wildcat). The key must belong to exactly one lift group and one official name,
  and the group must have no alias yet and no other official name claiming it. This
  only adds aliases: the identity keeps its mapped name and group id, nothing is
  merged, and each match is listed in the report (`official_lift_name_matched`). A
  wrong one is corrected under `status_aliases` in a decisions file. One official
  name for two mapped lifts ("Treeline Cirque" / Lower and Upper) cannot be an alias
  and stays unmapped.
- Ids: group ids and rendezvous slugs are the name folded to ASCII (NFKD, accents
  dropped, other characters to `-`). A name with no Latin letters or digits
  (`山頂レストラン`) is `u-` and the first 8 hex digits of the SHA-256 of its
  normalized name (NFC), so such names never collapse into one id.
- Rendezvous candidates: lodges and restaurants (`amenity`, `building`; at most two
  per anchor; an unstaffed `tourism=wilderness_hut` is a landmark with no food, and
  anything tagged `access=private` or `no` is left out; so is any place that is closed: a name
  ending in "(closed)", "(disused)" or "- closed", `disused=yes`, `abandoned=yes`, a `disused:*` or
  `abandoned:*` tag, or `opening_hours=closed`/`off`, which is dropped, not kept as a landmark), lift bases, mid stations (emitted as `lift_top` stops, ids ending
  `-mid`) and tops of chairs, gondolas, cable cars and T-bars (carpets and rope tows
  are left out) (in travel order, so a lift drawn top first still has its base at the
  bottom; a lift with no name gets `unnamed-<way id>-base` and `-top`, named for its
  type and the nearest named run), named junctions, peaks, and the bottom of each named run (the lowest end of
  its ways, kind `junction`, named "Bottom of <run>", id `<run-slug>-bottom`): only
  where the run drops at least 30 m and no other proposal lies within 60 m (a run
  that ends at a lift is met at the lift); several runs ending on one node give one
  entry, named for the longest. Proposed `rendezvous_id` slugs and kinds (a repeated id is numbered `-2`, `-3` in
  order of the place's own OSM element id (`node/123`, `way/456`; on a tie, nodes
  before ways before relations, then the anchor node), so a place mapped later
  takes the next number and existing ids stay put; a lift station or run bottom,
  which has no element of its own, sits on its anchor node and counts as that node
  id; numbering skips any number a place's own slug already holds, so "Summit 2"
  keeps `summit-2`). Candidates are anchored to the network
  build sees, without the ways of rejected identities; the
  reviewer confirms or edits in the same decisions file.
- Output `manifest/<resort_id>/v<N>.json` (`manifest_version` increments when content
  changes). Versions are counted from the manifests in the work directory and those
  committed as `fixtures/<resort_id>/manifest-v<N>.json`. A fresh CI workspace has
  neither for most resorts, so an unattended run starts every manifest at version 1.
  Reconcile stays offline: `publish` keeps the published order on the server
  instead (below).

### build `pm-pipeline build <resort_id> --manifest v<N> --extract <extract_id>`
- Graph from source topology: shared OSM vertices and explicit
  `piste:type=connection` ways create connectivity, and beyond them only the joins
  listed under Gaps below, each recorded as a flag; coordinate coincidence alone
  never does (invariant I-16). Ski-area polygons are footprints, never centerlines.
- Lifts: one directed edge bottom → top; `oneway=no` adds the reverse direction with
  its own queue entry (one edge with `one_way: false` and `queue_entry: both`); ride
  time from `aerialway:duration` or length ÷ typical speed by
  type; `operating_hours` from the manifest (official page), else resort defaults
  (`days` are ISO weekdays, 1 = Monday, in the resort's time zone).
  Gondolas, cable cars, mixed lifts and funiculars are two-way unless tagged
  `oneway=yes` (the OSM convention); chairs and surface lifts are two-way only when
  tagged `oneway=no`.
  A one-way lift keeps its mapped direction unless that direction descends more than
  20 m: chairs and surface lifts carry skiers up, so such a lift is mapped backwards
  and is built reversed (flag `lift_reversed`; every chair at Yongpyong, Nekoma's
  Batow and First Chair). A two-way lift is oriented by elevation
  and its pieces are numbered bottom to top, so consecutive pieces of one ride are
  always `w<id>:<k>`, `w<id>:<k+1>` in travel direction.
  A lift is cut only at its `aerialway=station` nodes, so a run that shares some
  other node with it is not joined to it.
- Node kinds: a `base` is a lift bottom in the lowest 15 % of the lift network's
  elevation range. A lift top is where a lift group ends (not a mid-station the same
  lift carries on from, which is a `lift_bottom`, and not the lower terminal of a
  two-way lift).
- Runs: split ways at junction vertices into edges `w<id>:<k>`; difficulty from
  `piste:difficulty` reconciled with the official map; `groomed_default` from
  `piste:grooming`, and `moguls: true` on the edges of a way tagged
  `piste:grooming=mogul` (still `groomed_default: false`; the key is left out
  elsewhere); elevation per vertex from the DEM; `vertical_m`, `grade_max_deg`,
  `aspect_deg` from geometry (`grade_max_deg` is the steepest slope over any stretch of at
  least 30 m, or the mean slope of an edge shorter than that). `length_m` is horizontal (haversine, radius 6 371 000 m,
  the same as `MountainCore.Geo`).
- Run direction and elevation noise: a run way that climbs more than 5 m end to end
  is mapped uphill and is built reversed (flag `run_reversed`). Rises of up to 5 m
  between vertices are DEM noise and are flattened, so every run edge has
  `vertical_m <= 0` as the client requires. A run piece that still climbs more than
  5 m is built as `kind: connection` in its group (flag `run_uphill`).
- Elevation: DEM tiles from a configured provider (Mapbox Terrain-RGB with the public
  token, AWS Terrarium, or Copernicus GLO-30), fetched by tile and cached under
  `.cache/dem/`; sampling is bilinear. No per-coordinate API calls. Only AWS
  Terrarium (keyless, zoom 14) is implemented. Sampling runs in `extract`.
- Unclaimed named runs stay open; unnamed run ways inside the area are kept and
  flagged (`unnamed_run`), not built closed (DECISION 1 makes degraded routing
  acceptable). Each unnamed way is its own group `trail:unnamed-<way id>` with an
  empty name (the pipeline never invents one), so ways of different difficulty are
  never one group. Its edges and its group take the way's `piste:difficulty`; only
  a way with no difficulty tag is `difficulty: unknown` (the solver gates `unknown`
  by its measured pitch, or as the resort's hardest difficulty when it has none:
  `06-SOLVER.md`).
- Gaps: OSM often leaves a lift station and the nearest run without a shared node
  (Whistler: 10 to 62 m; base-area lifts elsewhere sit 80 to 200 m from the nearest
  mapped run). Because nobody reviews a resort, the build closes
  the named kinds of gap below itself and lists every one in the report:
  a run end with no continuation is joined to the nearest node that continues,
  within `snap_tolerance_m` (default 15, flag `snap`); a lift station that shares no
  node with any run, a lift top whose runs reach no other lift, and a lift cut off
  from the rest of the network (nobody can ski to it, or its runs never lead back)
  are joined to the nearest node that connects, within `link_tolerance_m` (default
  200, max 250, flag `auto_link`) and never across more than 30 m of height (up or down). A wider
  gap is left open and flagged `link_proposed` with the two node ids; a decisions
  file may join it under `links` (flag `link`).
  A run drawn from near a lift's top, or down to near its bottom, without a
  shared node is tied to that station under the same limits (`link_tolerance_m`,
  30 m of height): the nearest station where riders leave a lift is joined to a
  run start nothing reaches, and a run end nothing leaves is joined to the nearest
  station where riders board (flag `auto_link`).
  A run end drawn a few metres short of another run's line, or a run start drawn
  just below a ridge or traverse, is a T-junction the map leaves open, and is
  joined to the nearest point on that line, not only to its nodes (flag
  `line_join`): within `line_join_m` (catalog default 40, max 50), a run end
  nothing leaves into a run or connection that leads on to a lift, and a run
  start nothing reaches from one that skiers reach from a lift. The join climbs
  no more than 5 m, drops no more than 30 m, is one way and never crosses a
  lift's cable. The line is split at the junction: at its vertex when one lies
  within 3 m, else at a new vertex `v<12 hex>` (`02-DOMAIN.md`). These joins
  run before the run-to-station joins, and a station that rule would join is
  used instead when it is nearer than the line; they run once more after the
  cut-off lifts are tied in, since those joins reach more lines. Rounds repeat
  until none is joined, so a chain of two cut-off runs (Pete's Peril below Peril
  Ridge at Palisades Tahoe) is tied in at both ends. Two runs that merely pass
  close together are never joined: only a run's free end is.
  The one other exception is a run whose whole piece of the map touches no lift (drawn
  as a line that starts just below one run and ends just above another, as at
  Jiminy Peak): it is tied to the network at both ends, each within
  `orphan_join_m` (catalog default 50, max 50) and 30 m of height, or not at all,
  so it never becomes a dead end (flag `orphan_link`): its start from a node skiers
  reach and its end into a node that leads on to a lift, never a node on a lift's
  cable. These joins come after every other join, so they change none of them, and
  rounds repeat until none is joined, so a run tied in brings its neighbours within
  reach.
  Cut-off lifts are joined one at a time, the shortest gap in the whole network
  first, and the network is measured again after each join, so a pod tied in brings
  its neighbours within reach and a gap past the tolerance is proposed only when no
  shorter one is left. A lift nobody can get to is joined from the network to the
  nearest node of anything that leads to its boarding station (the runs that feed
  it), not only to the station itself; a lift whose riders cannot get back is joined
  from the nearest node they can reach. Riders board and leave a two-way lift at
  every station, so each of its stations counts both ways here (a gondola linking
  two base areas, like Palisades Tahoe's Base to Base, joins them). Each join is a short `connection` edge on the way
  it extends, named after that way when it is a run or a named connection (a
  descent matched onto it reads as the trail; a join on a lift stays unnamed),
  and its flag names that edge so the report preview colours it; two
  ways are never joined merely because they pass close together. One exception to "never a merge": a join shorter than 1 m is two OSM
  nodes at the same place, and since a zero-length edge is not a valid edge the
  dead end becomes the node it joins; several such joins at one place merge all
  their nodes into one, and a decisions file's `areas` node keeps its id in such a
  merge. The tolerances default in `resorts.yaml`; 0
  turns one off. Reconcile writes all four (`snap_tolerance_m`, `link_tolerance_m`,
  `orphan_join_m`, `line_join_m`) into the manifest, and build reads them from there.
  These joins (`snap`, `auto_link`, `line_join`, `orphan_link`, and `link` from a
  decisions file) are the only ones invariant I-16 allows besides shared vertices
  and explicit connections.
- Output: canonical JSON (sorted keys, fixed float formatting to 7 decimals for
  coordinates and 1 for meters) → gzip (mtime 0, no name) → `bundle_id = sha256`.
  Determinism test: build twice → identical bytes. `built_at` is the later of the
  manifest's creation time and the extract time, not the wall clock, so the same
  inputs always give the same bytes. The JSON is byte-identical on every machine;
  the gzip bytes, and so the `bundle_id`, are identical only between machines whose
  zlib produces the same deflate stream.

### validate `pm-pipeline validate <bundle_id>`
Computes the integrity block and compares with thresholds:

| Metric | Publish threshold |
|---|---|
| `lift_tops_reaching_base` (share of lifts that are part of the connected network) | ≥ 0.90 |
| `rendezvous_reachable_from_all_lift_tops` | = 1.0; a proposed rendezvous outside the connected network is dropped with a flag, so this fails only when none is left. A lift bottom that skiers can ski to from the network is kept even when the lift itself is cut off (no run mapped from its top) |
| `orphan_edge_share` (edges in components without a lift) | ≤ 0.10 |
| `unnamed_run_share` | ≤ 0.10, a warning only |
| `lift_exit_dead_end` count | 0 after snaps, else `scheduled_only` and a flag |
| Elevation monotonicity: run pieces that climb more than 5 m (`run_uphill` flags) | 0, a warning only (the piece is built as a connection) |
| Status alias coverage (live mode): lift groups the provider feed names | ≥ 0.80, the status worker's own rule; the app checks the same |

The connected network is the largest part of the graph in which every node can reach
every other by runs, connections and lifts. A lift counts as connected when both its
ends are in it, so a lift nobody can ski to, a lift top with no way down, and a pod
whose runs never lead back all count against the first row. This replaces "a
run-only path to a base node": on a mountain with several pods a lift top often
cannot ski to the lowest base without riding another lift, and that is not a defect.

A resort can also hold separate ski areas that nobody skis between, each with its
own base: Ahorn and Penken at Mayrhofen, Dollar and Bald Mountain at Sun Valley,
Kitzbühel's Horn, Boston Mills and Brandywine. A strongly connected part of the
graph counts as a separate area when it holds at least one lift and one run, lies
more than 250 m from the main network at every node (anything nearer is a gap to
join), and has a lift bottom in the base band (the lowest 15 % of the whole lift
network's elevation range), or holds a node a decisions file names under `areas`
(for upside-down mountains such as Snowshoe's Silver Creek and Hotham's Big D).
A pod high on the mountain is never one. Its lifts count as connected, its
rendezvous are kept (two skiers both in it can meet there; the solver reports
`noRendezvousReachable` across areas), and it gets a `separate_area` flag. The
build joins pieces of a separate area the map leaves apart to that area under
the same limits as cut-off lifts are joined to the main network.

`status_mode = live` needs the first three rows, no `lift_exit_dead_end` and the status
alias coverage; unnamed and climbing run pieces never hold it back.
Below threshold: the resort may still publish with `status_mode = scheduled_only` only
if the first three rows pass; otherwise it is not publishable and the report says
which decisions would fix it. Output: `report/<resort_id>/<bundle_id>.md` plus
`.geojson` preview (edges colored by flag) uploaded to `resort-reports`. `validate`
also runs the constraints the client enforces (`BundleIntegrity.validate`), so a
bundle the app would refuse is never publishable.

### publish `pm-pipeline publish <resort_id> --bundle <bundle_id> [--rollback]`
- Uploads `resort-bundles/<resort_id>/<bundle_id>.json.gz` (skip if present), inserts
  `resort_bundles`, calls `bundle_publish(...)` with the rendezvous id list and report,
  then sets `resorts.published = true`, `status_mode` and `review_minutes` with a
  separate update. One command, but not one transaction: the uploads, the resort row,
  the bundle row, `bundle_publish` and that update are separate calls, so a failure
  between them leaves an uploaded or recorded bundle that is not active. Needs
  `SUPABASE_SERVICE_ROLE_KEY` in the environment (from `_local/secrets/supabase/` on the
  Mac; the workflow's repository secret is not set).
  It refuses, before uploading anything, a bundle that is not publishable, or whose
  integrity metrics or `status_mode` do not measure as stored under the current rules
  (the check `validate` makes, with the manifest's `areas`; an older bundle is rebuilt
  first). The final update is tried three times; when it still fails the bundle is
  active with the old row, and publish says so and is run again.
- The `resort_bundles` row's `manifest_version` is read from the server, not only
  from the bundle: before uploading anything, publish reads the highest number the
  server holds for the resort and records the bundle's own number only when it is
  higher, else that highest plus one; a bundle already recorded keeps its number, so
  a run after a partial failure records the same one. The row stores nothing that
  tells a rebuild of the same manifest from a different manifest, so every new
  bundle goes above the last and the column is the order bundles were published in.
  The bundle's `source.manifest_version` is the number from the work directory and
  is not changed (it is part of the bytes the `bundle_id` hashes), and publish loads
  the local manifest by that number. Rows written before this rule are not
  renumbered.
- `p_rendezvous_ids` is every rendezvous id in the bundle, in bundle order; the
  server keeps them in `resort_active_bundle.rendezvous_ids` and `meet_propose`
  checks against that list. A bundle with no rendezvous is never publishable.
- Before the bundle row, publish upserts the resort's `resorts` row from the catalog:
  `id`, `name`, `timezone`, `bbox` and `center` (the bundle's), `camera`,
  `pass_products`, `aliases` (other names the picker searches by; 0020) and
  `status_provider` (`epic`, `mtnpowder`, `liftie` or null). The
  pipeline owns these rows; the 0008 seed only has to exist for foreign keys.
- Also uploads `resort-bundles/<resort_id>/<bundle_id>.status.json`, a few tens of
  kilobytes, for the status worker: `schema_version`, `resort_id`, `bundle_id`,
  `status_mode`, `status_aliases` and `groups` reduced to `{id, kind}`. The keys are
  the bundle's own, so the worker's bundle parser reads it unchanged.
- Records `review_minutes` from the decisions file when there is one. A resort with
  no decisions file publishes on validation alone.

### build-all `pm-pipeline build-all [--only id,id] [--shard I/N] [--reuse-extracts]`
- Runs extract, reconcile, build and validate for every resort (or the ones named, or
  one shard of the catalog), one at a time. A resort that fails is recorded with its
  reason and the batch carries on. With `--reuse-extracts` a resort with a frozen
  extract is built from the newest one, with no Overpass request.
- Output `report/summary.json` and `report/summary.md`: per resort, the result
  (`live`, `scheduled_only` or `fail`), the validation numbers, counts, and what
  blocks it; then the pass rate and the reasons resorts fail, most common first.
  A run with `--only` writes `summary-only.*` instead, so it never replaces the
  whole-catalog summary; a shard writes `summary-<I>-of-<N>.*`.
  `pm-pipeline summary <files>` merges the summaries of several shards.

## 2. Status and conditions providers

Providers run as TypeScript edge workers (`backend/supabase/functions/_shared/providers/`),
each with fail-closed tests. Each provider: `fetch(resort) -> ProviderStatus | throw`, maps provider names to
`group_id` through the bundle's `status_aliases`, and MUST NOT write a row if the
parse fails or if fewer than 80 % of live lift groups are mapped (the previous row
simply ages into `stale`). `scheduled_only` resorts get hourly `source: scheduled`
rows from operating hours. Adding a provider is one adapter file plus fixtures.

MtnPowder feed quirks. The shared feed misspells names ("Mt Bueller", "Grandvilara",
"Takamagahara Mommoth Ski Area") and calls Blue Mountain Ontario just "Blue". It splits
one resort into many areas: 17 for Shiga Kogen, 4 for Niseko, plus Dolomiti Superski,
Bear Mountain with Snow Summit, and Alpental. It mixes in summer, forecast-only and
duplicate entries. Only winter entries that carry terrain count. Each name in `official.names` must
match exactly one feed entry: none, or two with the same name, fails the resort's
official list, as does an entry with no winter trails or no lifts. Names are matched
exactly as the feed spells them; never "fix" a spelling in `resorts.yaml`.

Liftie attribution. A resort given `status_provider: liftie` must show "Lift status
provided by Liftie" wherever its live status appears in the app.

Conditions: Open-Meteo, one call per resort per hour from the worker, cached in
`resort_conditions`. Clients never call Open-Meteo.

## 3. Repository and CI

```
pipeline/
  pyproject.toml           deps: pyyaml, pillow, pytest; osmium only for --pbf
  powdermeet_pipeline/{extract,reconcile/,build,validate,publish,dem,sources/,report,
                       topology,drawn,canonical,batch,catalog,geo,cli}.py
  resorts.yaml             catalog with provider and official URLs
  decisions/<resort_id>.yaml
  fixtures/whistler-blackcomb/extract-*.json, manifest-v<N>.json, expected-bundle.sha,
                           expected-content.sha, report.md
  tests/
.github/workflows/pipeline.yml       pytest (and Whistler through the CLI) on push to main touching pipeline/
.github/workflows/publish-resort.yml workflow_dispatch(resort_id, publish: bool): extract → reconcile → build → validate; publish only when input publish=true and validation passed; uploads report as artifact
.github/workflows/build-all.yml      workflow_dispatch only: one job fetches OpenSkiMap, eight shard jobs run build-all, one job merges the summaries
```

Runtime budget: one resort build under 10 minutes and 2 GB on a Linux runner. DEM
tile cache is a GitHub Actions cache keyed by resort.

## 4. Launch resorts (DECISION 2)

Every resort in the catalog (161, in `resorts.yaml` with an IANA timezone each,
including Alpine Valley Resort in Wisconsin and Snow King, where the GPS test logs
were recorded). The batch publishes each resort that
passes validation and lists the rest with the reason. A resort with no status
provider, or whose official list cannot be fetched or matched to every lift, is
`scheduled_only`; that is the expected case for most. Whistler Blackcomb is the first
proof.

## 5. Tests

- `test_determinism`: build twice from the Whistler fixture → same `bundle_id`.
- `test_golden_whistler`: integrity metrics within tolerance of the recorded report.
  Whistler is also the reference case for the join tolerances in build: its OSM data
  has unnamed ways and lift exits with no mapped downhill link (station-to-run gaps of
  10 to 62 m), and every one must be closed by a join listed in the report, with
  `lift_exit_dead_end` at 0.
- `test_reconcile_*`: the reference reconcile cases (identities, aliases, merges).
- `test_validate_thresholds`: synthetic graphs hitting each threshold.
- `test_bundle_schema`: the built bundle validates against `bundle.schema.json`, and
  the Swift `BundleIntegrity` fixture test consumes the same file (the schema JSON is
  copied into `packages/MountainCore/Tests/Fixtures`).
