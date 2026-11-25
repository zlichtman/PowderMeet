-- The server pace model (0015, specs/08-ACTIVITY.md section 4.2): the queued
-- `pace_recompute` job is consumed, the factors come out of a fixture within
-- tolerance, a repeat changes nothing, deleting the runs removes the model,
-- and only the owner and accepted friends can read it. Raw descents and
-- observations stay owner-only.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:30:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
update public.profiles set baseline_speeds = '{"blue": 5, "black": 4}' where id = tests.alice();

-- One run over three blue edges at 10 m/s (twice alice's blue baseline), one
-- of them with a 30 s stop, plus an edge the phone could not grade. Kept in a
-- setting so the signed-in role can read it without access to `tests`.
select set_config('tests.alice_run', jsonb_build_object(
    'source', 'live', 'started_at', '2026-01-10T18:00:00Z', 'ended_at', '2026-01-10T18:02:00Z',
    'content_hash', repeat('7', 64), 'track', encode('live-track'::bytea, 'base64'),
    'resort_id', 'whistler-blackcomb',
    'match', jsonb_build_object('bundle_id', repeat('a', 64), 'matcher_version', 1,
      'coverage', 0.9, 'confidence', 0.8,
      'matched', jsonb_build_array(
        jsonb_build_object('edge_id', 'e1', 'enter_at', '2026-01-10T18:00:00Z', 'exit_at', '2026-01-10T18:00:10Z',
                           'moving_s', 10, 'length_m', 100, 'difficulty', 'blue'),
        jsonb_build_object('edge_id', 'e2', 'enter_at', '2026-01-10T18:00:10Z', 'exit_at', '2026-01-10T18:00:50Z',
                           'moving_s', 10, 'length_m', 100, 'difficulty', 'blue'),
        jsonb_build_object('edge_id', 'e3', 'enter_at', '2026-01-10T18:00:50Z', 'exit_at', '2026-01-10T18:01:00Z',
                           'moving_s', 10, 'length_m', 100, 'difficulty', 'blue'),
        jsonb_build_object('edge_id', 'e4', 'enter_at', '2026-01-10T18:01:00Z', 'exit_at', '2026-01-10T18:01:30Z',
                           'moving_s', 30, 'length_m', 300))))::text, true);

select tests.login(tests.alice());
select results_eq($$select created from public.descent_upsert(current_setting('tests.alice_run')::jsonb)$$,
  $$values (true)$$, 'a live descent with graded edges is stored');
select is((select count(*)::int from public.pace_observations where difficulty = 'blue'), 3,
  'each matched edge keeps the difficulty the phone sent');
select is((select count(*)::int from public.pace_observations where difficulty is null), 1,
  'an edge without a difficulty is stored without one');
select throws_ok($$select public.pace_recompute_drain()$$, '42501', null,
  'a client cannot run the pace consumer');
select throws_ok($$select public.pace_recompute(tests.alice())$$, '42501', null,
  'a client cannot recompute anyone''s pace');

select tests.logout();
select is((select count(*)::int from public.jobs where kind = 'pace_recompute' and owner_id = tests.alice()), 1,
  'the upsert queued one pace_recompute job');
select is(public.pace_recompute_drain(), 1, 'the consumer runs the job');
select is((select count(*)::int from public.jobs where kind = 'pace_recompute'), 0, 'and removes it');

-- blue: (3 * 2.0 + 8) / (3 + 8) = 1.273
-- e1: ratio 2.0 / 1.273 = 1.571, shrunk (1.571 + 5) / 6 = 1.095
-- stops: 1 stop in 0.3 km = 3.33 per km over 1 descent, (3.33 + 10 * 0.4) / 11 = 0.667
select ok(abs((select (difficulty_factor ->> 'blue')::numeric from public.pace_models where owner_id = tests.alice()) - 1.273) < 0.002,
  'difficulty_factor is the shrunk ratio to the owner''s baseline');
select ok(abs((select (edge_factor ->> 'e1')::numeric from public.pace_models where owner_id = tests.alice()) - 1.095) < 0.002,
  'edge_factor is the shrunk ratio to the difficulty estimate');
select ok(abs((select stops_per_km from public.pace_models where owner_id = tests.alice())::numeric - 0.667) < 0.002,
  'stops_per_km is shrunk toward the default rate');
select is((select n_descents from public.pace_models where owner_id = tests.alice()), 1, 'one descent taught it');
select ok(not ((select difficulty_factor from public.pace_models where owner_id = tests.alice()) ? 'black'),
  'a difficulty with no runs gets no factor');
select ok(not ((select edge_factor from public.pace_models where owner_id = tests.alice()) ? 'e4'),
  'an ungraded edge is left out');

-- Idempotent: the same run again leaves the model where it was.
select tests.login(tests.alice());
select results_eq($$select created from public.descent_upsert(current_setting('tests.alice_run')::jsonb)$$,
  $$values (false)$$, 'the same run again is the same descent');
select tests.logout();
select is(public.pace_recompute_drain(), 1, 'the repeat queued one more job');
select ok(abs((select (difficulty_factor ->> 'blue')::numeric from public.pace_models where owner_id = tests.alice()) - 1.273) < 0.002,
  'and the model is unchanged');

-- A new baseline (the phone's recalibration, an ability change) queues a
-- recompute, so the factors are never measured against the old one.
select tests.login(tests.alice());
select public.profile_update('{"baseline_speeds": {"blue": 6, "black": 4}}'::jsonb);
select tests.logout();
select is((select count(*)::int from public.jobs where kind = 'pace_recompute' and owner_id = tests.alice()), 1,
  'changing baseline_speeds queues a recompute');
select is(public.pace_recompute_drain(), 1, 'which runs');
-- blue against 6: ratio 10/6 = 1.667, (3 * 1.667 + 8) / 11 = 1.182
select ok(abs((select (difficulty_factor ->> 'blue')::numeric from public.pace_models where owner_id = tests.alice()) - 1.182) < 0.002,
  'and measures against the new baseline');
update public.profiles set baseline_speeds = '{"blue": 5, "black": 4}' where id = tests.alice();
select public.pace_recompute_drain();

-- Who can read it.
select tests.login(tests.alice());
select is((select count(*)::int from public.pace_models_friend_read where owner_id = tests.alice()), 1,
  'self reads own pace model');
select tests.login(tests.bob());
select is((select count(*)::int from public.pace_models_friend_read where owner_id = tests.alice()), 1,
  'a friend reads the learned model');
select is((select count(*)::int from public.descents), 0, 'a friend cannot read the raw descents');
select is((select count(*)::int from public.pace_observations), 0, 'nor the observations');
select tests.login(tests.carol());
select is((select count(*)::int from public.pace_models_friend_read), 0, 'a stranger reads no model');
select is((select count(*)::int from public.descents), 0, 'nor descents');
select tests.login(tests.dave());
select is((select count(*)::int from public.pace_models_friend_read), 0, 'a blocked user reads no model');

-- Deleting the runs removes what they taught.
select tests.login(tests.alice());
select public.descent_delete((select descent_id from public.descents where content_hash = repeat('7', 64)));
select tests.logout();
select is(public.pace_recompute_drain(), 1, 'the delete queued a recompute');
select is((select count(*)::int from public.pace_models where owner_id = tests.alice()), 0,
  'with no runs left there is no model');

-- Old seasons count for less: the same run two and a half seasons later weighs half.
select tests.set_clock('2028-07-10 18:30:00+00');
select tests.login(tests.alice());
select public.descent_upsert(current_setting('tests.alice_run')::jsonb);
select tests.logout();
select public.pace_recompute_drain();
-- w = 0.5: (0.5 * 3 * 2.0 + 8) / (0.5 * 3 + 8) = 11 / 9.5 = 1.158
select ok(abs((select (difficulty_factor ->> 'blue')::numeric from public.pace_models where owner_id = tests.alice()) - 1.158) < 0.002,
  'observations older than two seasons are down-weighted by half per season');

select * from finish();
rollback;
