-- get_social_snapshot(p_resort_id text): atomic read of the caller's social
-- state in a single transaction.
--
-- Returns one JSON object:
--   {
--     "generation":        bigint,        -- nanosecond server clock at read time
--     "friends":           [FriendProfile, ...],
--     "pending_received":  [Friendship,   ...],
--     "pending_sent":      [Friendship,   ...],
--     "presence":          { "<user_id>": PresenceRow, ... }   -- nullable; friend-only
--   }
--
-- FriendProfile shape:
--   { id, display_name, avatar_url, skill_level, current_resort_id }
--
-- Friendship shape:
--   { id, requester_id, addressee_id, status, created_at }
--
-- PresenceRow shape (only when p_resort_id IS NOT NULL, filtered to friends at
-- that resort, null otherwise so we don't leak global presence by default):
--   { user_id, resort_id, lat, lon, captured_at, accuracy_m, last_seen }
--
-- **Contract stability.** Callers (Swift `FriendService.loadSocialSnapshot`)
-- assume these keys exist. Adding keys is safe; renaming / removing must go
-- through a versioned follow-up RPC (`get_social_snapshot_v2`) plus client
-- fan-out rather than a breaking change here.
--
-- SECURITY: declared `security invoker` + `stable`. We rely on the same RLS
-- policies that protect the underlying tables (friendships / profiles /
-- live_presence). No elevation; a caller only sees their own friendships
-- and only friends' profiles / presence — same as today's client-side join.
--
-- Why one RPC instead of two parallel fetches?
--   `loadFriends()` + `loadPending()` raced on Postgres snapshot boundaries
--   — a freshly-accepted friend could appear in `friends` while still
--   appearing in `pendingReceived`, producing the amber "PENDING" flash the
--   `prunePendingOverlappingFriends()` band-aid was fighting. This RPC reads
--   both in the same snapshot so the client applies a coherent state in a
--   single MainActor assignment.

create or replace function public.get_social_snapshot(p_resort_id text default null)
returns jsonb
language plpgsql
security invoker
stable
set search_path = public
as $$
declare
  uid uuid := (select auth.uid());
  friend_ids uuid[];
  friends_json jsonb;
  pending_recv_json jsonb;
  pending_sent_json jsonb;
  presence_json jsonb;
  gen bigint;
begin
  if uid is null then
    -- Unauthenticated: return empty snapshot rather than raising, so the
    -- client treats "not signed in yet" uniformly with "no friends."
    return jsonb_build_object(
      'generation', 0,
      'friends', '[]'::jsonb,
      'pending_received', '[]'::jsonb,
      'pending_sent', '[]'::jsonb,
      'presence', null
    );
  end if;

  -- Collect the other side of every accepted friendship where the caller is
  -- either requester or addressee. Single scan.
  select coalesce(array_agg(
    case when f.requester_id = uid then f.addressee_id else f.requester_id end
  ), array[]::uuid[])
    into friend_ids
    from public.friendships f
   where f.status = 'accepted'
     and (f.requester_id = uid or f.addressee_id = uid);

  -- friends: profile summaries for every accepted counterpart.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',                 p.id,
           'display_name',       p.display_name,
           'avatar_url',         p.avatar_url,
           'skill_level',        p.skill_level,
           'current_resort_id',  p.current_resort_id
         )), '[]'::jsonb)
    into friends_json
    from public.profiles p
   where p.id = any(friend_ids);

  -- pending_received: rows where the caller is the addressee.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            f.id,
           'requester_id',  f.requester_id,
           'addressee_id',  f.addressee_id,
           'status',        f.status,
           'created_at',    f.created_at
         )), '[]'::jsonb)
    into pending_recv_json
    from public.friendships f
   where f.status = 'pending'
     and f.addressee_id = uid
     -- Drop any pending row whose counterparts are already accepted friends,
     -- server-side, so the client never sees the race-window duplicate.
     and not (f.requester_id = any(friend_ids));

  -- pending_sent: rows where the caller is the requester.
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',            f.id,
           'requester_id',  f.requester_id,
           'addressee_id',  f.addressee_id,
           'status',        f.status,
           'created_at',    f.created_at
         )), '[]'::jsonb)
    into pending_sent_json
    from public.friendships f
   where f.status = 'pending'
     and f.requester_id = uid
     and not (f.addressee_id = any(friend_ids));

  -- presence: only filled when p_resort_id is non-null. Filtered to the
  -- caller's friends at that resort; RLS already blocks non-friends so this
  -- filter is primarily for correctness (avoid cross-resort rows) and to
  -- save bandwidth on mountain switches.
  if p_resort_id is not null then
    select coalesce(jsonb_object_agg(
             lp.user_id::text,
             jsonb_build_object(
               'user_id',     lp.user_id,
               'resort_id',   lp.resort_id,
               'lat',         lp.lat,
               'lon',         lp.lon,
               'captured_at', lp.captured_at,
               'accuracy_m',  lp.accuracy_m,
               'last_seen',   lp.last_seen
             )
           ), '{}'::jsonb)
      into presence_json
      from public.live_presence lp
     where lp.resort_id = p_resort_id
       and lp.user_id = any(friend_ids)
       -- Ignore rows older than 15 minutes — matches `live_presence_cleanup`.
       and lp.last_seen >= (now() - interval '15 minutes');
  else
    presence_json := null;
  end if;

  -- Monotonic generation stamp. Client uses it to reject out-of-order
  -- snapshot applications: if a stale in-flight snapshot lands after a
  -- newer one, its generation will be smaller and the client discards it.
  -- Nanoseconds from server clock → strictly increasing for practical
  -- purposes and opaque to the client (don't parse as a Date).
  gen := (extract(epoch from clock_timestamp()) * 1000000000)::bigint;

  return jsonb_build_object(
    'generation',       gen,
    'friends',          friends_json,
    'pending_received', pending_recv_json,
    'pending_sent',     pending_sent_json,
    'presence',         presence_json
  );
end;
$$;

grant execute on function public.get_social_snapshot(text) to authenticated;

-- Convenience overload with no resort (presence stays null).
create or replace function public.get_social_snapshot()
returns jsonb
language sql
security invoker
stable
set search_path = public
as $$
  select public.get_social_snapshot(null::text);
$$;

grant execute on function public.get_social_snapshot() to authenticated;
