# 10 Invariants

Each invariant is a test name. The package column says where the test lives. These
are the skiing and protocol rules; lifecycle patches are deliberately absent because
the architecture removes their causes.

| ID | Invariant | Test lives in |
|---|---|---|
| I-01 | A meet may terminate only at a rendezvous in the bundle's catalog. | MeetSolver, pgTAP (`meet_propose` rejects unknown) |
| I-02 | Fairness chooses a stop, never a detour: per-skier Pareto labels (mean, variance, current-action uncertainty, action count), fastest mean-time label retained, approaches chosen jointly. | MeetSolver |
| I-03 | Ranking: a stop is eligible only if each skier can leave it within their own limits (lodges and landmarks with nothing leading on excepted; all stops kept and labelled if none pass). Order: `max(tA,tB) + α·idle + 0.5·lap + 0.5·sqrt(varA+varB) + simplicity + onward − lodgeCredit + confidence + quality`, where `lap` is the lap the earlier skier fits into the gap and `idle = |tA−tB| − lap`, with α ≥ 1.5 and `onward` ≤ 12 min, then expected arrival, idle, spread, uncertainty, simplicity, onward, catalog confidence, stop quality, id. A first option whose earlier skier is ten minutes or more ahead says so (`.longWaitUnavoidable`), and options say when no lift is running (`.noLiftsRunning`). | MeetSolver |
| I-04 | Time-dependent FIFO: completion time is monotonic in departure time for queues (modelled, and a live wait as it hands back to the model), forecast snow and wind; wind scales ride time only. | MeetSolver (property) |
| I-05 | Conditions interpolate across normal gaps; at an edge hold 1 h, fade 30 min, then current. | MountainCore |
| I-06 | Mountain time and sun use the bundle's time zone and longitude; never the device zone. | MountainCore, MeetSolver |
| I-07 | No unsafe fallbacks: known closures, ability limits, exact origins are respected or a typed failure is returned. The one exception is the labelled easiest way down for a skier with no way down within their level (06-SOLVER section 1), which still respects closures, choices and hours. Unknown status is labeled, never silently treated as open. A measured pitch that is not an angle falls back to the rating's usual steepest pitch, and a pitch limit that is not an angle blocks every run rather than switching the gate off. A live wait is used only from fresh status; unknown is the modelled queue. | MeetSolver |
| I-08 | A lift reached at or after its close is untraversable. | MeetSolver |
| I-09 | Active ETA fails closed: any untraversable remaining leg yields nil and a reroute. | MeetSolver |
| I-10 | Variance carries through planning, acceptance and reroute; never dropped at a handoff. | MeetSolver, AppCore |
| I-11 | On-route is decided by geometry projection with monotonic within-edge progress, never by node identity alone. | MeetSolver |
| I-12 | Directed live starts charge and draw only the unskied remainder. | MeetSolver, MapScene |
| I-13 | Determinism: identical `SolveInput` yields identical output regardless of input ordering or device; quantization rules live in one place. | MeetSolver (property) |
| I-14 | Only a routing-grade fix (< 75 s old, plausible skew, accuracy ≤ 50 m) may start or change a route, publish presence or record a run; older fixes may display with age. Auto-selecting a resort on arrival uses the looser `ResortArrival` rule (one fix within 200 m and 2 minutes old: `07-CLIENT.md` section 4). | AppCore |
| I-15 | Closure truth: a group is open, partial or closed across all members; closed segments draw where they are; one open segment never makes a partially closed trail look open; map and solver read the same status value. | MapScene |
| I-16 | Connectivity comes from shared source vertices, explicit `piste:type=connection` ways, and only the joins `05-PIPELINE.md` (build, Gaps) lists: `snap`, `auto_link`, `line_join`, `orphan_link`, and `link` from a decisions file, each within its tolerance and each recorded as a flag in the report. Coincidence alone never joins ways, and two ways that only pass close together are never joined. | pipeline |
| I-17 | Bundle identity is the SHA-256 of bytes; the client verifies it before decoding and never derives identity from a decoded model. | MountainCore |
| I-18 | Status never changes topology; it is a solve input with an expiry. | MeetSolver, MapScene |
| I-19 | Sender-stamped capture time; receivers drop non-monotonic positions and progress. | pgTAP, AppCore |
| I-20 | A physical descent is one row with raw track and provenance; matching is a derivation keyed by bundle and matcher version. | DescentKit, pgTAP |
| I-21 | Social and meet transitions are typed and server-enforced; clients cannot write shared tables directly. | pgTAP |
| I-22 | Privacy is enforced in the database: a stranger, blocked user or ex-friend receives no presence, progress or profile detail. | pgTAP |
| I-23 | A user has at most one non-terminal meet. Replacing a sent proposal (`meet_propose(supersedes:)`) ends the old row and inserts the new one atomically; the invitee's client shows the replacement in place of the old one. | pgTAP, AppCore |
| I-24 | All expiries are server time. | pgTAP (`060_expiry` for D5, D13 and D14) |
| I-25 | Every user-initiated failure surfaces as a `PowderMeetError` with a recovery; no `try?` on those paths (lint rule). | AppCore (SwiftLint custom rule) |

## Why "live" means 75 seconds (I-14)

A chairlift's cell hand-off routinely drops one broadcast, and a 60-second window made
friends' dots blink to stale in the middle of a ride; 75 s rides out one dropped update. The same 75 s is the routing-grade fix age (I-14,
`FixQuality.maximumAgeS`) and the live window of a friend's position
(`FriendSignal.liveWindowS` in MapScene). After it a position is stale, shown with
its age, up to 5 minutes; from then it is cold, drawn dimmer, and from 10 minutes it
reads "Lost signal". At 15 minutes (`FriendSignal.forgetAfterS`, the presence TTL, after
which the server no longer serves the row) it leaves the map and `ResortSession.friends`:
a phone still at the resort publishes within a minute even standing still, so only a friend who closed
the resort, signed out or quit ages that far, and nothing else says they have gone.

A phone standing inside its distance filter gets no update from CoreLocation, so a
skier waiting in a lift line would lose routing grade after 75 s and could not
propose, accept or be routed. While updates are running, the location driver
therefore repeats the last position every 45 s, stamped with the time it is known
for, at speed 0 and with the distance filter added to its accuracy: silence from
CoreLocation means the phone has not moved further than the filter. Nothing is
repeated while updates are paused or off.
