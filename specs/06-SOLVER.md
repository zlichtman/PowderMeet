# 06 MeetSolver

A pure Swift package. Given one immutable bundle, an expiry-stamped status, conditions,
two skiers and a time, it returns ranked meeting options and per-skier routes, or a
typed failure. It never mutates the graph, never reads a clock, never touches the
network, and produces identical output for identical input on any device.

## 1. Public API

```swift
public struct RoutingOrigin: Hashable, Sendable {
  public enum Kind: Hashable, Sendable { case node(NodeID); case onEdge(EdgeID, fraction: Double) }
  public var kind: Kind
  public var fixAccuracyM: Double          // feeds initial variance
}
public struct SkierInput: Hashable, Sendable {
  public var id: UUID
  public var profile: SkierProfile
  public var pace: PaceModel?
  public var origin: RoutingOrigin
}
public enum StatusPolicy: Hashable, Sendable { case strict, degraded }   // DECISION 1 → degraded
public struct SolveOptions: Hashable, Sendable {
  public var maxOptions = 5
  public var maxLabelsPerNode = 8
  public var fairnessAlpha: Double? = nil  // nil → from conditions/kind table
  public var statusPolicy: StatusPolicy = .degraded
}
public struct SolveInput: Hashable, Sendable {
  public var bundle: ResortBundle            // Hashable by bundle_id
  public var status: ResortStatus?
  public var conditions: Conditions?
  public var at: Date                        // quantized to 60 s inside
  public var skiers: (SkierInput, SkierInput)
  public var options: SolveOptions
}

public struct ETA: Hashable, Sendable { public var meanS: Double; public var sdS: Double }
public struct RouteLeg: Hashable, Sendable { public var edgeID: EdgeID; public var enterS: Double; public var exitS: Double; public var startFraction: Double }
public struct Route: Hashable, Sendable {
  public var skierID: UUID; public var legs: [RouteLeg]; public var eta: ETA
  public var hardestDifficulty: Difficulty; public var liftCount: Int; public var lengthM: Double
  public var easiestWayDown: EasiestWayDown?   // set only on an easiest way down, below
  public var weatherFavours: [WeatherFavour]   // the weather that steered it, most material first; see section 3
}
public enum WeatherFavour: Hashable, Sendable, CaseIterable { case sunnySide, shadySide, outOfTheWind, clearerView }
public struct EasiestWayDown: Hashable, Sendable {
  public var hardest: Difficulty; public var runsAboveLevel: [Difficulty: Int]  // a split run counts once
  public var metresAboveLevel: Double; public var edgeIDs: [EdgeID]
}
public struct MeetOption: Hashable, Sendable {
  public var rendezvous: RendezvousID
  public var routes: (Route, Route)
  public var score: Double                   // reliability score, lower is better
  public var expectedWaitS: Double           // |tA − tB|
  public var reasons: [Reason]               // typed, rendered by the app; skiers.0 is "you"
  public var sharedContinuation: SharedContinuation?   // what both can do next (ranking evidence)
  public var lapWhileWaiting: Route?         // loop for the skier who would wait; counted by the score, see section 3
  public var tradeoff: Tradeoff?             // the card headline against the other options, see section 3
}
public struct MeetOptions: Hashable, Sendable { public var options: [MeetOption]; public var statusFreshness: StatusFreshness; public var degraded: Bool }

public enum SolveFailure: Error, Hashable, Sendable {
  case originNotOnGraph(UUID)
  case noRendezvousReachable(UUID)           // for this skier under gates
  case statusExpired                         // only under .strict
  case bundleUnusable(String)
  case abilityBlocksAll(UUID)
  case liftDeadlineRisk                      // the only shared routes need a lift too close to last chair
  case lostAll                              // untraversable remainder for recost
}

public enum MeetSolver {
  public static func solve(_ input: SolveInput) -> Result<MeetOptions, SolveFailure>
  public static func route(for skier: SkierInput, to rendezvous: RendezvousID, in input: SolveInput) -> Result<Route, SolveFailure>
  public static func recost(_ route: Route, from progress: Progress, at: Date, in input: SolveInput) -> ETA?
  public static func maneuvers(for route: Route, in bundle: ResortBundle) -> [Maneuver]
}
public struct Progress: Hashable, Sendable {   // a value; each fix produces the next from the last
  public enum State { case onRoute, offRoute, arrived }
  public var legIndex: Int; public var fractionAlongLeg: Double; public var state: State
  public var remainingM: Double; public var deviationM: Double; public var lastFixAt: Date?
}
public enum RouteProgress {
  public static func start(_ route: Route, in bundle: ResortBundle) -> Progress
  public static func project(fix: Fix, onto route: Route, in bundle: ResortBundle, after previous: Progress) -> Progress
}
public enum RouteSwitchPolicy { public static func decide(current: ETA, currentRemainingEdgeIDs: [EdgeID], candidate: Route, secondsSinceLastSwitch: TimeInterval?) -> RouteSwitchDecision }
public final class SolveCache: Sendable { init(capacity: Int); func value(for: SolveInput, compute: () -> Result<MeetOptions, SolveFailure>) -> Result<MeetOptions, SolveFailure> }
```

Easiest way down: when the two share no stop within their levels (and the cause
is not a lift too close to last chair), a skier with no way down within their
level gets the least hard way there is, so two people can always meet. Only the
difficulty limit relaxes; avoid choices, the pitch limit, closures, lift hours and
one-way edges stay hard. Caps rise one rating at a time above the skier's limit
(park counts as black) and the first that gives a shared stop wins: hardest run
first. Within it, relaxing one skier beats relaxing both, then fewer metres of run
above the level (labels carry them and compare them first, so a node keeps only
its fewest), then the usual ranking of the stops with the fewest, then skier ids,
so either phone's order gives the same answer. A within-level meet is never
replaced. Each such route carries `easiestWayDown` (hardest run, runs above the
level by rating, metres, edges) and its option the reason `easiestWayDownFor`.
`route` does the same when the skier cannot reach the agreed stop within their
level, so the invitee and navigation get it too; `recost` re-prices such a route
with the cap of its hardest run, never harder, and closures still end it.

Failure mapping: dead-end or unknown start →
`originNotOnGraph`; start or route blocked only by the skier's limits, with no
easiest way down (an avoid choice or the pitch limit blocks it) →
`abilityBlocksAll`; no shared reachable stop → `noRendezvousReachable`; empty catalog →
`bundleUnusable`. `Fix` (coordinate, accuracy, capture time) lives in `MountainCore`.

## 2. Cost model

One value per solve per skier, built from inputs; no globals. Constants live in
`Constants.swift`: the cost and search values and the ranking weights (section 3).
Changing one changes solver output.

```
traverse(edge, departure t, skier):
  run:   length / speed + stops, where
         speed = baseline[difficulty] × pace.difficultyFactor[difficulty] × pace.edgeFactor[edge]
                 × terrain modifier × environment modifier
         terrain (skipped when the edge has a learned edgeFactor, which already contains it):
                 grooming (groomed: none; ungroomed: the ability's off-piste comfort; unknown:
                 half-way), icy-ability below −3 °C, gradient ramp from 90 % of the ability's
                 comfortable pitch; combined with diminishing returns, floor 0.35
         environment: sun on the edge's aspect at arrival (an unknown aspect counts as
                 half turned to the sun, so it fades in from the horizon and never jumps at
                 sunrise), felt wind above 30 km/h, visibility
                 below 5 km (×1.5 on pitches over 25°), fresh snow over 5 cm off-piste, cold-snow
                 glide; floor 0.60; small bonus for fresh snow on a groomed run
         felt wind = (wind + 0.3 × (gust − wind)) × height factor; the height factor is
                 1 + 0.25 per 1,000 m above the forecast's height (`elevation_m`; the
                 reference elevation on a row without it), held to 0.8…1.3 (a judgement:
                 forecasts are for one height, ridges above it are windier). With a wind
                 direction and an aspect it is × (1 + 0.15 × cos(aspect − direction)):
                 windward slopes take it, lee slopes are sheltered
         temperature at the edge's height: with `elevation_m`, linear between the
                 reading at that height and `temp_850_c` at 1,457 m and `temp_700_c` at
                 3,012 m (a level within 150 m of the forecast height is ignored), so an
                 inversion is followed; above the top level its slope carries on, held to
                 −9.8…0 °C/km; below the forecast height, or with no level, −6.5 °C/km.
                 Without `elevation_m`: −6.5 °C/km from the reference elevation
         visibility at the edge's height: with `elevation_m`, `dew_point_c` and
                 `cloud_low_pct`, the cloud base is forecast height + 125 m × (temperature
                 − dew point); a run entering it loses the view over 100 m of climb, down
                 to min(reading, 0.5 km), in proportion to low cloud from 30 % to 70 %. The
                 cloud top is unknown, so everything above the base counts as in it, and
                 valley fog under clear summits is not modelled. The same height-adjusted
                 visibility feeds the weather hazard and wait weight at a stop
         refrozen crust: with `recent`, a run whose warmest hour of the last day (the
                 resort peak moved to the run's height) was above freezing and which is
                 below −1 °C now loses up to 15 % (40 % of that when groomed), fading in
                 over 2 °C on each side and out under 5 cm of new snow (a judgement)
         grooming = status.groomed (fresh status only) else groomed_default
         stops = pace.stopsPerKm × length × 20 s (0.4/km when there is no pace model)
         ability coefficients come from `Ability` (the onboarding presets);
         `prefersGroomed` lowers off-piste comfort by 0.2
  lift:  queue(t) + boarding penalty + ride_s × wind factor
         queue(t) = base by lift type (gondola/cable car 180 s, chair 90, T-bar 45, rope tow 30,
                 carpet 15) × capacity factor (≥ 3000 pph 0.7, ≥ 2000 pph 0.85) × hour-of-day
                 curve, linear between hourly anchors × 1.4 at weekends, capped at 10 min;
                 FIFO monotonic (I-04)
         live queue: with fresh status carrying `wait_minutes` for the lift's group, the
                 reported wait (capped at 45 min) replaces the modelled queue for an arrival
                 up to 30 min after `observed_at`, then hands back to the model linearly over
                 the next 60 min. The handover moves the wait by at most 0.75 s per second of
                 delay, so FIFO holds. It is part of the queue, so it counts against last
                 chair, and a hold still adds its 15 min. Unknown wait (no entry, or a reported 0,
                 which feeds also use for "not measured"): the model, unchanged
         wind factor is continuous (1.0 to 40 km/h, 1.2 at 60, 1.5 at 80, 3.0 at 120) and scales
                 the ride only
         wind hold: where no fresh status speaks for the lift (no group, a `scheduled`
                 group, or degraded status) and no live wait is reported, the queue gains
                 likelihood × 15 min. Likelihood rises linearly from 0 to 1 over 30 km/h of
                 gust at the top station (gust × height factor), starting at 50 km/h for a
                 gondola, 55 chair, 60 cable car, 80 surface lifts (rough public operating
                 figures). It is part of the queue, so it counts against last chair. At a
                 likelihood of 0.5 or more on a boarded lift the option carries
                 `.windHoldLikelyFor(skier)`
         operating_hours: days are ISO weekdays (1 = Monday) in the bundle's time zone; a lift
                 with none listed uses 07:00–21:00. A lift reached outside its window, or whose
                 queue would end at or after close, is untraversable (I-08). It must also be
                 catchable at the P90 approach arrival (mean + 1.2816 σ)
         a segment that continues a ride already boarded (next split ordinal of the same way,
                 same direction) charges no queue and is not gated on hours
         a skier already part-way along a lift edge pays only the remaining ride
  connection: length / (1.5 m/s × fresh-snow factor) + 6 s per metre climbed
  variance: (cv × elapsed)² with cv = 0.15 run, 0.30 lift, 0.10 connection; adjacent edges of
         one action (same group) are fully correlated, separate actions independent; the origin
         adds (fix accuracy ÷ 2 m/s)²
  status: closed group → untraversable; hold → queue += 15 min; scheduled or absent → hours only;
         live waits as above (fresh status only, like hold and grooming)
  ability: difficulty > profile.maxDifficulty, or no baseline speed for it → untraversable
         (hard gate, both policies; only the easiest way down, section 1, raises it). Ability sets pace only: every `SkierProfile.preset`
         has a speed for every rating, and the client fills a rating a stored row lacks
         from the preset, so in practice `maxDifficulty` (the skier's own choice; the
         preset's is only a new account's default) is the gate. `park` is open from `black` up. `unknown` with a measured pitch is gated and
         paced by that pitch (≤17° green, ≤23° blue, ≤33° black, steeper or no pitch: the
         bundle's hardest marked difficulty; never harder than that).
  limits: the skier's own choices, hard gates like ability and reported the same way
         (`abilityBlocksAll`). A run is untraversable when
           profile.avoid has `park` and it is a park run;
           profile.avoid has `ungroomed` and its grooming (as above) is known to be false;
           profile.avoid has `flats` and it is ≥ 100 m long with a mean pitch under 3°
             (mean pitch = atan(drop / length));
           profile.maxPitchDeg is set and its pitch is over it, the pitch being
             grade_max_deg, or when the bundle has none (or a value that is not a
             pitch: ≤ 0, over 90° or not finite) the usual steepest pitch of its
             effective difficulty (17° green, 23° blue, 33° black, 45° otherwise);
           profile.maxPitchDeg is set but not an angle in (0°, 90°] (corrupt data):
             every run, so a bad limit never switches the gate off.
         A lift is untraversable when profile.avoid has `surface_lifts` and it is a
         T-bar, rope tow or carpet. Limits apply to starting an edge: a skier already
         part-way down a run, or already on a lift, finishes it. Difficulty does not get
         that exemption.
  equipment (skipped, like terrain, when the edge has a learned edgeFactor):
         gear = waist × type × length × weight, clamped to 0.90...1.06, multiplies speed:
           waist: w = clamp((waist_mm − 90) / 30, −1, 1); skis with no waist given use
             72 carving, 88 all-mountain, 92 park, 106 freeride.
             Groomed: 1 − 0.015·w. Otherwise 1 + 0.01·w at ≤ 3 cm of fresh snow rising
             linearly to 1 + 0.03·w at 8 cm.
           type: +1 % carving on a groomed run, +1 % freeride off-piste with ≥ 8 cm
             fresh (linear from 3 cm), +2 % park on a park run.
           length (needs equipment.length_cm and profile.heightCM):
             s = clamp((length / height − 0.95) / 0.08, −1, 1).
             Groomed and under 25°: 1 + 0.02·s.
             Ungroomed or 30° and over: 1 − 0.03·s. Between: 1.
           weight (needs profile.weightKG): (kg / 75)^(1/6) on runs with a mean pitch
             of 3° or less, fading linearly to no effect at 10°.
         heightCM and weightKG are nil for anyone but the device's own skier
         (`02-DOMAIN.md` section 5.1), so those two terms are 1 for a partner.
```
`degraded` policy differs from `strict` only in what happens when
`StatusFreshness != fresh`: strict → `statusExpired`; degraded → treat every group as
`scheduled`, set `MeetOptions.degraded = true`, and the app badges every card.
Known closures in a stale-but-present row ARE still honored in degraded mode.
`route(for:to:in:)` returns a bare `Route` with no degraded flag, so the cards for an
incoming request, an active meet and a Go to work out `StatusFreshness` from the status
themselves (`MeetPresentation`).

A two-way lift or connection (`one_way: false`) is also traversable to→from. The
client names that traversal `<edge_id>~rev`; the id never appears in a bundle and is
never sent to the server. Every other lift is ridden bottom to top only. Whether a
lift downloads is the bundle's call, not the solver's: the solver never second-guesses
`one_way` by lift type, so a chair the source tags `oneway=no` is offered downhill,
and a wrong tag is fixed in the pipeline.

### 2.1 Calibration check: Whistler's lift waits

The modelled queue is a base by lift type with an hourly curve, not per-lift numbers.
Per-lift weekday and weekend queue minutes for Whistler Blackcomb are kept here as a
check on that model, not as an input: Village Gondola 5 and 15, Creekside Gondola 3 and
8, Peak 2 Peak 8 and 20, with lifts running 08:00 to 16:00. A Whistler solve whose
modelled queues sit far from these at mid-morning needs its base or curve looked at.

### 2.2 Run-card meters (`TrailConditions`, MountainCore)

The Grooming, Moguls and Glide meters on the run card are not solver inputs. Moguls,
on a run not groomed: a base of 0.15, or 0.55 on an edge the bundle flags `moguls`;
plus the mean pitch / 120 (at most 0.25); minus 0.3 after more than 15 cm in 24 h or
0.15 after more than 5 cm; plus 0.1 between -2 and 2 °C; clamped to 0...1. Snow
freshness: more than 10 cm in 24 h scores 1.0, more than 3 cm 0.85; then, where the
sample carries them, more than 15 cm in 72 h 0.65, more than 5 cm in 72 h 0.45, depth
over 100 cm 0.35, over 50 cm 0.20; else 0.10. The glide meter loses up to 0.2 to the
sun on a south-facing run only.

## 3. Search

- Per skier: label-setting Dijkstra over arrival time with up to `maxLabelsPerNode`
  non-dominated labels on (mean, variance, current-action uncertainty, action count)
  (I-02), compared only between labels that end on the same action. The fastest
  mean-time label is always kept when the cap trims. Edges are iterated in a fixed
  order (sorted `edge_id`); labels are popped by (reliability score, mean, variance,
  node_id, edge_id, label id) so ties are deterministic (I-13). A label's reliability
  score is `mean + 0.5·sd + simplicity`, where simplicity is 8 s per change of trail
  or lift, capped at 32 s; it never enters a displayed ETA.
- Candidates: every rendezvous reachable by both; for each, the best approach pair by
  joint reliability, drawn only from approaches within max(30 s, 15 %) of that skier's
  fastest (I-01, I-02). Wait never enters approach selection.
- Hard rule, everyone can leave: a candidate is eligible only if each skier, alone and
  within their own limits, has a way on from it 90 s after the later arrival: a run
  they can ski or a running lift they can ride, at the stop or up to three connectors
  from it. A lift counts only if it does not strand them: where it lets them off
  (following a split lift to its end) they again have a run they can ski or a lift
  they can ride. `lodge` and `landmark` stops are places people go to stop, so one
  with nothing leading on (a base lodge, any lodge after last chair) stays eligible;
  one whose only runs out are beyond the skier's limit does not. `lift_base`,
  `lift_top` and `junction` stops get no exemption. If the rule removes every
  candidate the unfiltered list is ranked instead and each option carries
  `.noOnwardRouteFor(skier)` for whoever is stuck; the solve does not fail.
- Score, in seconds, lower is better (I-03):
  `max(tA, tB) + alpha · idle + 0.5 · lap + 0.5 · max(0, |tA − tB| − 5 min)
  + 0.5 · sqrt(varA + varB) + simplicity(pair) + onward − lodgeCredit
  + 90 · (1 − confidence) + 120 · (1 − quality)`,
  then expected arrival, idle, spread, uncertainty, simplicity, onward, catalog
  confidence, stop quality, id.
  - Waiting is split in two. `lap` is the length of the lap the earlier skier can fit
    into the gap `|tA − tB|` (lap while you wait, below; zero when the gap is under
    five minutes or no lap fits) and `idle = |tA − tB| − lap` is the time they stand
    at the stop. A skier lapping is skiing, not waiting, so a lapped second costs 0.5
    (and never more than `alpha`): not nothing, because they ski it alone and against
    a deadline, and a stop both travel to should still win when one exists.
  - A long gap costs more again (`Scoring.unevenWaitRate`, 0.5): every second of
    `|tA − tB|` past five minutes (`waitLapMinimumWaitS`), lapped or not, adds half a
    second, whatever `alpha` is. A lap made a long gap cheap: a lapped 24-minute gap
    cost only about nine minutes more than a two-minute one, less than `onward` can
    swing, so a stop where one skier laps alone could beat an even stop with a weaker
    run on. Past five minutes the pair is apart, so a lapped minute then costs as much
    as being together a minute later, and a standing one two; a fully lapped gap g
    costs g − 90 s and outweighs the largest onward difference past about 16.5
    minutes. Shorter gaps are untouched. It is on the gap, not the idle part, so ranking with the
    longest possible lap stays a lower bound (below).
  - `alpha = min(2.5, 1.5 + exposure · (0.45·cold + 0.35·wind + 0.15·visibility))` with
    the hazards ramping from −8 to −25 °C, 20 to 65 km/h and 2 to 0.5 km at the arrival
    time and the stop's elevation. Exposure: indoor lodge 0.15, other lodge 0.30,
    landmark 0.60, lift base 1.00, lift top or junction 1.10. The base is 1.5: the
    pair would rather be together three minutes later than have one of them stand
    still for two, so a friend already standing at a stop does not make that stop
    the answer, and of two stops that get them together at the same time the one
    where nobody waits wins even if its shared run starts a few minutes later.
    `SolveOptions.fairnessAlpha` overrides it.
  - `onward = 360 · (1 − lap quality) + 0.5 · min(access, 720)`, or 720 when the pair
    has no shared lap from the stop. Reasoning in minutes: a full shared run straight
    from the stop costs nothing; no shared run costs twelve minutes, about the lift
    queue and ride a pair at a dead end or the bottom spends before their first turns
    together. Six of those are for the run itself, scaled by its quality. The other six
    are for `access`, the time from meeting to the first shared turns (walk, queue,
    ride), charged at half rate because it is time together but not skiing, up to
    twelve minutes of it. So a stop with a good run from it beats a dead end until it
    is twelve minutes later, and beats the same run behind an eight-minute lift by
    four. Travel time still decides anything larger.
  - The shared lap (`MeetOption.sharedContinuation`) is the best thing both can
    legally do next, judged on the weaker skier: ski from the stop, or ride one lift
    and ski from where it lets them off, through at most three connectors, within 30
    minutes and 24 edges, following a run across its segments until it reaches 1.2 km
    and 400 m of vertical. Quality, 0 to 1: `0.60 · min(1, length / 1200 m) + 0.40 ·
    min(1, drop / 400 m)`, less 0.08 per change between lift, connector and run, up to
    0.25 for access beyond eight minutes, up to 0.20 for terrain the weaker skier is
    slow on, plus up to 0.08 for a choice of shared runs.
  - Stopping can be the point. For `lodge` stops only, `s = max(lateDay, hazard)`:
    `lateDay` ramps from 0 when 45 minutes of lift time are left after the pair could
    first be together (the latest last chair among lifts both can reach) to 1 at 15
    minutes; `hazard` is the weather sum above without exposure. The lodge's `onward`
    is multiplied by `1 − s` and `lodgeCredit = 360 · s`. The swing is bounded at 18
    minutes and is zero on an ordinary mid-day solve.
- Alternates: one per lift-served zone (a stop at a lift's base or top, or reached by
  the same last lift; a 150 m grid where no lift is involved), at least 350 m from
  the pick and each other, relaxing to 200, 100 and 0 m only until two alternates
  exist. `maxOptions` is a ceiling, never a quota. Stops within 300 m horizontally
  and 40 m vertically of one another, chained stop to stop over the whole catalog,
  are one area (a base village, a mid-mountain hub). At each step of the ladder the
  places are first given, in rank order, to stops in areas not yet on the list whose
  score is at most max(5 min, 25 % of the pick's score) worse than the pick's; any
  place left is then filled in rank order under the rules here, so a crowded area is
  thinned but a far worse stop never jumps ahead of it; only the 350 m step may show
  a second stop in an area already on the list, so the looser steps never bring a
  village's lifts back. The pick is always first and options stay in score order.
  At most one alternate may
  be plainly worse than the pick (the best-ranked such, typically where one skier
  already stands); every other must leave the earlier skier waiting at most
  5 minutes longer than the pick does, or bring the two together at least a minute
  sooner. The lodge added by the rule below is exempt: stopping is its point
- A place the skier asks for by name (`SolveOptions.requested`) is the one
  exception to these rules: when both can reach it and the list leaves it out, it
  is added last, whatever its rank or its wait, with the headline
  `Tradeoff.yourPick`. One already on the list stays where it ranks; one the two
  cannot both reach is left out, and the app says so.
- A lodge stays on the list: when neither the pick nor an alternate is a `lodge` and
  an eligible one exists in an area (above) that neither the pick nor any alternate
  is in, the best-ranked such lodge is added (replacing the last alternate if the
  list is full) and carries `.lodgeAlternative`. A lodge in an area already listed
  (one on the pick's own node, say) is the same place again, so when every eligible
  lodge is in one, none is added. Options stay in score order.
- Lap while you wait (`MeetOption.lapWhileWaiting`, a `Route`): when the earlier
  skier would wait five minutes or more at a stop, a search from the stop starting at
  their arrival, under their own cost model and limits (one label per node), finds
  the loop back to the stop that returns latest while still being back at least 60 s
  before the partner's expected arrival. It must include a lift ride and at least
  400 m of run; the fastest way to each neighbouring node plus the edge back in are
  the loops considered, so it is one lap, not a tour. The route's `skierID` is the
  waiting skier, its legs' times run on from the solve instant (the first leg enters
  at their arrival) and its `eta` is when they are back. Its length (`eta` less the
  first leg's entry) is the score's `lap`, so it does change the order; it changes
  neither the meeting point nor either skier's route, and `recost` and
  `RouteProgress` do not follow it. So the app (`MeetModel`) stops offering it once a
  closure falls on any of its legs or the skier changes what routing reads.
- Shared runs and laps are searched only where they can matter. Every candidate is
  first ranked as if its onward cost were zero and its wait held the longest lap
  possible (the gap less 60 s when the gap is five minutes or more), which is a
  lower bound on its score. Candidates are then taken best first; one still holding
  a guess gets the real shared run, or then the real lap, and is put back. What
  comes out is exactly the order of the real scores, and stops too far down the
  list to be shown never pay for either search. Stops on one node share both. The
  kept lodge and a place asked for by name are scored directly, not by walking the
  queue to them.
- When no balanced stop exists the pick says so. `.longWaitUnavoidable(skier)` goes
  on the first option only, when that skier reaches it ten minutes or more before
  the other (the gap, whether or not a lap fills it): every eligible stop was ranked
  and none scored better, so the uneven meet is the best available, not a mistake.
  It does not claim that no other stop has a smaller gap. It
  comes with `.lapWhileWaitingFor` when the wait holds a lap. `.noLiftsRunning` goes
  on every option when the bundle has lifts and neither skier can board one from
  anywhere they can get to (outside operating hours, or all closed): every route is
  then downhill only and whoever is lower cannot come up.
- Output includes `Reason`s, in this order: `.noOnwardRouteFor(skier)`,
  `.noLiftsRunning`, `.longWaitUnavoidable(skier)`, `.alreadyThere(skier)` (their route is empty), `.skiOnTogether(run:)` (shared turns
  start within two minutes of meeting, lap quality at least 0.2; the name is the
  first shared run's), `.lodgeAlternative`, `.lapWhileWaitingFor(skier)`, `.closerForYou`, `.lessWaitFor(partner)`,
  `.avoidsBlackFor(skier)`, `.indoor`, `.onlyOptionUnderClosures`, `.statusUnknown`,
  `.windHoldLikelyFor(skier)`.
- Why a route was chosen, in weather words (`Route.weatherFavours`, typed; the app
  owns the words). Built only from the run environment terms of section 2, and it
  never changes a route, a cost or the order: the hard-pack half of the sun term
  (`.sunnySide`), its slush half (`.shadySide`), felt wind (`.outOfTheWind`) and
  visibility (`.clearerView`). After the routes are chosen, one more search per skier
  runs with those four terms off, one label per node and nothing past that skier's
  latest arrival (switching terms off only speeds runs up, so the plain way is never
  later); its fastest way to each stop is the plain-weather way. When it differs from
  the route, both are walked from the solve instant under the real model and, for
  each term, under the model without it, so each term's seconds on each run are known.
  A term is reported when the plain way is slower in the real weather and loses at
  least 30 s (`Scoring.weatherFavourMinimumS`, the `Tradeoff` margin) more to it than
  the route does; most seconds first, ties in declaration order. Empty with no
  conditions, on an easiest way down, on a lap and on an empty route. `solve` sets it
  on both routes of every option and `route` on its route, by the same code.
- Every solved option carries a `Tradeoff` (typed; the app owns the words). Measures per option: latest arrival, idle (`expectedWaitS`
  minus the lap's length, so a lap is skiing), combined sd, lift boardings, connector
  metres and the hardest marked run on either route (nil when any run is unrated or
  park). The pick gets the first of `.fastestTogether` (every other option ≥ 30 s
  later), `.leastWaiting` (every other ≥ 60 s more idle), `.mostPredictable` (every
  other ≥ 30 s and ≥ 15 % less certain), `.easiestTerrain`, `.fewestLifts`, else
  `.bestBalance`; `.onlyOption` when nothing else is shown. A pick carrying
  `.longWaitUnavoidable` or `.noLiftsRunning` never gets the first two. Each other
  option gets the first of `.lodgeBreak` (the kept lodge), `.easierTerrain`,
  `.quickerArrival` (30 s), `.lessSkating` (100 m and 25 % less connector),
  `.lessWaiting` (60 s), `.morePredictable`, `.fewerLifts`, else `.alternative`.

## 4. ETA, progress, reroute

- `recost` re-prices the exact remaining legs from the current progress at the given
  time. If any remaining leg is untraversable, return nil (I-09). Variance is
  recomputed for the remainder (I-10).
- `RouteProgress.project(fix:onto:in:after:)` projects GPS onto the remaining
  polylines and keeps within-edge progress monotonic. A fix within 65 m of the route
  is on it; a leg ends within 80 m of its node; joining a later leg needs three
  clearly separated matches over 4 s; the route completes within 110 m of the final
  node; `offRoute` needs deviation of 150 m or more sustained for 20 s, cleared only
  by three consecutive on-route fixes (I-11). Node identity alone never claims
  on-route.
- `RouteSwitchPolicy`: switch only between different routes to the same
  destination with a gain of at least max(30 s, 10 %), not within 30 s of arrival,
  never when the candidate's `mean + 0.5·sd` is worse, and within 2 min of the last
  switch the bar rises toward max(2 min, 20 %) and decays linearly back.
- Directed live starts: `RoutingOrigin.onEdge(edge, fraction)` charges only the
  remaining fraction (I-12), quantized to a thousandth.

## 5. Determinism and quantization

- `at` is floored to 60 s. Cloud cover rounds to 10 %, wind to 1 m/s, temperature to
  1 °C, visibility to 500 m, fresh snow to 1 cm before entering the cost model. Hourly
  samples from 2 h before to 12 h after the solve are kept and the current reading
  anchors the curve at the solve instant. Wind direction rounds to 10°; dew point and
  the temperatures aloft to 1 °C; low cloud to 10 %; snow depth and 72-hour snow to
  1 cm; the forecast height and the reference elevation (the bundle's mean node
  elevation) to 10 m; the past hours' temperatures to 1 °C. These rules live in one
  `Quantize` namespace used by both the solver and the cache key.
- No `Dictionary` iteration affects results; all collections sorted by id before use.
- Float arithmetic in `Double`; no `Float`.
- `SolveInput: Hashable` is the cache key; nothing else is.

## 6. Performance budget

- Largest launch bundle (Whistler, roughly 5–8k edges): two-skier `solve` under 400 ms
  on an iPhone 12-class CPU, under 150 ms on an M-series Mac; `route` under 60 ms;
  `recost` under 2 ms. These are targets: no benchmark test is written (`AGENTS.md`).
- Memory: adjacency built once per bundle load and shared (`ResortBundle` holds it).

## 7. Tests

- The reference scenarios in `RendezvousSolverTests`, `SolverSafetyTests`,
  `CostModelTests`, `TechnicalTerrainRoutingTests` and `TradeoffTests`: Swift Testing
  code against this API on small synthetic bundles, with their expected rankings and
  safety outcomes, and `WeatherFavourTests`
  (`aRouteTheSunFavouredSaysSo`: a longer sunny run beating a shorter shaded one on
  a cold noon reports `.sunnySide`, and reports nothing with no weather). They cover live lift waits
  (`liveLiftWaitWinsOverCanonicalWeekdayBaselines`, the cache-key case in
  `cachedSolveChangesWhenLiftStatusChanges`), the personal pitch limit (usable pitch
  data, no unrequested limit, an invalid limit, the known-pitch alternative), what the
  skier rides (category advantages, continuity at 3 and 8 cm, forecast snow FIFO,
  equipment never bypasses difficulty or a closure) and the option labels. Avoid
  choices are in `ProfileLimitsTests`. `bothSkiersReachingTheBaseAlwaysGetAMeetingPoint`
  pins the owner's rule: two skiers who can both get down to the same bottom within
  their limits always get an option there, with a higher stop only one can reach and
  with the lift at that base shut. It holds for a common bottom: on a resort with
  several bases each skier can get down and still share no stop. The pipeline proposes
  a `lift_base` at every chair, gondola, cable car and T-bar bottom; carpets and rope tows
  are left out on purpose.
- Not tested, because the solver has no such input or API: per-edge learned history
  and condition cohorts, measured variance, mogul, glade and obstacle flags
  (`ungroomed` stands in; the bundle's `moguls` flag feeds only the run card), per-blocker diagnostics (the solver reports
  `abilityBlocksAll`), a comfort slider, and route-explanation or arrival copy, which
  is the app's wording from typed reasons. Which lifts download belongs to the
  bundle builder; `aLiftIsRiddenDownOnlyWhenTheBundleMarksItTwoWay` pins that the
  solver rides a lift down only when the bundle says it may.
- `ProfileLimitsTests` covers the limits and equipment rules of section 2: each
  gate, the part-way exemption, and the direction and bound of each pace term.
- `RankingRuleTests` covers the ranking rules of section 3 (everyone can leave,
  the shared run, idle time and the lap, the lodge, alternates thinned by area);
  three cases in
  `RendezvousSolverTests` pin the wait weight (1.5) by number.
- Two of those tests run on the real Whistler bundle (the fixture in
  `packages/MountainCore/Tests/Fixtures`), from the demo's starting positions and
  from pairs both high, both low and either side of the valley: mid-day the pick has
  both skiers travelling and neither waiting long, and with no lifts running the
  pick says why it is uneven.
