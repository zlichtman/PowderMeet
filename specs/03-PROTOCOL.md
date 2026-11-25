# 03 Meet protocol

Server-authoritative. The only geographic fact two phones share is `rendezvous_id`.
Each phone computes and owns its own route. All times are server times.

## 1. States and transitions

```
proposed ─accept─────────▶ active ─end(arrived)──────▶ completed
   │                         │
   ├─decline──▶ declined     ├─end(user_cancelled)───▶ cancelled
   ├─cancel───▶ cancelled    ├─sweep(timeout)────────▶ expired
   ├─sweep────▶ expired      ├─end(status_blocks_route | partner_left) ▶ invalidated
   └─supersede▶ invalidated  └─server(rendezvous_removed) ─────────────▶ invalidated
```

| From | To | Who | RPC | Precondition |
|---|---|---|---|---|
| (none) | proposed | proposer | `meet_propose` | accepted friendship, neither blocked, resort published, rendezvous exists in the active bundle, neither party has a non-terminal meet |
| proposed | active | invitee | `meet_respond(accept=true)` | status is `proposed`, now < `expires_at` |
| proposed | declined | invitee | `meet_respond(accept=false, reason)` | status is `proposed` |
| proposed | cancelled | proposer | `meet_end(user_cancelled)` | status is `proposed` |
| proposed | expired | server sweep | | now ≥ `expires_at` (30 min after creation) |
| proposed | invalidated(superseded) | proposer | `meet_propose(supersedes=…)` | same pair; atomically ends the old one |
| active | completed | either | `meet_end(arrived)` | status is `active` |
| active | completed | either | `meet_progress_update` | status is `active` and, after this fix, both participants' stored progress state is `arrived` (0025), the other participant's with a `fix_at` at most 120 s old (0028) |
| active | cancelled | either | `meet_end(user_cancelled)` | status is `active` |
| active | invalidated | either | `meet_end(status_blocks_route \| partner_left)` | status is `active` |
| active | expired | server sweep | | no `meet_progress` from either party for 45 min after max(eta) |
| any non-terminal | invalidated(rendezvous_removed) | server | publish trigger | the new active bundle lacks the rendezvous |
| any non-terminal | invalidated(partner_left) | either | `friend_remove`, `block_user`, `account_delete` | the two are no longer friends, or one account is gone |

Terminal states never change. `meet_end` on a terminal meet returns the row unchanged
(idempotent); `meet_respond` on a non-`proposed` meet raises `meet_not_proposed`. On a
`proposed` meet only the proposer may `meet_end(user_cancelled)`; for the invitee, and
for any other reason, it raises `invalid_state` (the invitee declines instead).

## 2. RPC signatures

All RPCs are `security definer`, `authenticated` only, and read the caller from
`auth.uid()`. They return the full `meets` row as JSON unless noted. Errors are raised
with `errcode = 'P0001'` and a message code from the list in section 5.

```sql
meet_propose(
  p_meet_id uuid, p_invitee uuid, p_resort_id text, p_rendezvous_id text,
  p_bundle_id text, p_proposer_eta_s int, p_proposer_eta_sd_s int,
  p_supersedes uuid default null) returns meets

meet_respond(
  p_meet_id uuid, p_accept boolean,
  p_invitee_eta_s int default null, p_invitee_eta_sd_s int default null,
  p_decline_reason text default null) returns meets        -- declined_by_user | declined_cannot_route

meet_progress_update(
  p_meet_id uuid, p_eta_s int, p_eta_sd_s int, p_remaining_m int,
  p_state text, p_fix_at timestamptz) returns void          -- navigating | rerouting | arrived | lost

meet_end(p_meet_id uuid, p_reason text) returns meets      -- arrived | user_cancelled | status_blocks_route | partner_left

meet_current() returns meets                                -- the caller's non-terminal meet or null
meet_history(p_limit int default 50) returns setof meets
```

Idempotency: `meet_propose` with an existing `p_meet_id` by the same proposer returns
the existing row; by a different user raises `meet_id_taken`. A client that gets back
a row for another meeting point than the one it sent (an earlier send that seemed to
fail had landed, and the user then picked another option) supersedes that row at once
with a new `p_meet_id`. `meet_end` is idempotent
on terminal rows. `meet_progress_update` ignores `p_fix_at` older than the stored one
(an equal one is applied, so a state change on the same fix reaches the partner); it
stores at most one minute past server time, and a stored time further ahead than that
never blocks a later fix, so a phone clock running ahead has no effect (D14).

Arriving together (0025): when a `meet_progress_update` leaves both participants'
stored state at `arrived`, the other participant's with a stored `fix_at` no more than
120 s before server time (0028), it completes the meet in the same call, exactly as
`meet_end(arrived)` does (status `completed`, end reason `arrived`, `meet.updated` to
both, the caller in `ended_by`), and queues a `meet.ended` push to both with end reason
`arrived` ("you met up"). The call locks the meet row, so two arrivals at the same moment
run one after the other, and only an `active` meet completes, so it happens once. A later
`meet_progress_update` on the completed meet raises `invalid_state`; `meet_end(arrived)`
returns the same row. The freshness bound (0028) keeps an old arrival from completing
a meet: a skier who arrived, lost service and left keeps `arrived` stored, and the
friend arriving later is not "both there". A phone still at the meeting point keeps its
row inside the bound, since it repeats its fix every 45 s and a meet's location mode
never pauses (`07-CLIENT.md`). A phone that sends nothing for longer than the bound
(no service) completes the meet on its next progress, or by `meet_end(arrived)`.

Limits: `meet_propose` is rate-limited to 20 new proposals an hour per proposer
(`rate_limited`; an idempotent retry is not counted). The estimates given to
`meet_propose` and `meet_respond` (`p_*_eta_s`, `p_*_eta_sd_s`), which the expiry sweep
waits on, are 0–86400 s, else `invalid`.

Progress after the end (0026): once a meet is terminal, each participant reads only their
own `meet_progress` row; the partner's last ETA, distance and state are gone from view,
whatever ended it, a block included, so a block cannot be told from any other ending.

Who ended it: a terminal row's `ended_by` is the participant whose request ended the
meet (`meet_end`, a decline, a supersede, `friend_remove`, `block_user`,
`account_delete`), or null when the server did (sweep, bundle publish). The client
words an ending from the viewer's side with it ("You left" against "<name> left").

## 3. Realtime events (private topic `user:{uuid}`)

Envelope: `{ "v": 1, "type": "<type>", "at": "<server time>", "data": { ... } }`.

| type | data | sent to |
|---|---|---|
| `meet.proposed` | full meet row | invitee |
| `meet.updated` | full meet row | both participants, on every status change |
| `meet.progress` | `{meet_id, user_id, eta_s, eta_sd_s, remaining_m, state, fix_at}` | the other participant |
| `presence` | `{user_id, resort_id, lon, lat, accuracy_m, speed_ms, heading_deg, captured_at}` | per DECISION 7 |
| `friend.requested` / `friend.accepted` / `friend.removed` | `{friendship_id, user_id, display_name, avatar_url}` | counterpart |
| `resort.status` | status row (section 3 of 02-DOMAIN) | topic `resort:{resort_id}` |

Events are emitted by database triggers through `realtime.send(payload, event, topic,
private => true)`. Clients MUST treat events as hints and re-read through RPC when a
sequence looks inconsistent (`meet_current()` is cheap). Private channel replay
(`since`) MAY be used after reconnect to catch up on the last minutes; `presence`
messages are purged once past the 15 minute presence TTL (`presence_cleanup`, 0023).
`account_delete` removes every stored message that mentions the deleted user and
everything on their own topic, keeping only the `meet.updated` and `friend.removed`
events it sends to partners and friends, with no name or photo (0025).

A block is never visible to the person blocked (0025): a request to someone who blocked
you sends them no `friend.requested`, and withdrawing it sends no `friend.removed`.

## 4. Client sequences

**Accounts (Supabase Auth, not RPCs)**
- Sign in with Apple: native identity token → `signInWithIdToken`. Apple's name, given
  only on the first authorization, is kept on the phone and offered in onboarding; it is
  not written to the profile until the user saves it.
- Email sign-up: `signUp(email, password, redirect_to = powdermeet://auth-callback)`. With
  "Confirm email" on, no session is returned; the app shows "check your email" with
  resend (`resend(type: signup)`). A sign-up for an address that already has an account
  returns a user with no identities and is reported as "email in use". Signing in before
  confirming fails with `email_not_confirmed`, said plainly, with resend offered.
- Forgot password: `recover(redirect_to = powdermeet://auth-callback?type=recovery)`.
- Links: the email links open `powdermeet://auth-callback?…&code=…` (PKCE; the verifier is
  on the phone that asked). The app exchanges the code for a session; `type=recovery`
  then shows the set-new-password step over every screen (`auth.update(password)`). A
  link for another account replaces the signed-in one without a server sign-out. An
  expired, used or foreign link says so.
- Onboarding's name step checks the name as typed with `display_name_available`, and
  its Continue saves the name alone with `profile_update` before the next step shows,
  so a friend request sent from the contacts step carries the chosen name, never the
  placeholder; a refusal there keeps the name step. Onboarding cannot finish until the
  final `profile_update` (the name again with the rest) is accepted; `name_taken` or
  `name_not_allowed` on it returns to the name step.

**Profile photo (Storage, then `profile_update`)**
- The phone crops a square, redraws it at 512 × 512 px into a new bitmap and encodes
  a JPEG with no metadata (no location, camera or dates), then uploads it to
  `avatars/<lower-case user id>/<new uuid>.jpg` (`image/jpeg`; a new name every time,
  so a path names its bytes). `profile_update({avatar_url: path})` makes it the photo;
  then the user's other objects are removed. If the save fails the upload is removed.
- Remove: `profile_update({avatar_url: null})`, then the objects. Before
  `account_delete` the client removes its objects too.
- Display: the public URL of `avatar_url`, cached on the phone by path.

**Friends by name (migration 0019)**
- Search: the Friends sheet's search field, debounced (350 ms), → `search_users(query)`
  (60/min) → rows with the relation (friend, request sent, request received, none).
  Add is `friend_request(user)`, which accepts a request they already sent.
- The add codes of 0016 (`friend_code_*`, `friend_request_by_code`) are no longer
  called by the app (search by name replaces codes and QR); the database functions
  stay until a later migration drops them.

**Report (migration 0017)**
- `report_user(user, reason, note?, context)` from the friend card, a request or a
  contact match; the app then offers `block_user(user)`. Nothing is read back.

**Propose (proposer phone)**
1. `MeetSession` builds `SolveInput` from the active bundle, status, conditions, own
   profile and pace, the partner's `pace_models_friend_read` row and presence fix.
2. `MeetSolver.solve` → ranked options; user picks one.
3. `meet_propose(...)`. On success, state `proposed(outgoing)`; show "waiting".
4. On `meet.updated` with `active`: compute own route with `MeetSolver.route`, enter
   navigation. With `declined`: show reason.

**Respond (invitee phone)**
1. On `meet.proposed` (or `meet_current()` at launch): load the bundle named by the
   meet's `resort_id` (active bundle; `bundle_id` is advisory). If `rendezvous_id` is
   missing from the cached bundle, fetch the active bundle; if still missing, the
   server will already have invalidated the meet.
2. `MeetSolver.route(for: me, to: rendezvous)`; show ETA and terrain.
3. If routing fails under the current `StatusPolicy`: `meet_respond(false,
   declined_cannot_route)`. Otherwise the user accepts or declines.
4. On accept success: enter navigation immediately. Without a routing-grade fix at the
   tap (GPS lost since the route was worked out), `meet_respond(true)` is sent with
   null estimates, so the proposer is not shown a time from where the skier was, and
   navigation starts from the next fix rather than from the invitation's route.

**Navigate (both)**
- `meet_progress_update` is considered every 10 s and on a change of state
  (`navigating`, `rerouting`, `arrived`, `lost`), through the outbox, which keeps only
  the latest, and goes out only when there is a fix newer than the last one sent or a
  different state. While location updates run a still phone repeats its position about every 45 s
  (`10-INVARIANTS.md`); with no new fix it sends nothing, and the server ignores an older
  `fix_at`, so the expiry sweep's 45 minutes run from the last new fix.
- On a status change that makes a remaining edge untraversable: `MeetSolver.recost`
  returns nil → reroute via `MeetSolver.route`; if no route, `meet_end(status_blocks_route)`.
- Arrival: within 30 m of the rendezvous node for 10 s → `state = arrived`. Nobody
  confirms anything. A skier who has arrived and is then more than 100 m from the node
  on a routing-grade fix is no longer `arrived` (`navigating` again, routed back), so a
  lap or a walk away never counts as being there. When
  both phones have reported `arrived` the server completes the meet without a tap
  (section 2). A phone counts the partner's `arrived` only while its `fix_at` is at most
  120 s old (`MeetSession.arrivalFreshS`, the server's bound), so it never completes the
  meet on an arrival left behind.

**Recover (either)**
- On launch, foreground or reconnect: `meet_current()`. Non-null → rehydrate
  `MeetSession` from the row, recompute own route. Null while local state says active
  → the meet ended; show the server's `end_reason`. If the meet row is gone too (the
  partner deleted their account: `account_delete` ends the meet with `partner_left`,
  sends `meet.updated` and the "Meet ended: <name> left" push, then the row cascades
  away with their profile), the phone says the partner left.
- While a meet is non-terminal the client also re-reads its row every 60 s, and when
  partner progress arrives for a meet it does not hold as active, so a lost
  `meet.updated` cannot strand it. Rows carry no version: since statuses only move
  forward (section 1), a `proposed` row reaching a phone that holds the meet as
  active is stale and ignored.

**Leave (either)**
- Closing or switching the resort, or signing out, ends the meet under way first:
  the proposer withdraws (`meet_end(user_cancelled)`), the invitee declines
  (`meet_respond(false, declined_by_user)`), an active meet ends with
  `meet_end(partner_left)`. Best effort; if it fails the sweep still ends the meet.

## 5. Error codes

`not_friends`, `blocked`, `resort_not_published`, `rendezvous_unknown`,
`meet_busy_proposer`, `meet_busy_invitee`, `meet_not_proposed`, `meet_expired`,
`meet_id_taken`, `not_participant`, `invalid_reason`, `invalid_state`, plus the shared
`invalid` (a missing or negative argument) and `rate_limited` (`meet_propose`).
Inviting oneself is `not_friends`. `blocked` stays in the list for builds that
still handle it, but since 0025 nothing raises it: a block is hidden, and a meet with
someone you blocked or who blocked you is `not_friends`, as with any non-friend. Profile writes add `name_taken` and
`name_not_allowed`, and every RPC may raise `not_authenticated` and `not_found`
(`04-SCHEMA.md` section 6).

## 6. Divergence scenarios

| # | Scenario | Expected |
|---|---|---|
| D1 | Both propose to each other within 1 s | second `meet_propose` fails `meet_busy_*`; one meet exists |
| D2 | Invitee accepts after proposer cancelled | `meet_respond` fails `meet_not_proposed`; invitee sees `cancelled` via `meet_current` |
| D3 | Invitee cannot route (ability) | `declined_cannot_route`; proposer sees the reason |
| D4 | Proposer app killed after propose; invitee accepts | proposer relaunch → `meet_current()` is `active` → navigation |
| D5 | Invitee offline for 20 min during active | invitee progress ages; proposer sees "last seen"; sweep does not expire before 45 min after max(eta) |
| D6 | Lift on invitee's remaining route closes | invitee reroutes or `status_blocks_route`; proposer gets `meet.updated` |
| D7 | New bundle published without the rendezvous | server sets `invalidated(rendezvous_removed)`; both notified. A proposal racing the publish is ordered by `meet_propose` reading the active bundle `for share` (0026): it either sees the new catalog (`rendezvous_unknown`) or commits first and is invalidated by the publish |
| D8 | Proposer supersedes with a new rendezvous | old `invalidated(superseded)`, new `proposed`, atomically; invitee sees one proposal |
| D9 | Stranger calls `meet_propose` | `not_friends`; no push, no event |
| D10 | Blocked user calls `meet_propose` | `not_friends`, as for a stranger; no push, no event |
| D11 | Participant tries to update the other's progress | `not_participant` |
| D12 | Both call `meet_end(arrived)` | first completes, second returns the same row |
| D12b | Both report `arrived` progress at the same moment | the meet completes once; one `meet.ended` push each; the later progress call raises `invalid_state` |
| D13 | Proposal unanswered 30 min | sweep → `expired`; both notified |
| D14 | Clock skew of +2 h on the invitee device | no effect: all expiries server-side |
