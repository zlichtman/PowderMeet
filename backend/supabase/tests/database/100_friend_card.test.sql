-- The friend card fields in social_snapshot() (migration 0016), as self,
-- friend, stranger and blocked. Rules out: a stranger learning someone's gear,
-- stats or whereabouts by sending them a friend request, a blocked friend
-- staying on the list, coordinates in the snapshot, and one malformed descent
-- breaking a friend's whole snapshot.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
-- carol asks alice, alice asks erin: pending both ways, strangers still.
insert into public.friendships (requester_id, addressee_id, status) values
  (tests.carol(), tests.alice(), 'pending'),
  (tests.alice(), tests.erin(), 'pending');

update public.profiles
set ability = 'expert',
    equipment = '{"discipline": "ski", "type": "freeride", "length_cm": 184, "waist_mm": 110, "ski": "atomic-bent-110"}'
where id in (tests.bob(), tests.carol(), tests.dave(), tests.erin());

-- bob: two runs on one day, one with no average speed; one run with garbage
-- stats that must be skipped, not fail the snapshot.
insert into public.descents (owner_id, source, started_at, ended_at, content_hash, track, stats) values
  (tests.bob(), 'gpx', '2026-01-09 17:00+00', '2026-01-09 17:10+00', repeat('1', 64), 'x',
   '{"distance_m": 3000, "vertical_m": 600, "top_speed_ms": 20, "avg_speed_ms": 10,
     "resort_name": "Whistler Blackcomb", "local_day": "2026-01-09"}'),
  (tests.bob(), 'gpx', '2026-01-09 18:00+00', '2026-01-09 18:05+00', repeat('2', 64), 'x',
   '{"distance_m": 1500, "vertical_m": 300, "top_speed_ms": 25,
     "resort_name": "Whistler Blackcomb", "local_day": "2026-01-09"}'),
  (tests.bob(), 'gpx', '2026-01-08 18:00+00', '2026-01-08 18:05+00', repeat('3', 64), 'x',
   '{"distance_m": "far", "vertical_m": 1e400, "top_speed_ms": [1], "local_day": 7}'),
  (tests.carol(), 'gpx', '2026-01-09 17:00+00', '2026-01-09 17:10+00', repeat('4', 64), 'x',
   '{"distance_m": 9999, "vertical_m": 999}');

-- Fresh presence for bob; carol and dave stand there too.
insert into public.presence (user_id, resort_id, lon, lat, captured_at, received_at) values
  (tests.bob(), 'whistler-blackcomb', -122.95, 50.09, '2026-01-10 17:58+00', '2026-01-10 17:58+00'),
  (tests.carol(), 'whistler-blackcomb', -122.95, 50.09, '2026-01-10 17:59+00', '2026-01-10 17:59+00'),
  (tests.dave(), 'whistler-blackcomb', -122.95, 50.09, '2026-01-10 17:59+00', '2026-01-10 17:59+00');

-- --------------------------------------------------------------- friend
select tests.login(tests.alice());
select set_config('tests.snapshot', public.social_snapshot()::text, true);

select is(jsonb_array_length(current_setting('tests.snapshot')::jsonb -> 'friends'), 1,
  'friends lists bob only: dave is blocked, carol and erin are pending');
select is(current_setting('tests.snapshot')::jsonb #>> '{friends,0,display_name}', 'Bob', 'the friend is bob');
select is(current_setting('tests.snapshot')::jsonb #>> '{friends,0,ability}', 'expert',
  'a friend entry carries their ability');
select is(current_setting('tests.snapshot')::jsonb #>> '{friends,0,equipment,ski}', 'atomic-bent-110',
  'and their equipment');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,runs}')::int, 3,
  'stats count every descent, the malformed one included');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,days}')::int, 2,
  'days are counted per resort and ski day');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,distance_m}')::numeric, 4500::numeric,
  'distance is summed, skipping a value that is not a number');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,vertical_m}')::numeric, 900::numeric,
  'vertical is summed, skipping an out-of-range number');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,top_speed_ms}')::numeric, 25::numeric,
  'top speed is the highest');
-- (3000 + 1500) m over (3000 / 10 + 300) s of moving time = 7.5 m/s.
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,stats,avg_speed_ms}')::numeric, 7.5::numeric,
  'average speed is distance over moving time, as the phone computes its own');
select is(current_setting('tests.snapshot')::jsonb #>> '{friends,0,last_seen,resort_id}', 'whistler-blackcomb',
  'a fresh position gives the resort');
select is((current_setting('tests.snapshot')::jsonb #>> '{friends,0,last_seen,at}')::timestamptz,
  '2026-01-10 17:58+00'::timestamptz, 'and when');
select ok(not (current_setting('tests.snapshot')::jsonb #> '{friends,0,last_seen}' ? 'lat')
          and not (current_setting('tests.snapshot')::jsonb #> '{friends,0,last_seen}' ? 'lon'),
  'the snapshot carries no coordinates');

-- --------------------------------------------- strangers and the blocked
select ok(not exists (
    select 1 from jsonb_array_elements(
      (current_setting('tests.snapshot')::jsonb -> 'pending_in')
      || (current_setting('tests.snapshot')::jsonb -> 'pending_out')
      || (current_setting('tests.snapshot')::jsonb -> 'blocks')) e
    where e ? 'stats' or e ? 'equipment' or e ? 'ability' or e ? 'last_seen'),
  'stranger_gets_no_friend_card_fields: a pending request in either direction, and a block, carry no card fields');
select is(jsonb_array_length(current_setting('tests.snapshot')::jsonb -> 'pending_in'), 1,
  'carol''s request is listed');
select is(jsonb_array_length(current_setting('tests.snapshot')::jsonb -> 'blocks'), 1, 'dave is listed as blocked');

-- The other side of the pending request sees no more of alice than her name.
select tests.logout();
update public.profiles set ability = 'advanced', equipment = '{"discipline": "snowboard", "type": "park"}'
where id = tests.alice();
insert into public.presence (user_id, resort_id, lon, lat, captured_at, received_at)
values (tests.alice(), 'whistler-blackcomb', -122.95, 50.09, '2026-01-10 17:59+00', '2026-01-10 17:59+00');
select tests.login(tests.carol());
select is(jsonb_array_length(public.social_snapshot() -> 'friends'), 0, 'a stranger has no friends entry for alice');
select ok(not (public.social_snapshot() #> '{pending_out,0}' ? 'stats'),
  'and her sent request shows no stats');

-- The blocked friend: no entry, and nothing about alice's whereabouts.
select tests.login(tests.dave());
select is(jsonb_array_length(public.social_snapshot() -> 'friends'), 0,
  'blocked_friend_not_listed: a friendship row under a block gives the blocked user no friend entry');

-- --------------------------------------------------------------- self
select tests.login(tests.bob());
select is(jsonb_array_length(public.social_snapshot() -> 'friends'), 1, 'bob sees alice as a friend');
select is(public.social_snapshot() #>> '{friends,0,ability}', 'advanced', 'with her ability');
select is((public.social_snapshot() #>> '{friends,0,stats,runs}')::int, 0, 'a friend with no runs has zero runs');
select ok(public.social_snapshot() #> '{friends,0,stats,top_speed_ms}' = 'null'::jsonb,
  'and no top speed rather than zero');

-- ------------------------------------------------------------- staleness
select tests.set_clock('2026-01-10 18:20:00+00');
select tests.login(tests.alice());
select ok(public.social_snapshot() #> '{friends,0,last_seen}' = 'null'::jsonb,
  'a position older than the 15 minute presence TTL is not reported');

select tests.login_anon();
select throws_ok($$select public.lifetime_stats(tests.bob())$$, '42501', null,
  'the stats helper is not callable by clients');
select tests.login(tests.carol());
select throws_ok($$select public.lifetime_stats(tests.bob())$$, '42501', null,
  'not even by a signed-in user');

select * from finish();
rollback;
