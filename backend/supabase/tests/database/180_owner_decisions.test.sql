-- The owner's decisions in migration 0025.
-- Rules out: a blocked user learning they were blocked (block_hidden_from_blocked),
-- the blocker hearing from someone they blocked, a meet left open after both
-- skiers arrived or completed twice (meet_completes_when_both_arrived), a
-- report keeping a deleted account's name, photo or words
-- (reports_hold_no_deleted_account), realtime messages naming a deleted user
-- (realtime_forgets_deleted_user), a phone hash still stored or an old build's
-- patch breaking, and a client reading an Apple token.
begin;
select no_plan();

select tests.set_clock('2026-01-12 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
insert into public.device_tokens (user_id, token, environment)
select u, md5(u::text), 'development'
from unnest(array[tests.alice(), tests.bob(), tests.carol(), tests.dave(), tests.erin()]) u;
select set_config('tests.alice_hash', (select email_hash from public.profiles where id = tests.alice()), true);

-- Friend events of one kind on a user's topic, about one person (or anyone),
-- or -1 when realtime.messages cannot be read here.
create function pg_temp.events(p_user uuid, p_type text, p_about uuid) returns int language plpgsql as $$
declare
  v int;
begin
  select count(*)::int into v from realtime.messages rm
  where rm.topic = 'user:' || p_user::text and rm.event = p_type
    and (p_about is null or rm.payload -> 'data' ->> 'user_id' = p_about::text);
  return v;
exception when others then
  return -1;
end;
$$;

-- ==================================================== block_hidden_from_blocked

select tests.login(tests.alice());
select set_config('tests.alice_code', public.friend_code_get(), true);
select tests.login(tests.dave());
select set_config('tests.dave_code', public.friend_code_get(), true);

-- A stranger's request that alice simply has not answered, for comparison.
select tests.login(tests.carol());
select set_config('tests.carol_req', to_jsonb(public.friend_request(tests.alice()))::text, true);

-- The blocked sender: everything reads as an unanswered request.
select tests.login(tests.dave());
select set_config('tests.dave_req', to_jsonb(public.friend_request(tests.alice()))::text, true);
select is(current_setting('tests.dave_req')::jsonb ->> 'status', 'pending',
  'block_hidden_from_blocked: a request to someone who blocked you succeeds as pending');
select ok(current_setting('tests.dave_req')::jsonb ->> 'responded_at' is null, 'with no answer');
select is(
  (select array_agg(k order by k) from jsonb_object_keys(current_setting('tests.dave_req')::jsonb) k),
  (select array_agg(k order by k) from jsonb_object_keys(current_setting('tests.carol_req')::jsonb) k),
  'shaped exactly like a stranger''s unanswered request');
select is((public.friend_request(tests.alice())).id::text, current_setting('tests.dave_req')::jsonb ->> 'id',
  'asking again returns the same request, as for anyone');
select is((select count(*)::int from public.friendships), 1, 'the sender sees their own request row');
select results_eq(
  $$select e ->> 'user_id', e ->> 'display_name'
    from jsonb_array_elements(public.social_snapshot() -> 'pending_out') e$$,
  $$values (tests.alice()::text, 'Alice'::text)$$,
  'and it is listed in their outgoing requests');
select is((select relation from public.search_users('alice')), 'request_sent',
  'search finds the blocker, with the request sent');
select is(public.friend_code_resolve(current_setting('tests.alice_code')) ->> 'relation', 'request_sent',
  'so does the blocker''s add code');
select is(public.friend_request_by_code(current_setting('tests.alice_code')) ->> 'status', 'pending',
  'and a request by code answers as pending too');
select results_eq(
  format('select id from public.find_users(array[%L], null)', current_setting('tests.alice_hash')),
  $$values (tests.alice())$$, 'contacts match the blocker as anyone');
select throws_ok(
  $$select public.meet_propose('18000000-0000-4000-8000-0000000000d1', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'a meet to the blocker is refused as to any non-friend');
select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_propose('18000000-0000-4000-8000-0000000000c1', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'stranger: the same code');

-- The blocker hears and sees nothing of it.
select tests.logout();
select is(
  (select count(*)::int from public.push_outbox
   where user_id = tests.alice() and kind = 'friend.requested' and payload ->> 'user_id' = tests.dave()::text),
  0, 'the blocker gets no push for the request');
select is(
  (select count(*)::int from public.push_outbox
   where user_id = tests.alice() and kind = 'friend.requested' and payload ->> 'user_id' = tests.carol()::text),
  1, 'while a stranger''s request does push');
select is(pg_temp.events(tests.alice(), 'friend.requested', tests.dave()), 0, 'and no event');
select cmp_ok(pg_temp.events(tests.alice(), 'friend.requested', tests.carol()), '>', 0,
  'while a stranger''s request does send one');

select tests.login(tests.alice());
select is((select count(*)::int from public.friendships where requester_id = tests.dave()), 0,
  'the blocker cannot read the request row');
select results_eq(
  $$select e ->> 'user_id' from jsonb_array_elements(public.social_snapshot() -> 'pending_in') e$$,
  $$values (tests.carol()::text)$$, 'nor is it among their incoming requests');
select throws_ok(
  format('select public.friend_respond(%L, true)', current_setting('tests.dave_req')::jsonb ->> 'id'),
  'P0001', 'not_found', 'nor can they answer it by id');
select throws_ok($$select public.friend_request(tests.dave())$$, 'P0001', 'invalid',
  'the blocker cannot ask the person they blocked, as for an unknown user');
select is((select count(*)::int from public.search_users('dave')), 0, 'search still hides them from the blocker');
select ok(public.friend_code_resolve(current_setting('tests.dave_code')) is null,
  'and so does their code');
select is(jsonb_array_length(public.social_snapshot() -> 'blocks'), 1, 'the block list is unchanged');

-- friend: unaffected.
select tests.login(tests.bob());
select is((public.friend_request(tests.alice())).status, 'accepted', 'friend: a request to a friend is the friendship');

-- The sender withdraws: still nothing reaches the blocker.
select tests.login(tests.dave());
select lives_ok($$select public.friend_remove(tests.alice())$$, 'the blocked sender can withdraw the request');
select tests.logout();
select is(pg_temp.events(tests.alice(), 'friend.removed', tests.dave()), 0,
  'and the blocker hears nothing of the withdrawal');

-- An unblock clears a request that waited behind the block; to its sender it
-- reads as a decline.
select tests.login(tests.dave());
select public.friend_request(tests.alice());
select tests.login(tests.alice());
select lives_ok($$select public.unblock_user(tests.dave())$$, 'the blocker unblocks');
select tests.logout();
select is(
  (select count(*)::int from public.friendships where requester_id = tests.dave() and addressee_id = tests.alice()),
  0, 'the request that waited behind the block is gone');
select cmp_ok(pg_temp.events(tests.dave(), 'friend.removed', tests.alice()), '>', 0,
  'its sender hears friend.removed, as after a decline');
select tests.login(tests.dave());
select is((public.friend_request(tests.alice())).status, 'pending', 'after the unblock a new request is possible');
select tests.login(tests.alice());
select is(
  (select count(*)::int from jsonb_array_elements(public.social_snapshot() -> 'pending_in') e
   where e ->> 'user_id' = tests.dave()::text),
  1, 'and this one reaches the person asked');

-- ========================================== meet_completes_when_both_arrived

select tests.login(tests.alice());
select public.meet_propose('18000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('18000000-0000-4000-8000-000000000001', true, 900, 90);
select tests.logout();
delete from public.push_outbox;

select tests.set_clock('2026-01-12 18:01:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 0, 0, 0,
  'arrived', '2026-01-12 18:01:00+00');
select tests.login(tests.bob());
select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 300, 30, 800,
  'navigating', '2026-01-12 18:01:00+00');
select is((select status from public.meets where meet_id = '18000000-0000-4000-8000-000000000001'), 'active',
  'one skier arrived: the meet stays open');

select tests.set_clock('2026-01-12 18:02:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 60, 10, 40,
  'lost', '2026-01-12 18:02:00+00');
select tests.login(tests.bob());
select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 0, 0, 0,
  'arrived', '2026-01-12 18:02:00+00');
select is((select status from public.meets where meet_id = '18000000-0000-4000-8000-000000000001'), 'active',
  'what counts is each skier''s stored state: the first one wandered off');

select tests.set_clock('2026-01-12 18:03:00+00');
select tests.login(tests.alice());
select lives_ok(
  $$select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 0, 0, 0,
      'arrived', '2026-01-12 18:03:00+00')$$,
  'the second arrival is accepted');
select tests.logout();
select results_eq(
  $$select status, end_reason, ended_by, ended_at from public.meets
    where meet_id = '18000000-0000-4000-8000-000000000001'$$,
  $$values ('completed'::text, 'arrived'::text, tests.alice(), '2026-01-12 18:03:00+00'::timestamptz)$$,
  'meet_completes_when_both_arrived: completed as meet_end(arrived) does, recording who arrived last');
select results_eq(
  $$select user_id, payload ->> 'end_reason', payload ->> 'status' from public.push_outbox
    where kind = 'meet.ended' order by user_id$$,
  $$values (tests.alice(), 'arrived'::text, 'completed'::text), (tests.bob(), 'arrived'::text, 'completed'::text)$$,
  'both skiers get one meet.ended push saying they met up');
select is(
  (select count(*)::int from realtime.messages rm
   where rm.event = 'meet.updated' and rm.payload -> 'data' ->> 'status' = 'completed'
     and rm.payload -> 'data' ->> 'meet_id' = '18000000-0000-4000-8000-000000000001'
     and rm.topic in ('user:' || tests.alice()::text, 'user:' || tests.bob()::text)),
  2, 'and both phones get meet.updated');

select tests.set_clock('2026-01-12 18:04:00+00');
select tests.login(tests.bob());
select throws_ok(
  $$select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 0, 0, 0,
      'arrived', '2026-01-12 18:04:00+00')$$,
  'P0001', 'invalid_state', 'a later arrival fix finds the meet finished');
select is((public.meet_end('18000000-0000-4000-8000-000000000001', 'arrived')).status, 'completed',
  'and a tap on "we met up" returns the same row');
select tests.logout();
select is((select count(*)::int from public.push_outbox where kind = 'meet.ended'), 2,
  'the completion fired once: still one push each');

select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_progress_update('18000000-0000-4000-8000-000000000001', 0, 0, 0,
      'arrived', '2026-01-12 18:04:00+00')$$,
  'P0001', 'not_participant', 'stranger: cannot report arrival on someone else''s meet');

-- =================================================================== phone_hash

select tests.logout();
select hasnt_column('public', 'profiles', 'phone_hash', 'profiles has no phone_hash column');
select tests.login(tests.alice());
select is(
  (public.profile_update(jsonb_build_object('phone_hash', repeat('b', 64), 'ability', 'advanced'))).ability,
  'advanced', 'a patch from build 3.0.0 that still carries phone_hash applies, and the hash is ignored');
select lives_ok($$select public.profile_update('{"phone_hash": null}')$$, 'a phone_hash alone is ignored too');
select is((select count(*)::int from public.find_users(null, array[repeat('b', 64)])), 0,
  'find_users still takes phone hashes and matches none');
select results_eq(
  format('select id from public.find_users(array[%L], %L::text[])', current_setting('tests.alice_hash'), '{}'),
  $$select id from public.profiles where false$$, 'self: your own email never matches you');

-- ================================================================= apple_tokens

select tests.logout();
select ok((select relrowsecurity from pg_class where oid = 'public.apple_tokens'::regclass),
  'apple_tokens has row level security on');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'apple_tokens'), 0,
  'and no policy for any client role');
insert into public.apple_tokens (user_id, refresh_token)
values (tests.alice(), 'alice-refresh-token'), (tests.carol(), 'carol-refresh-token');
select tests.login(tests.alice());
select throws_ok($$select refresh_token from public.apple_tokens$$, '42501', null,
  'self: a user cannot read their own Apple token');
select throws_ok($$insert into public.apple_tokens (user_id, refresh_token) values (tests.alice(), 'x')$$,
  '42501', null, 'or write one');
select tests.login(tests.bob());
select throws_ok($$select user_id from public.apple_tokens$$, '42501', null, 'friend: cannot read it');
select tests.login(tests.carol());
select throws_ok($$select user_id from public.apple_tokens$$, '42501', null, 'stranger: cannot read it');
select tests.login(tests.dave());
select throws_ok($$select user_id from public.apple_tokens$$, '42501', null, 'blocked: cannot read it');
select tests.login_anon();
select throws_ok($$select user_id from public.apple_tokens$$, '42501', null, 'anon: cannot read it');

-- ===================== reports_hold_no_deleted_account, realtime_forgets_deleted_user

-- carol: friends with erin, in a live meet with her, broadcasting a position
-- to her, reported by alice and erin, and the author of a report on alice.
select tests.logout();
select tests.set_clock('2026-01-12 19:00:00+00');
select tests.befriend(tests.carol(), tests.erin());
update public.profiles set current_resort_id = 'whistler-blackcomb', avatar_url = tests.carol()::text || '/me.jpg'
where id = tests.carol();
update public.profiles set current_resort_id = 'whistler-blackcomb' where id = tests.erin();
select tests.login(tests.carol());
select public.meet_propose('18000000-0000-4000-8000-000000000002', tests.erin(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.erin());
select public.meet_respond('18000000-0000-4000-8000-000000000002', true, 900, 90);
select tests.login(tests.carol());
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-12 19:00:00+00');
select public.report_user(tests.alice(), 'other', 'Asked me to meet at the lodge', 'request');
select tests.login(tests.alice());
select public.report_user(tests.carol(), 'harassment', 'Carol keeps messaging me', 'request');
select tests.login(tests.erin());
select public.report_user(tests.carol(), 'inappropriate_photo', null, 'friend');

select tests.logout();
select is((select count(*)::int from public.user_reports where reported_id = tests.carol()), 2,
  'before the delete, two reports hold carol''s name and photo');
select cmp_ok(
  (select count(*)::int from realtime.messages
   where topic = 'user:' || tests.erin()::text and payload::text like '%' || tests.carol()::text || '%'),
  '>', 1, 'and erin''s topic holds several messages naming carol');

select tests.login(tests.carol());
select lives_ok($$select public.account_delete()$$, 'account_delete succeeds');
select tests.logout();

-- Reports.
select is(
  (select count(*)::int from public.user_reports
   where reported_name = 'Carol' or reported_avatar_url like tests.carol()::text || '%'
      or note like '%Carol%' or reported_id is null),
  0, 'reports_hold_no_deleted_account: no report keeps the deleted user''s name, photo or a note about them');
select results_eq(
  $$select reporter_id, reported_id, reported_name, note from public.user_reports$$,
  $$values (null::uuid, tests.alice(), 'Alice'::text, 'Asked me to meet at the lodge'::text)$$,
  'a report the deleted user filed stays, without their id');

-- Realtime.
select is(
  (select count(*)::int from realtime.messages
   where payload::text like '%' || tests.carol()::text || '%'
     and event not in ('meet.updated', 'friend.removed')),
  0, 'realtime_forgets_deleted_user: no older message names the deleted user (requests, presence, proposals)');
select is(
  (select count(*)::int from realtime.messages
   where event = 'meet.updated' and payload::text like '%' || tests.carol()::text || '%'
     and payload -> 'data' ->> 'status' <> 'invalidated'),
  0, 'not even an older meet update');
select is((select count(*)::int from realtime.messages where topic = 'user:' || tests.carol()::text), 0,
  'and nothing is left on the deleted user''s own topic');
select is(
  (select count(*)::int from realtime.messages
   where payload::text like '%Carol%' or payload::text like '%' || tests.carol()::text || '/me.jpg%'),
  0, 'no message carries the deleted user''s name or photo');
select results_eq(
  $$select payload -> 'data' ->> 'status', payload -> 'data' ->> 'end_reason' from realtime.messages
    where topic = 'user:' || tests.erin()::text and event = 'meet.updated'$$,
  $$values ('invalidated'::text, 'partner_left'::text)$$,
  'the partner''s meet.updated from the delete survives');
select results_eq(
  $$select payload -> 'data' ->> 'user_id', payload -> 'data' ? 'friendship_id',
           payload -> 'data' ?| array['display_name', 'avatar_url']
    from realtime.messages where topic = 'user:' || tests.erin()::text and event = 'friend.removed'$$,
  $$values (tests.carol()::text, true, false)$$,
  'and so does her friend.removed, with the id and no name or photo');
select cmp_ok(pg_temp.events(tests.alice(), 'friend.accepted', tests.bob()), '>', 0,
  'other people''s messages stay');

-- The Apple token goes with the account.
select is((select count(*)::int from public.apple_tokens where user_id = tests.carol()), 0,
  'the deleted user''s Apple token is gone');
select is((select count(*)::int from public.apple_tokens where user_id = tests.alice()), 1,
  'another user''s stays');

select * from finish();
rollback;
