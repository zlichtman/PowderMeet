# 00 Product

## 1. Promise

Two skiers, one mountain, one question: where should we meet? PowderMeet picks the
fairest places for two friends to meet on a resort's real lift-and-trail graph, with
each skier's own route and ability limits, shows honest arrival ranges, and then guides
both of them there while they see each other live. If a lift or run closes on the way,
both phones reroute or the meet ends with a reason. Afterwards, the runs are recorded
and the pace predictions get better.

Everything in this pack serves that paragraph. A feature that does not serve it is out
of scope.

## 2. Who it is for

- **Pairs of friends who split up on the mountain**: different ability, different
  lifts, same lunch. Primary.
- **Groups of three or more** are out of scope (see non-goals). The domain
  model keeps `participants` as a list so this can be added without a schema change.

## 3. Context of use

- One hand, gloves, glare, cold, intermittent connectivity, battery anxiety.
- Decisions happen at the top of a lift or in a lift line, in under 20 seconds.
- The phone is in a pocket most of the time. Audio and haptic cues matter more than
  pixels during navigation.

UX rules that follow (MUST):
- Every primary action is reachable with one thumb from the bottom third of the screen.
- Tap targets of at least 56 pt in the meet flow and during navigation.
- High-contrast "glare" theme available in one tap; the existing theme tokens are kept.
- Navigation keeps working with the screen locked: audio prompts for the next maneuver
  and for meet events (accepted, partner arrived, reroute).
- Anything the app cannot know is labeled, never hidden: "lift status unavailable",
  "last seen 4 min ago", "ETA ± 6 min".

## 4. User journeys (the behavior to build and test)

### J1 First run
Install, sign in with Apple, create a profile (name, ability, optional skis), allow
location (when in use, then always for navigation), allow notifications, add friends by
contact hash or by name, pick a resort from the list of published resorts. Exit: the user
sees the mountain with their position on it.

### J2 Propose a meet
On the Meet tab, pick a friend who is at the same resort (presence within the TTL).
The app solves locally and shows three to five ranked options, each with: where, my
arrival range, their arrival range, who waits and how long, hardest terrain each of us
touches, lift count, and a one-line reason. Pick one and send. Exit: the partner's
phone shows the proposal within 5 s and the proposer sees "waiting for Alex".

### J3 Respond
The partner sees the proposal with their own route computed on their own phone: ETA,
hardest terrain, lifts. Accept or decline (with a reason if the app cannot route them
there). Exit: both phones are in navigation to the same rendezvous within 10 s of
accept.

### J4 Navigate
Turn-by-turn cards and audio; partner position and ETA; live status badge. If a lift
or run on my remaining route closes, my phone reroutes if a route exists, otherwise the
meet ends with "status blocks route" and both phones say so. Arrival is detected within
30 m of the rendezvous node and confirmed with one tap. Exit: both phones show
"met" with the actual times.

### J5 Interruptions
Either phone killed or offline: on relaunch or reconnect, the meet resumes from the
server; the partner sees "last seen" aging. Proposals time out after 30 min; active
meets expire at the later ETA plus 45 min with no progress updates.

### J6 Record and learn
Ski the day with recording on. Descents are detected and uploaded once. Import past
files from Slopes, GPX, TCX or FIT. Each descent appears once in history with the
trail it matched. After enough descents, "your ETA" explains itself: "you ski blues 12 %
faster than the default".

### J7 Unsupported resort
Pick a resort with `status_mode = scheduled_only`: routing works on operating hours and
every route card carries the "lift status unavailable" badge. An unpublished
resort is listed marked "no map yet" and cannot be selected (A1, DECISION 3).

## 5. Acceptance criteria

| # | Criterion | Verified by |
|---|---|---|
| A1 | Only published resorts can be selected; each passed `05-PIPELINE.md` validation and declares `status_mode`. The picker also lists the rest of the catalog, marked as having no map yet. | Pipeline gate; pgTAP on the `published_resorts` and `resort_catalog` views. |
| A2 | Propose to active within 10 s on two phones; partner position within 5 s; a stranger, a blocked user or an ex-friend receives nothing. | Realtime policy tests with self/friend/stranger/blocked. |
| A3 | Closure during an active meet reroutes both or ends with `status_blocks_route` within one status refresh; no ETA through a closed edge. | Solver tests (`recost` returns nil). |
| A4 | Offline: last bundle renders, solve runs labeled "status unknown", meet resumes on reconnect. | AppCore tests with `FakeBackend`; device checklist. |
| A5 | Kill either app: meet recovers via `meet_current()`; stale meets expire server-side. | pgTAP expiry test (`060_expiry`). |
| A6 | One row per physical descent, idempotent re-import, visible calibration effect. | DescentKit corpus goldens; `descent_upsert` idempotency test. |
| A7 | Adding a resort is one pipeline run producing a report; human time measured. | Determinism test; `published_resorts.review_minutes`. |
| A8 | Each push to `main` runs the package, backend and pipeline tests for the paths it touches. | CI config. |

## 5a. Release requirements

Shipping on the App Store adds requirements that are not features: in-app account
deletion, purpose strings and privacy labels, a reviewer path through a two-phone
meet, and the notification set. They are specified in `11-SETUP-RELEASE.md` and must be
met before an App Store release.

## 6. Non-goals

- Groups larger than two. iPad. Apple Watch. Android.
- Live Overpass or on-device graph building. Resorts without a published bundle.
- Per-ski (equipment) calibration cohorts. Equipment changes pace through the fixed
  rules in `06-SOLVER.md` section 2 only; learned pace is not split by equipment.
- Synthetic trees. The one cinematic camera flight (the fly-in) is a setting, off by
  default.
- Social feed, chat, photos. Push is used for proposals, responses and meet events only.

## 7. Decisions (DECISION defaults the specs assume)

| # | Decision | Default assumed | Alternative |
|---|---|---|---|
| 1 | Unknown lift status | Degrade with a label: route on operating hours, badge every route card, never route through a *known* closure. | Refuse to route without fresh live status (current behavior). |
| 2 | Launch resorts | Every resort in the catalog. The pipeline runs unattended over all of them and publishes each one that passes automated validation; the rest are listed in a report with the reason. No per-resort hand review is required to publish. Whistler Blackcomb is the first proof. | A small hand-reviewed set. |
| 3 | Unpublished resorts | Listed in the picker marked "no map yet" and not selectable. A "request a resort" row that logs demand is open in `docs/ROADMAP.md`. | Hidden from the picker. |
| 4 | Calibration | In scope: the parsers, run history and pace learning: per-run offsets, recent runs weighted above old ones so a skier who improves is not held to old pace, and the per-skier difficulty ceiling as a hard routing gate. | Ship without any learning. |
| 5 | Pipeline language | Python (keeps reconciliation logic; shapely, pyproj, rasterio, osmium). Status and conditions workers stay TypeScript edge functions. | TypeScript everywhere. |
| 6 | Repository | One monorepo: app, packages, backend and pipeline together. | Separate repositories. |
| 7 | Position sharing scope | Fan out to accepted friends at the same resort plus any friend with a non-terminal meet with the sender. | All accepted friends regardless of resort. |
| 8 | Minimum iOS | Current major minus one; Swift 6 language mode. | Older. |
| 9 | Hosted Supabase projects | One project, `PowderMeet`, used for development and TestFlight, then reset for production at launch; CI uses local Supabase. | A second project for production. |
| 10 | Thin map sources | After the first full pipeline run shows which resorts fail and why, add a source that reads the resort's published trail map with a vision model. It supplies names, difficulty, lift names and which run connects to which lift; geometry still comes from OSM, terrain and imagery, and anything placed this way is marked approximate in the bundle. Not built until the failure list exists. | Leave failing resorts unpublished. |
| 11 | Map data date | Each bundle carries its source extract date. Settings shows "Mountain map last updated <date>" per resort; lift and run status carries its own observed time. | Not shown. |
| 12 | Live status sources | Epic terrain feed and MtnPowder (Ikon); Liftie as a lift-only source for other resorts (the worker can read it; no resort is assigned to it yet, see `05-PIPELINE.md`). These are the public endpoints behind the resorts' own pages, not licensed APIs, so each adapter fails closed and a resort without one is `scheduled_only`. | Official feeds only. |
