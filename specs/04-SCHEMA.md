# 04 Backend schema and authorization

Postgres on Supabase. Migrations are the only schema source; `config.toml`, cron jobs
and realtime policies are in migrations too. Every policy and RPC has pgTAP tests as
self, friend, stranger and blocked.

## 1. Conventions

- Tables are `public.*`, snake_case, `id uuid default gen_random_uuid()` unless noted,
  `created_at timestamptz default now()`.
- RLS enabled on every table by the `rls_auto_enable` event trigger.
- Clients get `select` grants only where a policy exists; `insert/update/delete` on
  shared tables are revoked from `authenticated` and `anon`. Writes go through RPCs.
- RPCs are `security definer`, `set search_path = public`, `revoke execute from
  public, anon`, `grant execute to authenticated` (or `service_role` only). They use
  `(select auth.uid())` once into a variable.
- Friend check helper: `is_accepted_friend(a uuid, b uuid) returns boolean` (accepted
  row in either direction and no `user_blocks` row in either direction).

## 2. Tables

```sql
profiles (id uuid pk references auth.users,
          display_name text not null,   -- unique ignoring case (index on lower(display_name));
                                        -- written only normalised and 2..24 code points (section 6)
          avatar_url text,     -- object path in the `avatars` bucket (`<user id>/<file>`), not a URL
          ability text not null check (ability in ('beginner','intermediate','advanced','expert')),
          max_difficulty text not null, baseline_speeds jsonb not null default '{}',
          equipment jsonb,     -- {discipline: ski|snowboard, type: all_mountain|carving|freeride|park,
                               --  length_cm?: 60..220, waist_mm?: 55..140 (ski only),
                               --  ski?: catalog key like atomic-bent-110 (ski only, shape checked, not the key),
                               --  skin?: house|solid|stripes|split|bands|fade|tip|tricolor}; no other keys.
                               --  The client writes only discipline `ski` and reads a stored
                               --  `snowboard` as `ski` with length_cm dropped (02-DOMAIN.md 5.1).
          avoid text[] not null default '{}',   -- subset of ungroomed, flats, park, surface_lifts
          max_pitch_deg smallint,               -- 10..45, null = no limit
          height_cm smallint, weight_kg smallint,   -- 100..230, 25..200; private, see section 3
          email_hash text unique,              -- phone_hash was dropped in 0025
          current_resort_id text references resorts(id), created_at, updated_at,
          search_name text generated always as (lower(display_name_normalize(display_name))) stored)
          -- 0026: what search_users matches, with GIN trigram index profiles_search_name_trgm
          -- (pg_trgm in schema extensions); not granted to clients

display_name_blocked_words (word text pk, match text check in ('word','substring'))
          -- server-only block list for display names; RLS on, no client grants

user_blocks (blocker_id uuid, blocked_id uuid, created_at, primary key (blocker_id, blocked_id))

friendships (id uuid pk, requester_id uuid not null, addressee_id uuid not null,
             status text not null check (status in ('pending','accepted')),
             created_at, responded_at,
             check (requester_id <> addressee_id))
  unique index friendships_pair on (least(requester_id, addressee_id), greatest(requester_id, addressee_id))

resorts (id text pk, name text not null, timezone text not null, bbox geometry(Polygon,4326) or jsonb,
         center jsonb, camera jsonb, pass_products text[],
         region text, country text,     -- where it is, for the picker: state or province code in the USA and Canada
         aliases text[] not null default '{}',  -- other names the picker searches by ("St. Anton"); 0020
         status_provider text,          -- epic | mtnpowder | liftie | null; null means scheduled_only
         status_mode text not null,     -- live requires a status_provider
         published boolean not null default false, review_minutes int, created_at, updated_at)

resort_bundles (bundle_id text pk check (bundle_id ~ '^[0-9a-f]{64}$'), resort_id text not null references resorts,
                schema_version int not null, manifest_version int not null, extract_id text not null,
                built_at timestamptz not null, pipeline_version text not null, size_bytes int not null,
                integrity jsonb not null, report_url text, created_at,
                status_meta jsonb)  -- 0026: the status worker's reading of the bundle, see section 7
  -- manifest_version: order of publication per resort, set by `pm-pipeline publish`; it can
  -- differ from the bundle's source.manifest_version (05-PIPELINE.md, publish)

resort_active_bundle (resort_id text pk references resorts, bundle_id text not null references resort_bundles,
                      rendezvous_ids text[] not null,   -- the active bundle's rendezvous catalog; meet_propose checks it
                      published_at timestamptz not null, published_by text not null)
resort_bundle_publications (id bigserial pk, resort_id, bundle_id, published_at, published_by, previous_bundle_id,
                            rendezvous_ids text[], report jsonb)

resort_status (id bigserial pk, resort_id text references resorts, observed_at, expires_at, source text,
               groups jsonb not null, groomed text[] not null default '{}',
               wait_minutes jsonb not null default '{}' -- 0014: lift group -> live queue minutes
               , created_at)
  index on (resort_id, observed_at desc)
resort_conditions (id bigserial pk, resort_id, observed_at, expires_at, source text, current jsonb, hourly jsonb, created_at,
                   elevation_m real null, recent jsonb default '[]')

meets (meet_id uuid pk, resort_id text not null references resorts, bundle_id text,
       rendezvous_id text not null, proposer_id uuid not null, invitee_id uuid not null,
       status text not null check (status in ('proposed','active','completed','declined','cancelled','expired','invalidated')),
       end_reason text check (end_reason in ('arrived','declined_by_user','declined_cannot_route','user_cancelled',
                                             'timeout','rendezvous_removed','status_blocks_route','partner_left','superseded')),
       proposer_eta_s int, proposer_eta_sd_s int, invitee_eta_s int, invitee_eta_sd_s int,
       created_at, responded_at, ended_at, expires_at timestamptz not null, superseded_by uuid,
       ended_by uuid check (ended_by is null or ended_by in (proposer_id, invitee_id)),
                                             -- the participant whose request ended it; null when the server did (0023)
       check (proposer_id <> invitee_id))
  unique index meets_one_active_proposer on (proposer_id) where status in ('proposed','active')
  unique index meets_one_active_invitee  on (invitee_id)  where status in ('proposed','active')
  -- a user may appear in at most one non-terminal meet in either role: enforced in meet_propose with
  -- an advisory lock on both user ids plus these two indexes.

meet_progress (meet_id uuid references meets, user_id uuid, eta_s int, eta_sd_s int, remaining_m int,
               state text check (state in ('navigating','rerouting','arrived','lost')),
               fix_at timestamptz, updated_at, primary key (meet_id, user_id))

presence (user_id uuid pk, resort_id text references resorts, lon double precision, lat double precision,
          accuracy_m real, speed_ms real, heading_deg real, captured_at timestamptz not null,
          received_at timestamptz not null default now(), app_build text)

descents (descent_id uuid pk, owner_id uuid not null, source text not null, started_at, ended_at,
          content_hash text not null, track bytea not null, resort_id text references resorts,
          device text, app_build text, created_at, stats jsonb,   -- `02-DOMAIN.md` section 8; migration 0011
          unique (owner_id, content_hash))
descent_matches (descent_id uuid references descents, bundle_id text references resort_bundles,
                 matcher_version int, matched jsonb not null, coverage real, confidence real, created_at,
                 primary key (descent_id, bundle_id, matcher_version))
pace_observations (id bigserial pk, owner_id uuid, descent_id uuid, bundle_id text, edge_id text,
                   elapsed_s real, moving_s real, length_m real, observed_at timestamptz, conditions_id bigint,
                   difficulty text null check in green|blue|black|double_black|park)   -- migration 0015
pace_models (owner_id uuid pk, computed_at timestamptz, difficulty_factor jsonb, edge_factor jsonb,
             stops_per_km real, n_descents int)

device_tokens (user_id uuid, token text, environment text check (environment in ('development','production')),
               app_build text, created_at, updated_at, primary key (user_id, token))
push_outbox (id bigserial pk, user_id uuid, kind text, payload jsonb, created_at, leased_until timestamptz,
             attempts int default 0, sent_at timestamptz, last_error text)
notification_prefs (user_id uuid pk references profiles on delete cascade,
                    muted_kinds text[] not null default '{}' check (muted_kinds <@ the eight push kinds),
                    updated_at timestamptz)                 -- migration 0018; no row = every kind on

jobs (id bigserial pk, kind text check (kind in ('status_refresh','conditions_refresh','push_drain','expiry_sweep',
      'pace_recompute','avatar_sweep')), resort_id text, owner_id uuid, run_after timestamptz not null, leased_until timestamptz,
      attempts int default 0, last_error text, created_at)
  index on (kind, run_after) where leased_until is null

friend_codes (user_id uuid pk references profiles on delete cascade,   -- 0016: one add code per user,
              code text not null unique check (code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$'),
              created_at)                                                 -- made on first ask; no client grants
user_reports (id bigint identity pk,                                      -- 0017: written only by report_user
              reporter_id uuid references profiles on delete set null,
              reported_id uuid references profiles on delete set null,
              reported_name text not null, reported_avatar_url text,     -- copied at report time
              reason text not null check in (inappropriate_photo, inappropriate_name, harassment, spam,
                                             impersonation, other),
              note text (1..500), context text check in (friend, request, contact, code),
              created_at, reviewed_at, review_note)                      -- reviewed in the dashboard
                                         -- deleted with the reported account (0025); kept, without
                                         -- reporter_id, when the reporter's account is deleted
apple_tokens (user_id uuid pk references auth.users on delete cascade,   -- 0025: Sign in with Apple
              refresh_token text not null, updated_at timestamptz default now())
              -- refresh token for revocation on account deletion; written and read only by an
              -- edge function with the service role; RLS on, no policies, no client grants
developer_accounts (user_id uuid pk references auth.users on delete cascade,   -- 0027
              added_at timestamptz not null default now())
              -- who may open the app's Dev page; rows added by hand with the service role (never
              -- by a migration); RLS on, no policies, no client grants

client_events (id bigserial pk, user_id uuid, kind text, props jsonb, at timestamptz default now(), app_build text)
app_config (key text pk, value jsonb)                       -- min_app_build, feature notes
rate_limits (user_id uuid, bucket text, window_start timestamptz, count int, primary key (user_id, bucket, window_start))
```

Views: `published_resorts` (resorts where published, joined with active bundle id,
status mode, review minutes), `resort_catalog` (every resort, published or not, with `region`,
`country`, the active bundle's `bundle_id`, `published_at` and `built_at`, all three null
while the resort has no map, and `aliases` (0020); it runs with its owner's rights because it is the one read
that shows unpublished rows, and it carries catalog metadata only), `resort_status_current` (latest row per resort),
`resort_conditions_current`, `pace_models_friend_read` (pace_models where
`is_accepted_friend(auth.uid(), owner_id)` or owner), `friends_view` (accepted
friendships as `{user_id, display_name, avatar_url}` for the caller).

## 3. RLS (select) by table

| Table | authenticated may select when |
|---|---|
| profiles | `id = me` or `is_accepted_friend(me, id)`. A pending request does not open the row (anyone can create one); pending names and avatars come from `social_snapshot()`. `email_hash`, `height_cm` and `weight_kg` are excluded by column grants, so clients name columns (`select *` is denied) and nobody, friend or not, can select them; the owner reads height and weight back through `profile_private()` |
| user_blocks | `blocker_id = me` |
| friendships | `me = requester_id`, or `me = addressee_id` unless the addressee has blocked the requester: a request from someone you blocked is hidden from you (0025) |
| resorts, resort_bundles, resort_active_bundle, resort_bundle_publications, resort_status, resort_conditions | published resorts only (`exists (select 1 from resorts r where r.id = resort_id and r.published)`); anon may select these too for the picker preview |
| resort_catalog (view) | everyone, every row: the picker lists resorts that have no map yet |
| meets | `me in (proposer_id, invitee_id)` |
| meet_progress | participant of the meet: their own row always, the partner's row only while the meet is `proposed` or `active` (0026). The rule ignores blocks, so a block reads like any other ending |
| presence | `user_id = me` or (`is_accepted_friend(me, user_id)` and `received_at > clock() - interval '15 minutes'`): the TTL is server time, not the sender's `captured_at` (I-24). It never reads the viewer's own row (see the rule below) |
| descents, descent_matches, pace_observations | `owner_id = me` |
| pace_models | owner or accepted friend (the table's own policy and the view allow the same rows and columns) |
| device_tokens, push_outbox, jobs, rate_limits, friend_codes, user_reports, notification_prefs, apple_tokens, developer_accounts | service role only (the owner reads and writes `notification_prefs` through its two RPCs) |
| client_events | insert via RPC; select service role |
| app_config | everyone |

**A policy never reads the caller's own row in the same table.** A friend read of
presence limited to the viewer's own resort, read from the viewer's own presence row,
makes every friend row vanish when that row is missing or stale, and Realtime, which
passes through RLS, goes quiet with it. Who may see a row is decided by friendship, blocks and
time only (`friend_sees_presence_without_own_row`, `140_presence_clear.test.sql`). The
client also subscribes to its topic before its first `presence_update` (section 5),
because positions that arrive before the friend set has loaded would be dropped.

No `insert`, `update` or `delete` policies for `authenticated` on any table. Writes are
RPCs. (The one exception MAY be `client_events` insert with `user_id = me`.)

## 4. Triggers

- `friendships_transitions` BEFORE INSERT OR UPDATE: INSERT must have `status =
  'pending'`; UPDATE may only move `pending → accepted` and set `responded_at`;
  anything else raises.
- `meets_transitions` BEFORE INSERT OR UPDATE: a row is born `proposed`; updates follow
  the table in `03-PROTOCOL.md` section 1 and may not change `resort_id, rendezvous_id,
  proposer_id, invitee_id, created_at, expires_at, bundle_id` or the proposer's estimate.
- `meets_ended_by` BEFORE INSERT OR UPDATE (fires before `meets_transitions`): on the
  move to a terminal state sets `ended_by` to `auth.uid()` when the caller is a
  participant, else null (cron, publish); `ended_by` is null on insert and never
  changes after (0023).
- `meets_notify` AFTER INSERT OR UPDATE: `realtime.send` `meet.proposed` to the invitee
  and `meet.updated` to both participants on every status change; insert `push_outbox`
  rows for exactly the kinds in `11-SETUP-RELEASE.md` section 5 (none for `completed`
  or `superseded`; `meet.ended` goes to whoever did not end the meet, to both when the
  server did; `meet.expired` goes to the proposer, and to both if the meet was active).
- `meet_progress_notify` AFTER INSERT OR UPDATE: `realtime.send` `meet.progress` to
  the other participant. (The `meet.ended` push to both when both have arrived is
  queued by `meet_progress_update` itself, not by a trigger: 0025.)
- `presence_fanout` AFTER INSERT OR UPDATE: for each recipient per DECISION 7, `realtime.send`
  `presence` to `user:{recipient}`.
- `friendships_notify` AFTER INSERT OR UPDATE OR DELETE: friend events to the counterpart,
  except to an addressee who has blocked the requester: their hidden request sends them
  nothing when made or removed (0025).
- `resort_status_notify` AFTER INSERT: `realtime.send` `resort.status` to `resort:{id}`.
- `bundle_publish_invalidate` AFTER INSERT OR UPDATE on `resort_active_bundle`: invalidate
  non-terminal meets whose `rendezvous_id` is not in the row's `rendezvous_ids`
  (the publish RPC writes the list).
- `profiles_from_auth` AFTER INSERT on `auth.users`: create the profile row. The name is
  the sign-up metadata's `display_name` / `full_name` / `name` when it passes the
  display-name rules and is free, otherwise a free placeholder `Skier NNNNNN`
  (`display_name_placeholder`). Onboarding never shows the placeholder and cannot finish
  without saving a real name. The trigger never raises: a clash falls back to a name
  derived from the user id.

## 5. Realtime topics and policies

- Topics: `user:{uuid}` and `resort:{resort_id}`. All private. No client sends.
- `realtime.messages` policies:
  ```sql
  create policy user_topic_read on realtime.messages for select to authenticated
    using (realtime.topic() = 'user:' || (select auth.uid())::text
        or realtime.topic() like 'resort:%');
  -- no insert policy for authenticated: clients cannot broadcast
  ```
- Dashboard: Realtime "Allow public access" OFF. Clients subscribe with
  `config: { private: true }`. The client connects the WebSocket before any
  `realtime.send` can reach it (partition creation), which the session guarantees by
  subscribing during `AppSession.run()` before `presence_update`.

## 6. RPCs

| RPC | Who | Does |
|---|---|---|
| `friend_request(p_user uuid)` | authenticated | insert pending or, if the inverse pending exists, accept it; self, an unknown user or someone the caller blocked → `invalid`. To someone who blocked the caller it behaves exactly as an unanswered request (the pending row is stored and returned, and shows in the caller's `pending_out` and search), but the blocker never sees it and gets no event or push (0025). Nothing raises `blocked` |
| `friend_respond(p_friendship_id uuid, p_accept bool)` | addressee | accept or delete; a hidden request (from someone the caller blocked) is `not_found` |
| `friend_remove(p_user uuid)` | either | delete the friendship row between the two, pending or accepted (the app uses it to withdraw a request); ends any non-terminal meet between them with `partner_left` |
| `block_user(p_user uuid)` / `unblock_user` | caller | insert/delete block; block also removes friendship and ends meets; unblock first deletes a request that waited hidden behind the block, which its sender sees as a decline (0025) |
| `find_users(p_email_hashes text[], p_phone_hashes text[])` | authenticated, rate-limited 20/min, email array ≤ 50 | returns `(id, display_name, avatar_url)` for email matches, never someone the caller blocked; someone who blocked the caller matches as anyone (0025). `p_phone_hashes` is accepted for old builds and ignored |
| `social_snapshot()` | authenticated | friends, pending in/out, blocks, in one JSON. Friends are accepted and not blocked either way; each friend entry also carries the card fields (0016): `ability`, `equipment`, `stats` (`lifetime_stats`: `runs`, `days`, `distance_m`, `vertical_m`, `top_speed_ms`, `avg_speed_ms`, summed from `descents.stats` the way `ActivityHistory.Totals` sums one's own; a malformed value is skipped, never fatal) and `last_seen` (`{resort_id, at}` of a presence row received within the 15 minute TTL, else null; never coordinates). Pending and blocked entries carry name and photo only. `pending_in` leaves out a request from someone the caller blocked (0025) |
| `friend_code_get()` | authenticated | the caller's add code, made on first ask |
| `friend_code_rotate()` | authenticated, rate-limited 10/hour | a new code; the old one stops working |
| `friend_code_resolve(p_code text) returns jsonb` | authenticated, rate-limited 30/hour with `friend_request_by_code` | `{user_id, display_name, avatar_url, relation}` (`self`, `friend`, `request_sent`, `request_received`, `none`) for the code's owner, or null for an unknown or replaced code and for the code of someone the caller blocked alike; the code of someone who blocked the caller answers as for anyone (0025). Case, spaces and dashes are ignored. A miss returns rather than raises, so it counts against the limit |
| `friend_request_by_code(p_code text) returns jsonb` | authenticated, same limit | `friend_request` to the code's owner (accepting theirs if they asked first); the friendship row, or null when the code names nobody the caller can ask, their own included |
| `search_users(p_query text) returns table (user_id, display_name, avatar_url, relation)` | authenticated, rate-limited 60/min | people whose display name contains the query: normalised with `display_name_normalize`, compared ignoring case (against the stored `profiles.search_name` through its trigram index since 0026, so a call no longer normalises every profile; a two-character query has no trigram and reads the whole index), `%`, `_` and `\` taken literally; prefix matches first, then the rest, each in name order; at most 20. `relation` is `friend`, `request_sent`, `request_received` or `none`. Never the caller, anyone the caller blocked (someone who blocked the caller is listed as anyone, 0025), or an account still on its sign-up placeholder (`display_name_is_placeholder`). A query under 2 or over 24 characters once normalised returns nothing and is not counted. Nothing else about a person is returned (0019) |
| `is_developer() returns boolean` | authenticated, not rate-limited | true when the caller is listed in `developer_accounts` (0027); nothing in the app calls it yet (maintainer, 23 Nov: the Dev page stays open to TestFlight builds for now). Anon cannot call it |
| `report_user(p_user uuid, p_reason text, p_note text default null, p_context text default null)` | authenticated, rate-limited 10/hour | inserts a `user_reports` row with the reported name and photo path; anyone but the caller can be reported; `invalid` for an unknown user, the caller, a reason or context outside the list, or a note over 500 characters (a blank note is none) |
| `profile_update(p_patch jsonb)` | owner | whitelisted keys only: `display_name`, `avatar_url`, `ability`, `max_difficulty`, `baseline_speeds`, `equipment`, `avoid`, `max_pitch_deg`, `height_cm`, `weight_kg`, `current_resort_id`. `email_hash` (server-kept since 0022) and `phone_hash` (dropped in 0025; build 3.0.0 still sends it) are removed from the patch silently, so a patch carrying them still applies. A value outside the column's range or shape is `invalid`. `display_name` is normalised (`display_name_normalize`: NFKC, every space to one space, control and invisible characters removed, spaces collapsed, ends trimmed) and must then be 2–24 code points (`invalid`), contain no blocked word (`name_not_allowed`) and not be another user's name ignoring case (`name_taken`, also when the unique index catches a race). Returns the caller's whole row, private columns included |
| `display_name_available(p_name text) returns text` | authenticated, rate-limited 60/min | `available`, or the code `profile_update` would raise for this name (`invalid`, `name_not_allowed`, `name_taken`); the caller's own name is available |
| `profile_private()` | owner | `{height_cm, weight_kg}` of the caller; there is no way to ask for anyone else's |
| `meet_*` | see `03-PROTOCOL.md` | |
| `presence_update(p_resort_id, p_lon, p_lat, p_accuracy_m, p_speed_ms, p_heading_deg, p_captured_at)` | owner | upsert if `p_captured_at` newer; rate-limited 1/2 s |
| `presence_snapshot(p_resort_id text)` | authenticated | accepted friends' presence rows at that resort within TTL, plus the caller's meet partner's row at any resort while their meet is proposed or active (the partner's marker depends on it) |
| `presence_clear()` | owner, not rate-limited | deletes the caller's presence row (0020). The client calls it on sign-out (before the server sign-out), when it closes a resort without opening another, and best-effort when the app is terminated. Friends lose the row from `presence_snapshot` and `last_seen` at once; a dot already drawn ages out on the client, since a delete sends no event. Since 0026 it also sets the caller's `profiles.current_resort_id` to null, so friends stop reading that resort and `presence_recipients` stops sending them positions by it; the next resort the phone opens sets it again |
| `device_token_register(p_token, p_environment, p_app_build)` / `device_token_unregister(p_token)` | owner | |
| `descent_upsert(p_descent jsonb) returns (descent_id uuid, created boolean)` | owner | `p_descent` = descent fields from `02-DOMAIN.md` section 8 (`stats` included: an object of at most 4 kB, else `invalid`) plus optional `match {bundle_id, matcher_version, matched, coverage, confidence}`, each `matched` element `{edge_id, enter_at, exit_at, moving_s, length_m, difficulty?}` (`difficulty` is the edge's in that bundle, as the phone read it; 0015 stores it on `pace_observations`); dedup on `(owner_id, content_hash)` and on > 80 % time overlap with an existing descent of the owner; a repeat with the same `content_hash` replaces the stored `stats`; upserts `descent_matches`; enqueues `pace_recompute`. Rate-limited (0026): 120 calls a minute, and 1,000 new descents a day (a repeat or re-match is not a new descent), both `rate_limited`, which the phone queues and sends later |
| `descent_delete(p_descent_id)` | owner | deletes derived rows; enqueues recompute |
| `notification_prefs() returns text[]` | owner | the caller's muted push kinds, sorted; `{}` when every notification is on |
| `notification_prefs_set(p_muted text[]) returns text[]` | owner | replaces the caller's muted kinds and returns them as stored (each once, sorted); null or `{}` turns everything on; a kind outside the notification set or a null element is `invalid` and changes nothing |
| `client_event(p_kind text, p_props jsonb)` | authenticated | insert |
| `account_delete()` | owner | ends non-terminal meets with `partner_left`, deletes friendships, blocks, presence, descents and derived rows, device tokens, reports about the user (they hold the copied name and photo and what was said about them), profile (its add code and Apple token go with it; reports it filed keep their rows without its id), then the `auth.users` row (App Store guideline 5.1.1). It never touches `storage.objects` (a SQL delete removes the row and orphans the stored file); it queues an `avatar_sweep` job with no owner, so the job outlives the profile, and pings `avatar-sweep`, which removes any photo left behind within about a minute (0021). The client still removes its avatar files through the Storage API first, while it owns the folder. It also deletes every other user's `push_outbox` row whose payload names it (`partner_id` or `user_id`), except an unsent `meet.ended`, which is kept with the photo and id stripped so the partner still hears the meet ended. For the meet this call ended (`partner_left`) it keeps the partner's name until the push is sent, so it reads "Meet ended: <name> left" like any partner-left ending; trigger `push_outbox_forget_name` drops the name when the row is marked sent, collapsed, stale or given up (0026). The meet row itself then cascades away with the profile. In `realtime.messages` it deletes, before writing any event of its own, every message whose payload mentions the user and everything on the user's own topic; afterwards it deletes what it sent to its own topic and strips `display_name` and `avatar_url` from the `friend.removed` events it sent to others, keeping their ids, so partners' and friends' phones still catch up (0025; 0023 purged presence broadcasts only). The realtime steps warn and never block the deletion |
| `bundle_publish(p_resort_id, p_bundle_id, p_rendezvous_ids text[], p_report jsonb, p_published_by text)` | service role | validates the bundle row exists and matches resort; moves pointer; records publication; triggers invalidation |
| `bundle_rollback(p_resort_id, p_bundle_id)` | service role | re-point to an earlier bundle |
| `avatar_orphans(p_limit int default 100) returns setof text` | service role | avatar object paths nobody uses: the owner's profile is gone (listed first), or the path is not the owner's current `avatar_url` and the object is over an hour old, so an upload still waiting for its `profile_update` is never listed; at most `p_limit` (1–1000) (0021) |
| `avatar_sweep_enqueue()` | cron | queues one `avatar_sweep` job unless one is already waiting, and pings `avatar-sweep` (0021) |
| `jobs_claim(p_kind text, p_limit int default 1) returns setof jobs` | service role | `for update skip locked`, lease 5 min |
| `jobs_complete(p_id bigint, p_error text default null)` | service role | delete or reschedule with backoff; dropped after five attempts |
| `push_outbox_claim(p_limit int default 25) returns (id, user_id, kind, payload, tokens)` | service role | retires rows whose kind the recipient muted (`last_error = 'muted'`, 0018), rows older than 15 min, collapses duplicates (same user, kind and meet) against a newer waiting row or one sent in the last 60 s, then leases a batch `for update skip locked` and returns each row with its device tokens |
| `push_outbox_complete(p_id bigint, p_error text default null, p_dead_tokens text[] default null)` | service role | mark sent, or release with backoff (given up after five attempts); delete dead tokens |
| `pace_recompute(p_owner uuid)` | service role | rewrites the owner's `pace_models` row from their `pace_observations` (`08-ACTIVITY.md` section 4.2); deletes it when no usable observation is left; also queued by trigger `profiles_baseline_pace_recompute` whenever `baseline_speeds` changes, so the factors are never measured against an old baseline |
| `pace_recompute_drain(p_limit int default 50) returns int` | cron | claims due `pace_recompute` jobs with `jobs_claim`, runs `pace_recompute` for each, completes them; one failure does not stop the rest |
| `expire_meets()` | cron | proposal and active sweeps per protocol |
| `presence_cleanup()` | cron | delete rows older than 2 h, and `presence` broadcasts in `realtime.messages` whose envelope `at` is past the 15 minute TTL (0023); returns the presence rows removed |
| `housekeeping()` | cron | retention: status and conditions rows 7 days, outbox 7 days, rate limits 1 day, client events 90 days, dead jobs |

Error codes beyond `03-PROTOCOL.md` section 5, used by the non-meet RPCs: `not_authenticated`,
`invalid`, `not_found`, `rate_limited`, `name_taken`, `name_not_allowed`.

## 7. Jobs and cron

| Cron | Schedule | Action |
|---|---|---|
| `enqueue_status_refresh` | `*/15 * * * *` | one `status_refresh` job per published resort with `status_mode = live` (coalesce if pending) |
| `enqueue_conditions_refresh` | `5 * * * *` | one `conditions_refresh` job per published resort |
| `scheduled_status_rows` | `0 * * * *` | insert one `source = scheduled` status row per published `scheduled_only` resort, with empty `groups` (no live information for any lift: use operating hours). No job and no worker |
| `expire_meets` | `* * * * *` | `select expire_meets()` |
| `presence_cleanup` | `*/10 * * * *` | |
| `push_drain_ping` | `* * * * *` | if unsent rows are waiting, `pg_net` POST to `push-drain` with `x-worker-secret` from `vault` (the outbox also pings on every enqueue, so this is the retry net) |
| `status_worker_ping` / `conditions_worker_ping` | `* * * * *` | one `pg_net` POST per job that has been due for 20 s, at most 20 per tick (the enqueue functions ping for the first 20). Sized for about 160 published resorts at one job per invocation: a full round drains in 8 minutes |
| `pace_recompute` | `* * * * *` | `select pace_recompute_drain()`: a new descent reaches the pace model within about a minute (migration 0015) |
| `enqueue_avatar_sweep` | `40 * * * *` | `select avatar_sweep_enqueue()`: the retry net for a photo the client failed to remove (0021) |
| `avatar_worker_ping` | `* * * * *` | one `pg_net` POST to `avatar-sweep` per `avatar_sweep` job due for 20 s (a lost ping, or a failed sweep due again) |
| `housekeeping` | `20 9 * * *` | `select housekeeping()` |

Workers (edge functions, `verify_jwt = false` in `config.toml`, but every request MUST
carry `x-worker-secret` matching `WORKER_SECRET`), one job per invocation:
`status-refresh` claims one job, reads the lift groups and provider aliases from the
resort's active bundle, runs the provider the resort declares in
`resorts.status_provider` (`epic`, `mtnpowder` or `liftie`; Liftie is lift-only and no resort uses it yet),
inserts `resort_status` and completes the job. The lift groups and aliases come from
`resort_bundles.status_meta` when the bundle's row has it; otherwise the worker downloads
the bundle, verifies its hash, derives them and stores them there (0026), so each bundle
is downloaded once, not once per job. An unusable provider answer writes
nothing and is not retried until the next 15 minute round (`NoRetry`); any other failure
is retried with backoff. A provider may see more than one request per resort per round
(Epic is asked under two spellings of the resort, and MtnPowder's whole shared feed is
fetched for each resort job). `conditions-refresh` asks
Open-Meteo once per resort (cached 50 min) and, like the status providers, does not retry a failed request until the next hourly job (`NoRetry`, 0026); `push-drain` claims one batch of up to 25 outbox rows through
`push_outbox_claim`, sends APNs, and reports dead tokens (410, or 400 with
`BadDeviceToken`) for deletion; `avatar-sweep` claims one `avatar_sweep` job, lists
paths with `avatar_orphans` in batches of 100 (at most 10 batches; the next sweep takes
the rest) and removes them through the Storage API with the service role, which deletes
the stored bytes with the row. The outbox is its own queue: there are no `push_drain`
rows in `jobs`. Secrets: `WORKER_SECRET`, `APNS_*`, `SUPABASE_SERVICE_ROLE_KEY` (edge
runtime provides it). The project URL and the secret for cron live in Supabase Vault
(`project_url`, `worker_secret`), read in SQL with `vault.decrypted_secrets`; with
either missing the pings do nothing.

## 8. Storage

| Bucket | Access | Content |
|---|---|---|
| `resort-bundles` | public read, service-role write | `<resort_id>/<bundle_id>.json.gz` |
| `resort-reports` | public read | pipeline reports and GeoJSON previews |
| `avatars` | public read; the owner writes, replaces and removes objects under `<own user id>/` through `storage.objects` policies | `<lower-case user id>/<new uuid>.jpg`: a 512 × 512 JPEG with no metadata, a new name for every upload (a path names its bytes; cached a year), saved as `avatar_url` and the user's other objects then removed by the client. The app makes the JPEG; the bucket itself accepts JPEG, PNG or HEIC up to 2 MiB and does not check the size or metadata, so that guarantee holds for the app's own uploads only. A photo is public by its path: anyone who has the path can fetch it (search and add by name return it to strangers), and unfriending or blocking does not revoke a path someone already holds. Objects are only ever removed through the Storage API, never with SQL. Whatever the client fails to remove, and everything of a deleted account, is removed by the `avatar-sweep` worker (section 7): a deleted user's photo within about a minute, a replaced or removed one within about two hours |

## 9. Discovery and privacy

- `profiles.email_hash` is the SHA-256 hex of the account's auth email, trimmed and
  lowercased. The server keeps it (0022: a trigger on `auth.users` insert and email
  change, plus a one-time backfill); clients cannot write it. Only a confirmed address
  (`email_confirmed_at` set) has a hash, so an unconfirmed sign-up cannot claim someone
  else's address; a second trigger sets the hash when the address is confirmed (0023). An Apple private relay
  address gets none, and when two accounts share an address the earlier one keeps
  the hash. The app hashes its contacts' email addresses the same way in memory and
  sends only the hashes to `find_users`; the address book is not
  stored on the phone or the server (the app keeps only the server's matches, per account, until the session ends: `07-CLIENT.md` section 4). The hash is unsalted, so
  anyone who knows an address can compute it; any signed-in account can test 50 hashes
  a call, 20 calls a minute, and learns the name, photo path and id of each match.
  No phone number or phone hash is stored (`phone_hash` was dropped in 0025).
- `find_users` caps arrays and is rate-limited by `rate_limits`.
- Blocks are hidden (0025). Nothing tells the person blocked: no RPC raises `blocked`,
  and search, contact matching and add codes show them the blocker as they show any
  stranger, so a missing result never gives the block away. A request they send is
  stored and looks pending to them, but the blocker never sees it, by row, list, event
  or push; a meet to the blocker is `not_friends`. The blocker never sees the person
  they blocked anywhere but their block list. Friendship ends at the block, so friend
  cards, presence and pace close as on unfriending.
- Add codes (0016) find anyone, including someone whose Apple email is hidden and who
  has added no number: the holder of a code learns its owner's name and photo, and
  nothing more until they are friends. Codes are random (about 49 bits), replaceable,
  unreadable from any table, and lookups are rate-limited with misses counted; the code
  of someone you blocked answers as unknown.
- Search by name (0019) finds anyone who has finished onboarding, by part of their name,
  and returns their name, photo and relation to the caller only. Someone you blocked is
  never in your results; you stay in theirs, as for anyone (0025). It is rate-limited, as each call says which names exist.
- Presence rows carry no display name; the client joins names from `friends_view`.

## 10. pgTAP matrix

Negative cases that MUST exist, each named after the hole it rules out: `forged_accepted_friendship_rejected` (direct insert and RPC), `meet_to_non_friend_rejected`,
`meet_to_blocked_rejected`, `sender_cannot_self_accept`, `participant_cannot_rewrite_meet_columns`,
`stranger_cannot_read_profile_stats_or_pace`, `stranger_cannot_read_profile_details`,
`anon_cannot_read_user_tables`, `find_users_capped_and_rate_limited_returns_minimal_columns`,
`clients_cannot_insert_realtime_messages`, `stranger_cannot_subscribe_to_user_topic`,
`device_token_removed_on_unregister`, `presence_not_visible_after_unfriend_or_block`,
`display_name_unique_ignoring_case`, `display_name_normalised_and_blocked`
(`090_display_names.test.sql`),
`worker_endpoints_reject_missing_secret` (edge function tests),
`stranger_gets_no_friend_card_fields` and `blocked_friend_not_listed` (`100_friend_card.test.sql`),
`friend_code_hidden_from_blocked`, `replaced_friend_code_names_nobody` and `friend_code_misses_are_rate_limited`
(`110_friend_codes.test.sql`), `reports_written_only_through_report_user`, `reports_hold_no_deleted_account` and `reports_survive_reporter_deletion`
(`120_user_reports.test.sql`), `search_never_lists_self`, `search_hides_blocked`, `search_skips_placeholder_names` and `search_escapes_wildcards` (`130_search_users.test.sql`),
`friend_sees_presence_without_own_row` and `presence_clear` as self, friend, stranger, blocked and anon (`140_presence_clear.test.sql`).
Avatar orphans listed and removed, never a photo still in use (`150_avatar_sweep.test.sql`), and an email hashed only once confirmed (`160_email_match.test.sql`).
`meet_propose_rate_limited`, a future `fix_at` not freezing progress (D14), `ended_by` as self, friend, stranger, blocked and server, a block ending a live meet, presence broadcasts purged after the TTL and on deletion, no push naming a deleted user, and an unconfirmed email not matchable (`170_review_fixes.test.sql`). `block_hidden_from_blocked` (a request to the blocker looks unanswered, the blocker sees and hears nothing), `meet_completes_when_both_arrived` (once), `reports_hold_no_deleted_account`, `realtime_forgets_deleted_user` (the partner's own event from the delete survives), no `phone_hash` with build 3.0.0's patch still applying, and `apple_tokens` unreadable as self, friend, stranger, blocked and anon (`180_owner_decisions.test.sql`). `descent_upsert_rate_limited` (per minute, and new descents per day), `presence_clear_forgets_resort`, `ended_meet_progress_private` (a block reads like any ending), `avatar_folder_is_the_owners` (self, friend, stranger, blocked and anon against `storage.objects`), `friend_cannot_subscribe_to_user_topic` and `blocked_cannot_subscribe_to_user_topic`, `events_reach_only_recipients` (presence, progress, meet updates and a block), and `account_delete_leaves_nothing` (presence, runs, tokens, blocks, pushes, meets; the partner told `partner_left`), `partner_learns_why` (the push names who left until it is sent) and `search_name_indexed` (`190_review_followups.test.sql`). `developer_only_when_listed` and `developer_list_closed_to_clients` as listed, unlisted and anon (`200_developer_accounts.test.sql`). `stale_arrival_does_not_complete` and `fresh_arrivals_complete` (`210_fresh_arrival.test.sql`). `080_pace_recompute`: the job is consumed, the factors match a fixture, a repeat changes nothing, a delete removes the model, old seasons weigh half, and the model is readable by self and friend only while descents and observations stay owner-only.

For each table: select as self / friend / stranger / blocked (expect rows or none).
For each RPC: success path, each precondition failure, idempotent repeat. For each
trigger: the forbidden transition raises. For realtime: `realtime.messages` policy
allows own topic, denies another user's topic, denies insert. For cron functions:
`expire_meets` moves exactly the expected rows at a fixed `now()` (inject through a
`clock()` function with a test override).

## 11. Migrations

- `0001_extensions.sql` (pgcrypto, pg_cron, pg_net, pgtap in test), `0002_tables.sql`,
  `0003_policies.sql`, `0004_functions.sql`, `0005_triggers.sql`, `0006_realtime.sql`,
  `0007_cron.sql`, `0008_seed_resorts.sql` (catalog metadata only, no bundles).
  `0009_profile_equipment_null.sql` and `0010_profile_equipment_ski_skin.sql` loosen
  and extend the `equipment` check (null means not set; the display-only `ski` and
  `skin` keys). `0011_descent_stats.sql` adds `descents.stats`; `0014_lift_waits.sql`
  adds `resort_status.wait_minutes`.
  `0012_resort_catalog.sql` seeds every resort in `pipeline/resorts.yaml` with its
  region and country and adds the `resort_catalog` view. `0015_pace_recompute.sql` adds
  `pace_observations.difficulty`, keeps it in `descent_upsert`, adds `pace_recompute`,
  `pace_recompute_drain` and their cron entry, and queues one job per owner with
  observations.
  `0013_display_names.sql` adds the
  display-name normalisation, block list, case-insensitive unique index, placeholder
  trigger, the name checks in `profile_update` and `display_name_available`.
  `0018_notification_prefs.sql` adds `notification_prefs`, its two RPCs and the
  `muted` rule in `push_outbox_claim` (`100_notification_prefs.test.sql`).
  `0016_friend_card_and_codes.sql` replaces `social_snapshot()` (same signature) with
  the friend card fields and adds `stats_number`, `lifetime_stats`, `friend_codes` and
  the four code RPCs. `0017_user_reports.sql` adds `user_reports` and `report_user`.
  `0019_search_users.sql` adds `display_name_is_placeholder` and `search_users`.
  `0020_resort_aliases_presence_clear.sql` adds `resorts.aliases` (seeded with 24
  lists, also in `pipeline/resorts.yaml`), appends it to `resort_catalog`, and adds
  `presence_clear()`.
  `0021_avatar_sweep.sql` adds `avatar_orphans`, `avatar_sweep_enqueue`, the
  `avatar_sweep` job kind and its cron entries, and stops `account_delete` deleting
  `storage.objects` rows (`150_avatar_sweep.test.sql`). `0022_email_match.sql` has
  the server derive `profiles.email_hash` from the auth email and stops clients
  writing it (`160_email_match.test.sql`).
  `0023_review_fixes.sql` adds `meets.ended_by` and its trigger, rate-limits
  `meet_propose`, caps meet estimates, clamps a future `fix_at` in
  `meet_progress_update`, hashes only confirmed emails, purges presence broadcasts in
  `presence_cleanup` and `account_delete`, and clears a deleted user from other
  people's queued pushes (`170_review_fixes.test.sql`). `0024_conditions_profile.sql`
  adds `resort_conditions.elevation_m` and `recent` for the per-run weather
  (`06-SOLVER.md` section 2). `0025_owner_decisions.sql` hides blocks (the
  `friendships_read` policy, `friend_request`, `friend_respond`, `unblock_user`,
  `friendships_notify`, `social_snapshot`, `find_users`, `search_users`,
  `friend_code_owner`, `meet_propose`), completes a meet when both have arrived
  (`meet_progress_update`), has `account_delete` delete reports about the user and
  realtime messages naming them, deletes reports already left by deleted accounts, drops
  `profiles.phone_hash` (`profile_update` ignores the key), and adds `apple_tokens`
  (`180_owner_decisions.test.sql`). `0026_review_followups.sql` rate-limits
  `descent_upsert`, has `presence_clear` clear `current_resort_id`, limits
  `meet_progress_read` to the caller's own row once a meet ends, has `meet_propose` read
  the active bundle `for share`, adds `resort_bundles.status_meta`, keeps the name on a
  deleted user's partner-left push until it is sent (`account_delete`,
  `push_outbox_forget_name`), and adds `pg_trgm`, `profiles.search_name` and its index
  under `search_users` (`190_review_followups.test.sql`). `0027_developer_accounts.sql` adds `developer_accounts` and
  `is_developer()` (`200_developer_accounts.test.sql`). `0028_fresh_arrival.sql` has
  `meet_progress_update` complete a meet only when the other participant's `arrived`
  has a `fix_at` at most 120 s old (`210_fresh_arrival.test.sql`).
- Every later change is a new file; no edits to applied files. CI runs `supabase db
  reset` from zero and the pgTAP suite against the local database; the CLI is never run
  against the hosted project (`AGENTS.md`).

## 12. Dashboard-only settings (checked by hand; `backend/scripts/check-dashboard.sh` is planned)

Realtime "Allow public access" OFF; Auth providers (Apple, and Email with "Confirm email"
on and a minimum password length of 8); Auth redirect URLs `powdermeet://auth-callback` and
`powdermeet://auth-callback?type=recovery`; Storage bucket public
flags as in section 8; Vault secrets `worker_secret` and `project_url` present; edge
function secrets present (names only).
