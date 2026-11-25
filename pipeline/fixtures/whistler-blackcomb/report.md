# Whistler Blackcomb: bundle report

- Bundle: `95236f0065c782dd745561fa4e153845c6a9f568cbd7cdf1e1087c43ee0ef16d` (333,103 bytes stored)
- Extract: `osm-2026-11-19T23:31Z-whistler-blackcomb-279e7b`; manifest v1; pipeline 1.5.0; built 2026-11-22T19:18:29Z
- Result: **publishable**, status mode `scheduled_only`
- Decisions file: yes, 0 review minutes recorded

## Integrity

| Metric | Value | Threshold | Needed for | Result |
|---|---|---|---|---|
| `lift_tops_reaching_base` | 1.0 | >= 0.9 | publishing | pass |
| `rendezvous_reachable_from_all_lift_tops` | 1.0 | == 1.0 | publishing | pass |
| `orphan_edge_share` | 0.0029 | <= 0.1 | publishing | pass |
| `unnamed_run_share` | 0.088 | <= 0.1 | live status | pass |
| `lift_exit_dead_end` | 0 | == 0 | live status | pass |
| `run_uphill` | 6 | == 0 | live status | FAIL |
| `status_alias_coverage` | 0.3143 | >= 0.8 | live status | FAIL |

Client constraints (`BundleIntegrity.validate`): all pass.

## Contents

- 1338 nodes; 2084 edges (1977 run, 36 lift, 71 connection)
- 599 trail groups, 35 lift groups
- 386 rendezvous: 293 junction, 24 landmark, 26 lift_base, 27 lift_top, 16 lodge

## Reconciliation

- Sources: official 321, openskimap 530, osm 529. 28 official names matched ignoring punctuation. 4 official lift names matched to a mapped lift of another name (listed under Other notes)
- 524 identities: 500 confirmed by two sources and one piece, 0 accepted by decision, 24 not fully supported, 0 rejected
- 110 unnamed run ways and 0 unnamed lift ways kept

### Identities the sources do not fully support (24)

These are built as described; none of them holds up publishing.

| Code | Identity | Detail | What the build does |
|---|---|---|---|
| `difficulty_conflict` | `trail:glacier-road` | sources disagree: official black/blue; openskimap black/blue; osm black/blue | the harder value, black, is used; set difficulty for trail:glacier-road to override |
| `difficulty_conflict` | `trail:ptarmigan` | sources disagree: official black/blue; openskimap blue; osm blue | the harder value, black, is used; set difficulty for trail:ptarmigan to override |
| `multi_cluster` | `trail:7th-heaven-avenue-glades` | 3 separate pieces: ways 1167569202; ways 1167569203; ways 1167569204 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:arthurs-choice-exit` | 2 separate pieces: ways 1167536719; ways 1167536720 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:blackcomb-home-run` | 3 separate pieces: ways 48427915; ways 1169399416; ways 1304534124 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:camel-humps` | 3 separate pieces: ways 48109147; ways 257662675; ways 257662678 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:closed-captions` | 3 separate pieces: ways 255941583; ways 1170955036; ways 1170955037 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:crabapple-connector` | 2 separate pieces: ways 549056437; ways 1175320138 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:cutover-to-lower-chainsaw-ridge` | 2 separate pieces: ways 1166014980; ways 1171034218 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:everglades` | 2 separate pieces: ways 39993400,89634499,89634500,89634501,1167569201; ways 1173097991 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:excelerator-express-chairlift-access` | 2 separate pieces: ways 872802940; ways 1167351958 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:expressway` | 2 separate pieces: ways 75366960,1134582534,1134582538; ways 475428199 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:expressway-access` | 2 separate pieces: ways 1168288211; ways 1315733311 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:glacier-bowl` | 5 separate pieces: ways 48109143; ways 1172204650,1283258164; ways 1173968003; ways 1283258162; ways 1283258163 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:insanity` | 2 separate pieces: ways 1174825717; ways 1174825720 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:jeffs-connector` | 2 separate pieces: ways 1165412130; ways 1173683959 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:lakeside-bowl` | 3 separate pieces: ways 1166123092; ways 1166123093; ways 1166123094 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:little-whistler` | 2 separate pieces: ways 1172204648; ways 1172204649 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:northern-lights-connector` | 2 separate pieces: ways 1314261352; ways 1314261353 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:panorama-connector` | 3 separate pieces: ways 1171034220; ways 1171034221; ways 1285937715 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:peak-to-creek-lower-access` | 2 separate pieces: ways 48270132; ways 1174679542 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:staccato-glades` | 2 separate pieces: ways 88149204; ways 1173683952 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:tree-fort-access` | 2 separate pieces: ways 1173053291; ways 1173053293 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |
| `multi_cluster` | `trail:zig-zag-connector` | 2 separate pieces: ways 1167464204; ways 1167536714 | kept as one trail mapped in pieces; put a stray piece's ways in exclude_ways if it is not part of it |

### Other notes (69)

| Code | Identity | Detail | What the build does |
|---|---|---|---|
| `difficulty_differs_from_official` | `trail:flute-north-bowl` | official says black; the map says double_black | sections mapped harder keep the map's value and the rest take black, so the trail shows double_black; set difficulty for trail:flute-north-bowl to override |
| `difficulty_differs_from_official` | `trail:grey-zone` | official says black; the map says double_black | sections mapped harder keep the map's value and the rest take black, so the trail shows double_black; set difficulty for trail:grey-zone to override |
| `difficulty_differs_from_official` | `trail:main-flute-bowl` | official says black; the map says double_black | sections mapped harder keep the map's value and the rest take black, so the trail shows double_black; set difficulty for trail:main-flute-bowl to override |
| `difficulty_differs_from_official` | `trail:rhapsody-bowl` | official says blue; the map says black | sections mapped harder keep the map's value and the rest take blue, so the trail shows black; set difficulty for trail:rhapsody-bowl to override |
| `difficulty_differs_from_official` | `trail:staccato-glades` | official says blue; the map says black, blue | sections mapped harder keep the map's value and the rest take blue, so the trail shows black; set difficulty for trail:staccato-glades to override |
| `difficulty_differs_from_official` | `trail:stoker-bumps` | official says black; the map says black, blue | keep black, or set difficulty for trail:stoker-bumps |
| `difficulty_differs_from_official` | `trail:surprise` | official says black; the map says double_black | sections mapped harder keep the map's value and the rest take black, so the trail shows double_black; set difficulty for trail:surprise to override |
| `mixed_difficulty` | `trail:crabapple-connector` | its ways are tagged green, blue | each edge keeps its own way's difficulty; the group shows blue |
| `mixed_difficulty` | `trail:excelerator-express-chairlift-access` | its ways are tagged green, blue | each edge keeps its own way's difficulty; the group shows blue |
| `mixed_difficulty` | `trail:peak-to-creek-lower-access` | its ways are tagged blue, black | each edge keeps its own way's difficulty; the group shows black |
| `mixed_difficulty` | `trail:roundhouse-roll` | its ways are tagged blue, black | each edge keeps its own way's difficulty; the group shows black |
| `no_ways` | lift "Admin Carpet - Blackcomb" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Adult Mini Carpet - Whistler - Olympic Zone" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Base 2 - Blackcomb - Ski and Ride School Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "CLC Mini Carpet - Whistler - CLC - Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Chateau Carpet - Blackcomb" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Creekside Carpet - Whistler - Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Fantastic Carpet - Whistler - Olympic Zone" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Scampland Carpet - Whistler - CLC -Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Snowboard Carpet - Whistler - Olympic Zone" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | lift "Super Carpet - Whistler - Olympic Zone" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Adult Learning | Super Carpet" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Animal Adventure Trail" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Bean Bowl" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Blackcomb Base Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Blackcomb Race Centre" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Bobcat Park" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Brownlie Basin" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "CLC Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Chipmunk Park" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Choker" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Creekside Base Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Cruiser Bypass" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Cruiser Grub" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Cruiser Rolls" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Cruiser Snoozer" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Dave Murray Downhill Fallaway" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Dave Murray Downhill Weasel" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Ego Park" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Entrance to Blackcomb Glacier" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Entrance to Grey Zone" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Flute Road" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Grey Line" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Harmony Horseshoes" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Highest Level" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Jersey Cream Bowl" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Krummholz" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Magic Castle" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Mini Pipe" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Piccolo Face" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Pony Trail Bypass" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Pony Trail Cat Track" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Sapphire Bowl" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Scampland Whistler Kids Only" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Secret Bassin" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Secret Chute" | listed by openskimap but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Showcase Bowl" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Slingshot Connector" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Snowboard Carpet" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Spankys Ladder" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Stoker Rolls" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Super Carpet" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "T-Bar Bowl" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Tree Fort" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `no_ways` | trail "Zig Zag Foon Alley" | listed by official but no mapped way has this name | merge with the mapped identity it names, or ignore if it is not skiable terrain |
| `official_lift_name_matched` | `lift:base2-carpet` | the status feed calls 'Base2 Carpet' 'Base 2 - Blackcomb - Ski and Ride School Only' (matched on 'base2') | kept as its status alias; set status_aliases for the lift if the match is wrong |
| `official_lift_name_matched` | `lift:chateau-carpet` | the status feed calls 'Chateau Carpet' 'Chateau Carpet - Blackcomb' (matched on 'chateaucarpet') | kept as its status alias; set status_aliases for the lift if the match is wrong |
| `official_lift_name_matched` | `lift:creekside-carpet` | the status feed calls 'Creekside Carpet' 'Creekside Carpet - Whistler - Whistler Kids Only' (matched on 'creeksidecarpet') | kept as its status alias; set status_aliases for the lift if the match is wrong |
| `official_lift_name_matched` | `lift:scampland-carpet` | the status feed calls 'Scampland Carpet' 'Scampland Carpet - Whistler - CLC -Whistler Kids Only' (matched on 'scamplandcarpet') | kept as its status alias; set status_aliases for the lift if the match is wrong |

## Graph flags

### `auto_link` (45)

A gap the map leaves at a lift, joined automatically within `link_tolerance_m` and 30 m of height: a lift station no run touches, a run drawn from near a lift's top or down to near its bottom without a shared node, or a lift cut off from the network. Built as a short connection.

- 50.09957, -122.94943: no run arrives at the bottom of Olympic Chair: n10917226233 joined to n369887841, 0.0 m, on way 33209954 Fantastic
- `w29362437:1` 50.09606, -122.90165: no run leaves the top of Blackcomb Gondola Upper: n6041106563 joined to n10865048188, 10.0 m, on way 29362437 Blackcomb Gondola Upper
- `w32775428:1` 50.05642, -122.94686: nothing reaches the start of Glacier Wall near Harmony 6 Express Chairlift: n3853977771 joined to n2622870030, 137.5 m, on way 32775428 Harmony 6 Express Chairlift
- `w32775428:2` 50.05642, -122.94686: nothing reaches the start of Excitation near Harmony 6 Express Chairlift: n3853977771 joined to n2622870019, 81.4 m, on way 32775428 Harmony 6 Express Chairlift
- `w32775428:3` 50.05642, -122.94686: nothing reaches the start of Exhilaration near Harmony 6 Express Chairlift: n3853977771 joined to n2622870039, 96.1 m, on way 32775428 Harmony 6 Express Chairlift
- `w32828959:1` 50.04614, -122.93959: nothing reaches the start of Piccolo Summit Slope near Symphony Express: n369887840 joined to n10905182997, 96.1 m, on way 32828959 Symphony Express
- `w39994999:5` 50.11538, -122.94780: no run arrives at the bottom of Magic Chair: n376762421 joined to n2639771118, 20.4 m, on way 39994999 Yellow Brick Road
- `w39994999:6` 50.11538, -122.94780: no run arrives at the bottom of Blackcomb Gondola Lower: n376762421 joined to n2639771128, 22.2 m, on way 39994999 Yellow Brick Road
- `w258644617:1` 50.11520, -122.94778: no way in to Blackcomb Kids Carpet: n2639771118 joined to n11625890102, 35.6 m, on way 258644617 Magic Chair
- `w258644618:1` 50.11443, -122.94737: no run leaves the top of Blackcomb Kids Carpet: n2639771125 joined to n11625890101, 16.2 m, on way 258644618 Blackcomb Kids Carpet
- `w258645935:1` 50.09829, -122.95099: no run leaves the top of It Happens Carpet: n2639783825 joined to n11633733635, 28.6 m, on way 258645935 It Happens Carpet
- `w258645935:2` 50.09829, -122.95099: no way in to It Happens Carpet: n2639783825 joined to n10917226277, 28.8 m, on way 258645935 It Happens Carpet
- `w258646026:1` 50.09726, -122.94893: no run leaves the top of Adult Supercarpet: n2639785180 joined to n11624954363, 12.5 m, on way 258646026 Adult Supercarpet
- `w258646027:1` 50.09891, -122.94995: no run leaves the top of Never Ever Flats Carpet: n2639785182 joined to n10917226243, 17.4 m, on way 258646027 Never Ever Flats Carpet
- `w258646027:2` 50.09891, -122.94995: no run arrives at the bottom of Top Carpet: n2639785182 joined to n10917226253, 11.7 m, on way 258646027 Never Ever Flats Carpet
- `w258646783:1` 50.09320, -122.98811: no run leaves the top of Creekside Carpet: n2639792861 joined to n11624956841, 17.4 m, on way 258646783 Creekside Carpet
- `w359277947:8` 50.11573, -122.94771: Merlin ends near Blackcomb Gondola Lower with nothing leaving: n615056848 joined to n2639771128, 38.6 m, on way 359277947 Merlin
- `w359277947:9` 50.11563, -122.94713: no way in to Chateau Carpet: n615056846 joined to n10870697145, 6.5 m, on way 359277947 Merlin
- `w867166528:1` 50.11558, -122.94716: no run arrives at the bottom of Chateau Carpet: n10870697145 joined to n8083112089, 9.6 m, on way 867166528 Chateau
- `w867166528:2` 50.11558, -122.94716: no way in to Chateau Carpet: n10870697145 joined to n615056846, 6.5 m, on way 867166528 Chateau
- `w870601791:5` 50.09833, -122.95059: no way in to It Happens Carpet: n10917226277 joined to n2639783825, 28.8 m, on way 870601791 Olympic - Upper
- `w872802940:2` 50.11176, -122.92259: no run arrives at the bottom of Excelerator Express: n10871502945 joined to n324831589, 20.0 m, on way 872802940 Excelerator Express Chairlift Access
- `w1131098056:4` 50.09839, -122.91682: no run arrives at the bottom of Catskinner Express: n10869074376 joined to n480516252, 14.0 m, on way 1131098056 Castle Green
- `w1168288206:3` 50.09601, -122.90153: no way down from the top of Blackcomb Gondola Upper: n10865048188 joined to n10865048190, 9.4 m, on way 1168288206 (unnamed)
- `w1174567117:1` 50.09367, -122.98877: no way in to Creekside Carpet: n2639792863 joined to n11624956842, 11.4 m, on way 1174567117 (unnamed)
- `w1174890337:6` 50.11279, -122.95373: no run arrives at the bottom of Whistler Village Gondola Lower: n10917007057 joined to n320777522, 57.0 m, on way 1174890337 Lower Olympic
- `w1174906007:4` 50.09934, -122.95015: no run arrives at the bottom of Never Ever Flats Carpet: n10917226245 joined to n2639785181, 15.2 m, on way 1174906007 Never Ever Flats
- `w1174906008:1` 50.09842, -122.94903: no run leaves the top of Top Carpet: n10917226254 joined to n10917226300, 16.3 m, on way 1174906008 Top Carpet
- `w1174906011:2` 50.09873, -122.95006: no way in to Adult Supercarpet: n10917226285 joined to n11624954364, 9.2 m, on way 1174906011 (unnamed)
- `w1174906013:1` 50.09721, -122.95069: no run leaves the top of Scampland Carpet: n10917226305 joined to n11633733634, 14.6 m, on way 1174906013 Scampland Carpet
- `w1250600112:1` 50.09868, -122.95016: no run arrives at the bottom of Adult Supercarpet: n11624954364 joined to n2639785179, 12.2 m, on way 1250600112 Adult Supercarpet
- `w1250600112:2` 50.09868, -122.95016: no way in to Adult Supercarpet: n11624954364 joined to n10917226285, 9.2 m, on way 1250600112 Adult Supercarpet
- `w1250603184:1` 50.09358, -122.98882: no run arrives at the bottom of Creekside Carpet: n11624956842 joined to n2639792860, 28.0 m, on way 1250603184 Creekside Kids
- `w1250603184:2` 50.09358, -122.98882: no way in to Creekside Carpet: n11624956842 joined to n2639792863, 11.4 m, on way 1250603184 Creekside Kids
- `w1250603185:1` 50.09521, -122.98927: Whistler Creek Ski Out ends near Creekside Gondola with nothing leaving: n11624956848 joined to n2639792863, 174.7 m, on way 1250603185 Whistler Creek Ski Out
- `w1250670056:1` 50.11149, -122.95580: Jam Tart ends near Whistler Village Gondola Lower with nothing leaving: n11625890100 joined to n320777522, 166.9 m, on way 1250670056 Jam Tart
- `w1250670057:1` 50.11502, -122.94819: no run arrives at the bottom of Blackcomb Kids Carpet: n11625890102 joined to n2639771124, 42.9 m, on way 1250670057 Blackcomb Kids Centre
- `w1250670057:2` 50.11502, -122.94819: no way in to Blackcomb Kids Carpet: n11625890102 joined to n2639771118, 35.6 m, on way 1250670057 Blackcomb Kids Centre
- `w1251510655:3` 50.09825, -122.95147: no run arrives at the bottom of It Happens Carpet: n11633733636 joined to n2639783823, 12.2 m, on way 1251510655 Scampland
- `w1251510655:4` 50.09803, -122.95102: no run arrives at the bottom of Scampland Carpet: n11633733635 joined to n10917226304, 21.7 m, on way 1251510655 Scampland
- `w1309517056:10` 50.11842, -122.90574: no run arrives at the bottom of Crystal Ridge Express: n12173788594 joined to n8747476684, 33.6 m, on way 1309517056 Glacier Road
- `w1315546515:10` 50.09593, -122.88217: no run arrives at the bottom of Showcase Quad: n12176985365 joined to n14220851300, 57.5 m, on way 1315546515 Crystal Traverse
- `w1525849949:1` 50.10713, -122.92391: no run leaves the top of Blackcomb Gondola Lower: n324831588 joined to n10870918949, 10.8 m, on way 1525849949 Blackcomb Gondola Lower
- `w1562634819:1` 50.09084, -122.87723: nothing reaches the start of Blow Hole near Showcase Quad: n325317563 joined to n8427031013, 69.5 m, on way 1562634819 Showcase Quad
- `w1562634819:2` 50.09084, -122.87723: nothing reaches the start of Blackcomb Glacier near Showcase Quad: n325317563 joined to n4558109998, 198.2 m, on way 1562634819 Showcase Quad

### `line_join` (15)

A run end drawn a few metres short of another run's line, or a run start just below one, joined to the nearest point on that line within `line_join_m` (a T-junction): only into a line that leads on to a lift, or from one skiers reach from a lift, never more than 5 m uphill or across a lift's cable. The line is split there, at a new `v…` vertex when no vertex of it is within 3 m. Built as a short one-way connection.

- 50.09933, -122.90312: Cougar Milk starts 0.0 m from Wishbone: n10858949502 joined to n10875845756, 0.0 m, on way 33198965 Wishbone
- 50.10859, -122.89836: Lower Straight Shot starts 0.0 m from Upper Straight Shot: n10857966516 joined to n10857966517, 0.0 m, on way 89855931 Upper Straight Shot
- `w39993397:6` 50.08259, -122.89088: Last Resort starts 13.5 m from Sunburn: n12229577764 joined to n12229577765, 13.6 m, on way 39993397 Sunburn
- `w255941579:4` 50.06955, -122.94718: unnamed run starts 6.9 m from Roundhouse Roll: n10881607069 joined to n10884113175, 7.0 m, on way 255941579 Roundhouse Roll
- `w541465876:1` 50.09578, -122.88117: Crystal Traverse starts 1.6 m from an unnamed way: n12176985348 joined to n12176985350, 1.7 m, on way 541465876 (unnamed)
- `w1134582536:1` 50.09481, -122.89885: unnamed run ends 7.8 m from Rendevous Drive: n10577212754 joined to vab1287f4263a, 7.8 m, on way 1134582536 (unnamed)
- `w1168288211:4` 50.09562, -122.90116: unnamed run starts 8.9 m from Expressway Access: vabadc2629222 joined to n889758891, 8.9 m, on way 1168288211 Expressway Access
- `w1171275224:1` 50.06957, -122.94697: unnamed run ends 15.3 m from Roundhouse Roll: n10884113166 joined to n10881607069, 15.3 m, on way 1171275224 (unnamed)
- `w1171275226:1` 50.06925, -122.94648: unnamed run ends 17.3 m from an unnamed way: n10884113172 joined to n10884113167, 17.4 m, on way 1171275226 (unnamed)
- `w1250670054:2` 50.09040, -122.98788: Lit Champs Glades starts 1.3 m from Kadenwood Ski Out: n13005849546 joined to n11624956834, 1.8 m, on way 1250670054 Kadenwood Ski Out
- `w1284115405:1` 50.11146, -122.94358: Lot 6 Access ends 34.0 m from Excalibur Gondola Download: n1040556194 joined to n10871751274, 34.2 m, on way 1284115405 Lot 6 Access
- `w1309517056:11` 50.11315, -122.91308: Blackcomb Glacier Road - Lower starts 2.9 m from Glacier Road: n12173829647 joined to n12125793451, 3.0 m, on way 1309517056 Glacier Road
- `w1315937945:2` 50.05600, -122.94964: Dilemma starts 25.1 m from Saddle Connector: vf5c9522dec24 joined to n2622870098, 25.2 m, on way 1315937945 Saddle Connector
- `w1316221531:2` 50.06901, -122.94635: unnamed run starts 13.0 m from Ego Bowl Access: vd3df0843457a joined to n10884113167, 13.1 m, on way 1316221531 Ego Bowl Access
- `w1354986263:1` 50.09491, -122.87354: Double Rubble ends 14.1 m from Surf's Up: n12539671509 joined to v02d37cbbf942, 14.1 m, on way 1354986263 Double Rubble

### `orphan_edge` (6)

This piece is not connected to any lift. Fix the shared node in OSM or `exclude_ways` it.

- `w140799449:0` 50.07353, -122.88205: in a part of the network with no lift
- `w472098498:0` 50.07878, -122.86820: in a part of the network with no lift
- `w1250603186:0` 50.08679, -122.99278: in a part of the network with no lift
- `w1251510656:0` 50.09040, -122.94719: in a part of the network with no lift
- `w1354986264:0` 50.09294, -122.87407: in a part of the network with no lift
- `w1482734758:0` 50.09240, -122.86272: in a part of the network with no lift

### `rendezvous_dropped` (28)

A proposed meeting point that is not in the connected network (and not a lift bottom skiers can ski to from it), so two skiers could not both reach it. Removed.

- 50.09077, -122.94506: 4-6-bottom (Bottom of 4.6) is outside the connected network; dropped
- 50.10398, -122.87797: bad-attitude-bottom (Bottom of Bad Attitude) is outside the connected network; dropped
- 50.08899, -122.99384: bear-creek-ski-in-bottom (Bottom of Bear Creek Ski in) is outside the connected network; dropped
- 50.11319, -122.93657: blackcomb-home-run-bottom (Bottom of Blackcomb Home Run) is outside the connected network; dropped
- 50.07726, -122.87882: body-bag-bowl-bottom (Bottom of Body Bag Bowl) is outside the connected network; dropped
- 50.10122, -122.87819: calvin-bottom (Bottom of Calvin) is outside the connected network; dropped
- 50.10205, -122.87597: diamond-bowl-bottom (Bottom of Diamond Bowl) is outside the connected network; dropped
- 50.10051, -122.87763: diamond-bowl-left-entrance-helter-skelter-bottom (Bottom of Diamond Bowl Left Entrance (Helter Skelter)) is outside the connected network; dropped
- 50.09491, -122.87354: double-rubble-bottom (Bottom of Double Rubble) is outside the connected network; dropped
- 50.04638, -122.92462: flute-chutes-bottom (Bottom of Flute Chutes) is outside the connected network; dropped
- 50.03969, -122.92562: flute-summit (Flute Summit) is outside the connected network; dropped
- 50.10039, -122.87924: garnet-bowl-center-bottom (Bottom of Garnet Bowl Center) is outside the connected network; dropped
- 50.10170, -122.88037: garnet-bowl-left-bottom (Bottom of Garnet Bowl Left) is outside the connected network; dropped
- 50.09932, -122.87864: garnet-bowl-right-bottom (Bottom of Garnet Bowl Right) is outside the connected network; dropped
- 50.10126, -122.87659: hobbs-right-bottom (Bottom of Hobbs (Right)) is outside the connected network; dropped
- 50.08583, -122.98770: home-run-bottom (Bottom of Home Run) is outside the connected network; dropped
- 50.09846, -122.87712: low-entry-bottom (Bottom of Low Entry) is outside the connected network; dropped
- 50.09792, -122.87804: main-entry-bottom (Bottom of Main Entry) is outside the connected network; dropped
- 50.04487, -122.92650: main-flute-bowl-bottom (Bottom of Main Flute Bowl) is outside the connected network; dropped
- 50.04486, -122.92333: north-bowl-cornice-bottom (Bottom of North Bowl Cornice) is outside the connected network; dropped
- 50.10490, -122.87746: playland-bottom (Bottom of Playland) is outside the connected network; dropped
- 50.09905, -122.87318: sapphire-chutes-bottom (Bottom of Sapphire Chutes) is outside the connected network; dropped
- 50.09739, -122.87834: sapphire-traverse-bottom (Bottom of Sapphire Traverse) is outside the connected network; dropped
- 50.04211, -122.92697: search-ski-areas-lifts-and-runs-stuies-slope-bottom (Bottom of Search Ski Areas, Lifts, and Runs Stuie's Slope) is outside the connected network; dropped
- 50.10347, -122.88035: skid-lips-bottom (Bottom of Skid Lips) is outside the connected network; dropped
- 50.10148, -122.88212: spankys-chute-bottom (Bottom of Spanky's Chute) is outside the connected network; dropped
- 50.10434, -122.87999: spankys-shoulder-bottom (Bottom of Spanky's Shoulder) is outside the connected network; dropped
- 50.08649, -122.98850: upper-kadenwood-trail-bottom (Bottom of Upper Kadenwood Trail) is outside the connected network; dropped

### `run_dead_end` (14)

Nothing leaves the end of this run: no further run, no lift. Usually a lift base or the next run starts a few metres away without a shared node.

- `w48427915:0` 50.11319, -122.93657: Blackcomb Home Run ends at n3708775098 with nothing leaving
- `w89546305:1` 50.08583, -122.98770: Home Run ends at n13005849720 with nothing leaving
- `w140799449:0` 50.07469, -122.88267: unnamed run ends at n1541851475 with nothing leaving
- `w472098498:0` 50.07726, -122.87882: Body Bag Bowl ends at n4663322161 with nothing leaving
- `w1167657608:0` 50.09792, -122.87804: Main Entry ends at n10859516685 with nothing leaving
- `w1167657609:0` 50.09779, -122.87833: 2M Gully ends at n10889788691 with nothing leaving
- `w1169399416:0` 50.11282, -122.93459: Blackcomb Home Run ends at n615056458 with nothing leaving
- `w1173784971:0` 50.04374, -122.93414: Flute Bowls Access ends at n10906040310 with nothing leaving
- `w1236006087:1` 50.08649, -122.98850: Kadenwood Trail ends at n9460782951 with nothing leaving
- `w1250603186:0` 50.08899, -122.99384: Bear Creek Ski in ends at n1418900402 with nothing leaving
- `w1251510656:0` 50.09077, -122.94506: 4.6 ends at n11633733651 with nothing leaving
- `w1304534124:0` 50.11202, -122.93211: Blackcomb Home Run ends at n11913314922 with nothing leaving
- `w1354986264:0` 50.09739, -122.87834: Sapphire Traverse ends at n12539671517 with nothing leaving
- `w1482734758:0` 50.09557, -122.86845: Asian Pussy (AP) ends at n13597024288 with nothing leaving

### `run_reversed` (4)

Mapped uphill; the build turned it around. No action unless the direction looks wrong on the preview.

- `w33199488:0` 50.11168, -122.92284: unnamed run is mapped uphill; built in the downhill direction
- `w1168288206:0` 50.09608, -122.90117: unnamed run is mapped uphill; built in the downhill direction
- `w1170437171:0` 50.09829, -122.91693: unnamed run is mapped uphill; built in the downhill direction
- `w1311153318:0` 50.10023, -122.89115: Upper Coyote Road is mapped uphill; built in the downhill direction

### `run_uphill` (6)

The elevation model says this piece climbs. Check the way direction in OSM, or `exclude_ways` it.

- `w33205312:1` 50.11102, -122.94404: unnamed run climbs 5.5 m here; built as a connection
- `w62252090:0` 50.10753, -122.89166: Ridge Runner climbs 5.7 m here; built as a connection
- `w161731776:0` 50.06957, -122.93326: unnamed run climbs 5.7 m here; built as a connection
- `w1167351958:1` 50.11917, -122.90664: Excelerator Express Chairlift Access climbs 7.0 m here; built as a connection
- `w1309042163:2` 50.07556, -122.95701: Bear Cub - Upper climbs 5.1 m here; built as a connection
- `w1311153318:4` 50.10023, -122.89115: Upper Coyote Road climbs 10.0 m here; built as a connection

### `snap` (12)

A gap closed under `snap_tolerance_m`, built as a short connection.

- 50.09631, -122.90074: run end with no continuation: n10879125563 joined to n376376694, 0.0 m, on way 39993407 (unnamed)
- 50.06878, -122.94839: run end with no continuation: n11907297510 joined to n611220554, 0.0 m, on way 1171282952 Ski Patrol Roll
- 50.09295, -122.94637: run end with no continuation: n12121438627 joined to n2639787361, 0.0 m, on way 1174906012 (unnamed)
- 50.08637, -122.98450: run end with no continuation: n613335715 joined to n13005815158, 0.0 m, on way 48270134 Lower Kadenwood Trail
- `w48298382:1` 50.09519, -122.95584: run end with no continuation: n611220731 joined to n10916996478, 8.8 m, on way 48298382 Tokum
- `w1134582535:1` 50.09608, -122.90103: run end with no continuation: n10863483201 joined to n10865048192, 9.6 m, on way 1134582535 (unnamed)
- `w1161169016:4` 50.10671, -122.90074: run end with no continuation: n10879928258 joined to n10799989036, 5.1 m, on way 1161169016 Cougar Milk
- `w1167657606:1` 50.09846, -122.87712: run end with no continuation: n10859516662 joined to n10859524532, 5.2 m, on way 1167657606 Low Entry
- `w1168862802:1` 50.09882, -122.89717: run end with no continuation: n12136855813 joined to n12136855814, 11.5 m, on way 1168862802 Cougar Chutes
- `w1169045315:1` 50.10594, -122.92088: run end with no continuation: n12175271304 joined to n12175393581, 5.4 m, on way 1169045315 Gemini Freestyle Center
- `w1251510655:5` 50.09843, -122.95159: run end with no continuation: n11633733637 joined to n2639783823, 13.9 m, on way 1251510655 Scampland
- `w1310685815:1` 50.11302, -122.91320: run end with no continuation: n12125793454 joined to n12173829706, 2.2 m, on way 1310685815 Blackcomb Glacier Road - Lower

### `unnamed_run` (110)

Kept with its mapped difficulty, or unknown when the way has none. Name it in OSM if it is a real run.

- `w29166974:0` 50.06828, -122.94544: way 29166974 has no name; kept
- `w33198963:0` 50.10343, -122.90508: way 33198963 has no name; kept
- `w33199488:0` 50.11168, -122.92284: way 33199488 has no name; kept
- `w33199489:0` 50.11120, -122.92354: way 33199489 has no name; kept
- `w33205312:0` 50.11109, -122.94375: way 33205312 has no name; kept
- `w33206720:0` 50.05642, -122.94686: way 33206720 has no name; kept
- `w33211821:0` 50.06765, -122.94593: way 33211821 has no name; kept
- `w39993407:0` 50.09589, -122.89981: way 39993407 has no name; kept
- `w48109149:0` 50.06713, -122.95010: way 48109149 has no name; kept
- `w48269894:0` 50.09732, -122.95326: way 48269894 has no name; kept
- `w48427920:0` 50.11232, -122.93909: way 48427920 has no name; kept
- `w89773878:0` 50.10630, -122.91795: way 89773878 has no name; kept
- `w89867182:0` 50.10938, -122.89597: way 89867182 has no name; kept
- `w89867187:0` 50.10935, -122.89987: way 89867187 has no name; kept
- `w89867191:0` 50.10867, -122.89619: way 89867191 has no name; kept
- `w140799449:0` 50.07353, -122.88205: way 140799449 has no name; kept
- `w161731776:0` 50.06957, -122.93326: way 161731776 has no name; kept with difficulty unknown
- `w461517644:0` 50.10205, -122.87597: way 461517644 has no name; kept
- `w541465876:0` 50.09582, -122.88123: way 541465876 has no name; kept
- `w867166533:0` 50.11120, -122.92370: way 867166533 has no name; kept with difficulty unknown
- `w867166535:0` 50.11186, -122.92285: way 867166535 has no name; kept with difficulty unknown
- `w872802942:0` 50.10665, -122.90089: way 872802942 has no name; kept with difficulty unknown
- `w1134582535:0` 50.09568, -122.90124: way 1134582535 has no name; kept
- `w1134582536:0` 50.09431, -122.89819: way 1134582536 has no name; kept
- `w1134582537:0` 50.09425, -122.89776: way 1134582537 has no name; kept
- `w1134582540:0` 50.09384, -122.89811: way 1134582540 has no name; kept
- `w1166216597:0` 50.09902, -122.89423: way 1166216597 has no name; kept
- `w1167250470:0` 50.10464, -122.89821: way 1167250470 has no name; kept
- `w1167250473:0` 50.09169, -122.88403: way 1167250473 has no name; kept
- `w1167250474:0` 50.10763, -122.89176: way 1167250474 has no name; kept
- `w1167536715:0` 50.10800, -122.89460: way 1167536715 has no name; kept
- `w1167536716:0` 50.10822, -122.89473: way 1167536716 has no name; kept
- `w1167536718:0` 50.11422, -122.89483: way 1167536718 has no name; kept
- `w1167540641:0` 50.11211, -122.89741: way 1167540641 has no name; kept
- `w1167611274:0` 50.09438, -122.89781: way 1167611274 has no name; kept
- `w1167611275:0` 50.09358, -122.89755: way 1167611275 has no name; kept
- `w1167657613:0` 50.09905, -122.87318: way 1167657613 has no name; kept
- `w1167657616:0` 50.10111, -122.87457: way 1167657616 has no name; kept
- `w1167852428:0` 50.10398, -122.87797: way 1167852428 has no name; kept
- `w1168161545:0` 50.10489, -122.87913: way 1168161545 has no name; kept
- `w1168288204:0` 50.09578, -122.90024: way 1168288204 has no name; kept with difficulty unknown
- `w1168288206:0` 50.09601, -122.90153: way 1168288206 has no name; kept with difficulty unknown
- `w1168288207:0` 50.09608, -122.90117: way 1168288207 has no name; kept
- `w1168288208:0` 50.09603, -122.90141: way 1168288208 has no name; kept
- `w1168288213:0` 50.09585, -122.90146: way 1168288213 has no name; kept
- `w1168288214:0` 50.09527, -122.90194: way 1168288214 has no name; kept
- `w1168308424:0` 50.09767, -122.90113: way 1168308424 has no name; kept
- `w1169013703:0` 50.10728, -122.92377: way 1169013703 has no name; kept
- `w1169013704:0` 50.10683, -122.92351: way 1169013704 has no name; kept
- `w1169100343:0` 50.11092, -122.92218: way 1169100343 has no name; kept
- `w1169134352:0` 50.11032, -122.94270: way 1169134352 has no name; kept
- `w1169134357:0` 50.11139, -122.94174: way 1169134357 has no name; kept
- `w1169324286:0` 50.10672, -122.90011: way 1169324286 has no name; kept
- `w1170012743:0` 50.10662, -122.90137: way 1170012743 has no name; kept
- `w1170437171:0` 50.09829, -122.91693: way 1170437171 has no name; kept
- `w1170437172:0` 50.09622, -122.90942: way 1170437172 has no name; kept
- `w1170996715:0` 50.08361, -122.94097: way 1170996715 has no name; kept
- `w1171004997:0` 50.07312, -122.94454: way 1171004997 has no name; kept
- `w1171042574:0` 50.06759, -122.93093: way 1171042574 has no name; kept
- `w1171231668:0` 50.06526, -122.93567: way 1171231668 has no name; kept
- and 50 more, all in the GeoJSON preview

### `way_skipped` (1)

Left out of the graph for the reason given (`other_ski_area` means OpenSkiMap puts it in a neighbouring resort; `not_operating` that it is planned, being built or closed for good).

- 50.09339, -122.98885: lift way 682523542 Kadenwood Gondola left out: private

## What would change the result

- Check each `run_uphill` piece; it is built as a connection until the elevation or the way direction is fixed.
- Map at least 80 % of lift groups to their provider names (official list or `status_aliases` in the decisions file); until then the resort publishes as `scheduled_only`.
