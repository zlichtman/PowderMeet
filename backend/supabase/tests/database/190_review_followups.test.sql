-- The follow-ups in migration 0026, and the privacy cases the review found
-- missing.
-- Rules out: one account growing the descent tables without bound
-- (descent_upsert_rate_limited), a friend reading the last resort after the
-- skier signed out (presence_clear_forgets_resort), a partner reading the
-- other side's ETA after the meet ended, a block among them
-- (ended_meet_progress_private), a photo written, replaced, removed or listed
-- in someone else's avatar folder (avatar_folder_is_the_owners), a friend,
-- blocked user or stranger joining another user's topic, events reaching
-- anyone but their recipients (events_reach_only_recipients), and a deleted
-- account leaving presence, runs, tokens, blocks, pushes or an open meet
-- behind (account_delete_leaves_nothing), the partner of a deleted account not
-- told why the meet ended or the name kept once told (partner_learns_why), and
-- search reading every profile (search_name_indexed).
begin;
select no_plan();

select tests.set_clock('2026-01-14 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());

-- One valid descent: a distinct hash and a five-minute slot per number.
create function pg_temp.run(p_n int) returns jsonb language sql as $$
  select jsonb_build_object(
    'content_hash', encode(sha256(convert_to('run-' || p_n, 'UTF8')), 'hex'),
    'source', 'gpx',
    'started_at', '2026-01-01 08:00:00+00'::timestamptz + p_n * interval '10 minutes',
    'ended_at', '2026-01-01 08:05:00+00'::timestamptz + p_n * interval '10 minutes',
    'track', 'AQ==');
$$;

-- Topics holding events of one kind whose data names one user.
create function pg_temp.topics(p_type text, p_about uuid) returns text[] language sql as $$
  select coalesce(array_agg(distinct rm.topic order by rm.topic), '{}')
  from realtime.messages rm
  where rm.event = p_type and rm.payload -> 'data' ->> 'user_id' = p_about::text;
$$;

-- ================================================== descent_upsert_rate_limited

select tests.login(tests.alice());
do $$
begin
  for i in 1 .. 120 loop
    perform public.descent_upsert(pg_temp.run(i));
  end loop;
end;
$$;
select tests.logout();
select is((select count(*)::int from public.descents where owner_id = tests.alice()), 120,
  'self: 120 runs in a minute are stored');
select tests.login(tests.alice());
select throws_ok($$select public.descent_upsert(pg_temp.run(121))$$, 'P0001', 'rate_limited',
  'descent_upsert_rate_limited: the 121st call in the minute is refused as "try later"');
select throws_ok($$select public.descent_upsert(pg_temp.run(1))$$, 'P0001', 'rate_limited',
  'a repeat counts toward the minute too');
select tests.login(tests.bob());
select is((select created from public.descent_upsert(pg_temp.run(121))), true,
  'friend: the limit is per account');

select tests.set_clock('2026-01-14 18:01:00+00');
select tests.logout();
insert into public.rate_limits (user_id, bucket, window_start, count)
values (tests.alice(), 'descent_new', date_bin(interval '1 day', public.clock(), timestamptz '2000-01-01 00:00:00+00'), 1000)
on conflict (user_id, bucket, window_start) do update set count = excluded.count;
select tests.login(tests.alice());
select throws_ok($$select public.descent_upsert(pg_temp.run(122))$$, 'P0001', 'rate_limited',
  'descent_upsert_rate_limited: a new run past 1,000 in the day is refused');
select is((select created from public.descent_upsert(pg_temp.run(1) || '{"stats": {"runs": 1}}')), false,
  'while a run already stored is still accepted, so a re-match is not held up');
select tests.logout();
select is((select count(*)::int from public.descents where owner_id = tests.alice()), 120,
  'and nothing new was stored');

-- =============================================== presence_clear_forgets_resort

select tests.login(tests.alice());
select public.profile_update('{"current_resort_id": "whistler-blackcomb"}');
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-14 18:01:00+00');
select tests.login(tests.bob());
select is((select current_resort_id from public.profiles where id = tests.alice()), 'whistler-blackcomb',
  'friend: reads the resort while the skier is there');
select lives_ok($$select public.presence_clear()$$, 'friend: clearing their own presence');
select tests.login(tests.carol());
select public.presence_clear();
select tests.login(tests.dave());
select public.presence_clear();
select tests.logout();
select is((select current_resort_id from public.profiles where id = tests.alice()), 'whistler-blackcomb',
  'friend, stranger or blocked clearing leaves someone else''s resort alone');
select ok(tests.alice() in (select public.presence_recipients(tests.bob(), 'whistler-blackcomb')),
  'before the clear, the friend''s positions reach her');

select tests.login(tests.alice());
select lives_ok($$select public.presence_clear()$$, 'self: clears presence');
select is((select current_resort_id from public.profiles where id = tests.alice()), null,
  'self: the resort is cleared with it');
select tests.login(tests.bob());
select is((select current_resort_id from public.profiles where id = tests.alice()), null,
  'presence_clear_forgets_resort: a friend reads no resort after the clear');
select tests.login(tests.carol());
select is((select count(*)::int from public.profiles where id = tests.alice()), 0, 'stranger: reads no profile at all');
select tests.login(tests.dave());
select is((select count(*)::int from public.profiles where id = tests.alice()), 0, 'blocked: reads no profile at all');
select tests.logout();
select ok(tests.alice() not in (select public.presence_recipients(tests.bob(), 'whistler-blackcomb')),
  'and friends'' positions stop going to her');

-- ================================================ ended_meet_progress_private

-- A meet that ends the ordinary way.
select tests.login(tests.alice());
select public.meet_propose('19000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('19000000-0000-4000-8000-000000000001', true, 900, 90);
select public.meet_progress_update('19000000-0000-4000-8000-000000000001', 800, 80, 2400,
  'navigating', '2026-01-14 18:01:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('19000000-0000-4000-8000-000000000001', 500, 50, 1500,
  'navigating', '2026-01-14 18:01:00+00');
select is((select count(*)::int from public.meet_progress where meet_id = '19000000-0000-4000-8000-000000000001'), 2,
  'friend in a live meet: reads both rows');
select tests.login(tests.carol());
select is((select count(*)::int from public.meet_progress), 0, 'stranger: reads none');
select tests.login(tests.dave());
select is((select count(*)::int from public.meet_progress), 0, 'blocked: reads none');

select tests.login(tests.bob());
select public.meet_end('19000000-0000-4000-8000-000000000001', 'partner_left');
select results_eq(
  $$select user_id from public.meet_progress where meet_id = '19000000-0000-4000-8000-000000000001'$$,
  $$values (tests.bob())$$, 'after an ordinary ending each side reads only their own row');
select tests.login(tests.alice());
select results_eq(
  $$select user_id from public.meet_progress where meet_id = '19000000-0000-4000-8000-000000000001'$$,
  $$values (tests.alice())$$, 'on both sides');

-- The same, ended by a block.
select public.meet_propose('19000000-0000-4000-8000-000000000002', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('19000000-0000-4000-8000-000000000002', true, 900, 90);
select public.meet_progress_update('19000000-0000-4000-8000-000000000002', 700, 70, 2000,
  'navigating', '2026-01-14 18:01:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('19000000-0000-4000-8000-000000000002', 400, 40, 1200,
  'navigating', '2026-01-14 18:01:00+00');
select public.block_user(tests.bob());
select tests.login(tests.bob());
select results_eq(
  $$select user_id from public.meet_progress where meet_id = '19000000-0000-4000-8000-000000000002'$$,
  $$values (tests.bob())$$,
  'ended_meet_progress_private: the blocked partner reads only their own row, as after any ending');
select is((select status from public.meets where meet_id = '19000000-0000-4000-8000-000000000002'), 'invalidated',
  'and the meet reads as ended, like any other');
select tests.login(tests.alice());
select results_eq(
  $$select user_id from public.meet_progress where meet_id = '19000000-0000-4000-8000-000000000002'$$,
  $$values (tests.alice())$$, 'the blocker reads only their own row too');
select tests.login(tests.alice());
select public.unblock_user(tests.bob());
select tests.logout();
select tests.befriend(tests.alice(), tests.bob());

-- ================================================= avatar_folder_is_the_owners

select tests.login(tests.alice());
select lives_ok(
  format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, tests.alice()::text || '/me.jpg'),
  'self: may upload into their own folder');
select is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 1,
  'self: and list it');
select lives_ok(
  format($$update storage.objects set name = %L where bucket_id = 'avatars' and name = %L$$,
         tests.alice()::text || '/me2.jpg', tests.alice()::text || '/me.jpg'),
  'self: and replace it');
select throws_ok(
  format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, tests.bob()::text || '/me.jpg'),
  '42501', null, 'self: may not upload into a friend''s folder');
select throws_ok(
  format($$update storage.objects set name = %L where bucket_id = 'avatars' and name = %L$$,
         tests.bob()::text || '/me2.jpg', tests.alice()::text || '/me2.jpg'),
  '42501', null, 'self: nor move their photo into someone else''s folder');

-- friend, stranger and blocked: none can list, replace, move or remove it.
do $$
declare
  v_user uuid;
  v_label text;
  v_seen int;
begin
  foreach v_user in array array[tests.bob(), tests.carol(), tests.dave()] loop
    v_label := case v_user when tests.bob() then 'friend' when tests.carol() then 'stranger' else 'blocked' end;
    perform tests.login(v_user);
    select count(*)::int into v_seen from storage.objects where bucket_id = 'avatars';
    perform set_config('tests.seen_' || v_label, v_seen::text, true);
    begin
      update storage.objects set name = v_user::text || '/taken.jpg'
      where bucket_id = 'avatars' and name = tests.alice()::text || '/me2.jpg';
    exception when others then
      null;
    end;
    begin
      delete from storage.objects where bucket_id = 'avatars' and name = tests.alice()::text || '/me2.jpg';
    exception when others then
      null;
    end;
    begin
      insert into storage.objects (bucket_id, name) values ('avatars', tests.alice()::text || '/planted.jpg');
      perform set_config('tests.planted_' || v_label, 'yes', true);
    exception when others then
      perform set_config('tests.planted_' || v_label, 'no', true);
    end;
  end loop;
  perform tests.logout();
end;
$$;
select is(current_setting('tests.seen_friend')::int, 0, 'friend: cannot list someone else''s folder');
select is(current_setting('tests.seen_stranger')::int, 0, 'stranger: cannot list it');
select is(current_setting('tests.seen_blocked')::int, 0, 'blocked: cannot list it');
select is(current_setting('tests.planted_friend'), 'no', 'friend: cannot upload into it');
select is(current_setting('tests.planted_stranger'), 'no', 'stranger: cannot upload into it');
select is(current_setting('tests.planted_blocked'), 'no', 'blocked: cannot upload into it');
select tests.logout();
select results_eq(
  $$select name from storage.objects where bucket_id = 'avatars'$$,
  $$values (tests.alice()::text || '/me2.jpg')$$,
  'avatar_folder_is_the_owners: after all of it, the owner''s photo is unchanged and nothing was added');

select tests.login_anon();
select throws_ok(
  format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, tests.alice()::text || '/anon.jpg'),
  '42501', null, 'anon: cannot upload at all');

-- ============================================================ realtime topics

select tests.logout();
select public.emit('user:' || tests.alice()::text, 'presence', '{"probe": true}'::jsonb);
select set_config('realtime.topic', 'user:' || tests.alice()::text, true);
select tests.login(tests.alice());
select cmp_ok((select count(*)::int from realtime.messages), '>', 0, 'self: may join their own topic');
select tests.login(tests.bob());
select is((select count(*)::int from realtime.messages), 0, 'friend_cannot_subscribe_to_user_topic');
select tests.login(tests.dave());
select is((select count(*)::int from realtime.messages), 0, 'blocked_cannot_subscribe_to_user_topic');
select tests.login(tests.carol());
select is((select count(*)::int from realtime.messages), 0, 'stranger: neither');

select tests.logout();
select public.emit('resort:whistler-blackcomb', 'resort.status', '{"probe": true}'::jsonb);
select set_config('realtime.topic', 'resort:whistler-blackcomb', true);
select tests.login(tests.carol());
select cmp_ok((select count(*)::int from realtime.messages), '>', 0, 'any signed-in skier may join a resort topic');
select tests.login_anon();
do $$
declare
  v_rows int := 0;
begin
  begin
    execute 'select count(*) from realtime.messages' into v_rows;
  exception when others then
    v_rows := 0;
  end;
  perform set_config('tests.anon_resort_rows', v_rows::text, true);
end;
$$;
select tests.logout();
select set_config('realtime.topic', '', true);
select is(current_setting('tests.anon_resort_rows')::int, 0, 'a signed-out client may not join even a resort topic');

-- ============================================== events_reach_only_recipients

-- bob (friend), carol (stranger) and dave (blocked) all have whistler open.
update public.profiles set current_resort_id = 'whistler-blackcomb'
where id in (tests.bob(), tests.carol(), tests.dave());
select tests.set_clock('2026-01-14 18:02:00+00');
select tests.login(tests.alice());
select public.presence_update('whistler-blackcomb', -122.94, 50.08, 5, 3, 90, '2026-01-14 18:02:00+00');
select tests.logout();
select is(pg_temp.topics('presence', tests.alice()), array['user:' || tests.bob()::text],
  'events_reach_only_recipients: a position goes to the friend only, not the stranger or the blocked friend');

select tests.login(tests.alice());
select public.meet_propose('19000000-0000-4000-8000-000000000003', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('19000000-0000-4000-8000-000000000003', true, 900, 90);
select tests.login(tests.alice());
select public.meet_progress_update('19000000-0000-4000-8000-000000000003', 300, 30, 900,
  'navigating', '2026-01-14 18:02:00+00');
select tests.logout();
select is(pg_temp.topics('meet.progress', tests.alice()), array['user:' || tests.bob()::text],
  'progress goes to the partner only');
select is(
  (select coalesce(array_agg(distinct rm.topic order by rm.topic), '{}') from realtime.messages rm
   where rm.event = 'meet.updated' and rm.payload -> 'data' ->> 'meet_id' = '19000000-0000-4000-8000-000000000003'),
  (select array_agg(t order by t) from unnest(array['user:' || tests.alice()::text, 'user:' || tests.bob()::text]) t),
  'meet updates go to the two participants only');

select tests.login(tests.alice());
select public.block_user(tests.bob());
select tests.logout();
select is(
  (select count(*)::int from realtime.messages rm
   where rm.event in ('friend.removed', 'meet.updated')
     and rm.topic not in ('user:' || tests.alice()::text, 'user:' || tests.bob()::text)),
  0, 'a block tells nobody but the two people in it');

-- ===================================================== search_name_indexed

select tests.logout();
select is(
  (select indexdef ~ 'gin_trgm_ops' and indexdef ~ 'search_name' from pg_indexes
   where schemaname = 'public' and indexname = 'profiles_search_name_trgm'),
  true, 'search_name_indexed: names are searched through a trigram index');
select is((select search_name from public.profiles where id = tests.dave()), 'dave',
  'the stored search name is the normalised, lower-case name');
select tests.login(tests.dave());
select public.profile_update('{"display_name": "Davey  Jones"}');
select tests.logout();
select is((select search_name from public.profiles where id = tests.dave()), 'davey jones',
  'and follows a rename');
select tests.login(tests.carol());
select throws_ok($$select search_name from public.profiles where id = tests.carol()$$, '42501', null,
  'self: not readable through the API, like the other derived columns');
select results_eq($$select user_id, relation from public.search_users('JONES')$$,
  $$values (tests.dave(), 'none'::text)$$, 'stranger: found by a word inside the name, any case');
select is((select count(*)::int from public.search_users('j')), 0, 'a one-letter query still finds nothing');
select tests.login(tests.alice());
select is((select count(*)::int from public.search_users('jones')), 0,
  'someone you blocked stays out of your results');
select tests.login(tests.dave());
select is((select user_id from public.search_users('alic')), tests.alice(),
  'while the blocker turns up for the person blocked, as for anyone (0025)');

-- ============================================== account_delete_leaves_nothing

-- erin: friends with carol and in a meet with her, broadcasting, with a run,
-- a phone, queued pushes, a block she made and one made against her.
select tests.logout();
select tests.set_clock('2026-01-14 19:00:00+00');
select tests.befriend(tests.erin(), tests.carol());
update public.profiles set current_resort_id = 'whistler-blackcomb' where id = tests.erin();
insert into public.device_tokens (user_id, token, environment)
values (tests.erin(), repeat('e1', 32), 'development'), (tests.carol(), repeat('c2', 32), 'development');
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.erin());
select tests.login(tests.erin());
select public.block_user(tests.dave());
select public.meet_propose('19000000-0000-4000-8000-000000000004', tests.carol(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-14 19:00:00+00');
select public.descent_upsert(pg_temp.run(500));
select tests.logout();
insert into public.push_outbox (user_id, kind, payload, created_at)
values (tests.erin(), 'friend.accepted', '{}', public.clock());

select ok(
  (select count(*) from public.presence where user_id = tests.erin()) = 1
  and (select count(*) from public.descents where owner_id = tests.erin()) = 1
  and (select count(*) from public.device_tokens where user_id = tests.erin()) = 1
  and (select count(*) from public.user_blocks where tests.erin() in (blocker_id, blocked_id)) = 2
  and (select count(*) from public.push_outbox where user_id = tests.erin()) >= 1
  and (select status from public.meets where meet_id = '19000000-0000-4000-8000-000000000004') = 'proposed',
  'before the delete, erin has presence, a run, a phone, two blocks, a push and an open meet');

select tests.login(tests.erin());
select lives_ok($$select public.account_delete()$$, 'account_delete succeeds');
select tests.logout();
select is((select count(*)::int from public.presence where user_id = tests.erin()), 0,
  'account_delete_leaves_nothing: no presence');
select is((select count(*)::int from public.descents where owner_id = tests.erin()), 0, 'no runs');
select is((select count(*)::int from public.device_tokens where user_id = tests.erin()), 0, 'no device token');
select is((select count(*)::int from public.user_blocks where tests.erin() in (blocker_id, blocked_id)), 0,
  'no block, made or received');
select is((select count(*)::int from public.push_outbox where user_id = tests.erin()), 0, 'no queued push');
select is((select count(*)::int from public.meets where tests.erin() in (proposer_id, invitee_id)), 0,
  'no meet');
select results_eq(
  $$select rm.payload -> 'data' ->> 'status', rm.payload -> 'data' ->> 'end_reason' from realtime.messages rm
    where rm.topic = 'user:' || tests.carol()::text and rm.event = 'meet.updated'
      and rm.payload -> 'data' ->> 'meet_id' = '19000000-0000-4000-8000-000000000004'$$,
  $$values ('invalidated'::text, 'partner_left'::text)$$,
  'and the partner''s phone was told the meet ended because she left');
select results_eq(
  $$select payload ->> 'end_reason', payload ->> 'partner_name', payload ? 'partner_id', sent_at is null
    from public.push_outbox
    where user_id = tests.carol() and kind = 'meet.ended'
      and payload ->> 'meet_id' = '19000000-0000-4000-8000-000000000004'$$,
  $$values ('partner_left'::text, 'Erin'::text, false, true)$$,
  'partner_learns_why: the partner''s push says "Meet ended: Erin left", with no id');
select is(
  (select count(*)::int from public.push_outbox
   where user_id = tests.carol() and payload::text like '%' || tests.erin()::text || '%'),
  0, 'and no push left to the partner holds the deleted user''s id');
select public.push_outbox_complete(
  (select id from public.push_outbox where user_id = tests.carol() and kind = 'meet.ended'));
select results_eq(
  $$select payload ? 'partner_name', payload ->> 'end_reason', sent_at is not null
    from public.push_outbox where user_id = tests.carol() and kind = 'meet.ended'$$,
  $$values (false, 'partner_left'::text, true)$$,
  'once sent, the push forgets the name');

select * from finish();
rollback;
