-- An arrival must be current to complete a meet (0028).
-- Rules out: a skier who arrived, lost service and left completing the meet
-- when the friend arrives later (stale_arrival_does_not_complete), and the
-- bound breaking two skiers who are standing there together
-- (fresh_arrivals_complete).
begin;
select no_plan();

select tests.set_clock('2026-01-14 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());

-- ============================================ stale_arrival_does_not_complete

select tests.login(tests.alice());
select public.meet_propose('21000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('21000000-0000-4000-8000-000000000001', true, 900, 90);

-- Alice arrives, then her phone goes quiet: her `arrived` stays stored.
select tests.set_clock('2026-01-14 18:01:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('21000000-0000-4000-8000-000000000001', 0, 0, 0,
  'arrived', '2026-01-14 18:01:00+00');

-- Bob arrives nine minutes later.
select tests.set_clock('2026-01-14 18:10:00+00');
select tests.login(tests.bob());
select lives_ok(
  $$select public.meet_progress_update('21000000-0000-4000-8000-000000000001', 0, 0, 0,
      'arrived', '2026-01-14 18:10:00+00')$$,
  'the later arrival is accepted');
select tests.logout();
select is((select status from public.meets where meet_id = '21000000-0000-4000-8000-000000000001'), 'active',
  'stale_arrival_does_not_complete: an arrival nine minutes old does not complete the meet');
select results_eq(
  $$select user_id, state from public.meet_progress
    where meet_id = '21000000-0000-4000-8000-000000000001' order by user_id$$,
  $$select u, 'arrived'::text from unnest(array[tests.alice(), tests.bob()]) u order by u$$,
  'though both stored states say arrived');
select is((select count(*)::int from public.push_outbox where kind = 'meet.ended'), 0,
  'and nobody is told they met up');

-- Alice's phone speaks again from the meeting point: both are current now.
select tests.set_clock('2026-01-14 18:11:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('21000000-0000-4000-8000-000000000001', 0, 0, 0,
  'arrived', '2026-01-14 18:11:00+00');
select tests.logout();
select results_eq(
  $$select status, end_reason, ended_by from public.meets
    where meet_id = '21000000-0000-4000-8000-000000000001'$$,
  $$values ('completed'::text, 'arrived'::text, tests.alice())$$,
  'a fresh arrival from the first skier, with the other 60 s old, completes it');

-- ==================================================== fresh_arrivals_complete

select tests.set_clock('2026-01-14 19:00:00+00');
select tests.login(tests.bob());
select public.meet_propose('21000000-0000-4000-8000-000000000002', tests.alice(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.alice());
select public.meet_respond('21000000-0000-4000-8000-000000000002', true, 900, 90);

select tests.set_clock('2026-01-14 19:05:00+00');
select tests.login(tests.bob());
select public.meet_progress_update('21000000-0000-4000-8000-000000000002', 0, 0, 0,
  'arrived', '2026-01-14 19:05:00+00');

-- Alice arrives 90 s later, while Bob's last fix is still within the bound.
select tests.set_clock('2026-01-14 19:06:30+00');
select tests.login(tests.alice());
select public.meet_progress_update('21000000-0000-4000-8000-000000000002', 0, 0, 0,
  'arrived', '2026-01-14 19:06:30+00');
select tests.logout();
select results_eq(
  $$select status, end_reason, ended_by from public.meets
    where meet_id = '21000000-0000-4000-8000-000000000002'$$,
  $$values ('completed'::text, 'arrived'::text, tests.alice())$$,
  'fresh_arrivals_complete: both arrived within 120 s of each other completes the meet');

-- A stranger still cannot report an arrival.
select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_progress_update('21000000-0000-4000-8000-000000000002', 0, 0, 0,
      'arrived', '2026-01-14 19:06:30+00')$$,
  'P0001', 'not_participant', 'stranger: cannot report arrival on someone else''s meet');

select * from finish();
rollback;
