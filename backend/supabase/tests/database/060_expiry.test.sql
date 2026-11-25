-- Server-side expiry (I-24): every deadline is server time, moved here through
-- public.clock(). Divergence scenarios D5, D13, D14.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
insert into public.device_tokens (user_id, token, environment)
values (tests.alice(), md5('alice-phone'), 'production'), (tests.bob(), md5('bob-phone'), 'production');

-- ------------------------------------------- D13: a proposal nobody answers
select tests.login(tests.alice());
select public.meet_propose('60000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);

select tests.logout();
select tests.set_clock('2026-01-10 18:29:00+00');
select is(public.expire_meets(), 0, 'nothing expires 29 minutes after the proposal');
select is((select status from public.meets where meet_id = '60000000-0000-4000-8000-000000000001'), 'proposed',
  'the proposal is still open');

select tests.set_clock('2026-01-10 18:31:00+00');
select is(public.expire_meets(), 1, 'D13: the sweep expires it after 30 minutes');
select results_eq(
  $$select status, end_reason, ended_at from public.meets where meet_id = '60000000-0000-4000-8000-000000000001'$$,
  $$values ('expired'::text, 'timeout'::text, '2026-01-10 18:31:00+00'::timestamptz)$$,
  'D13: expired with reason timeout, stamped with server time');
select is(public.expire_meets(), 0, 'the sweep is idempotent');
select set_eq(
  $$select user_id from public.push_outbox where kind = 'meet.expired'$$,
  array[tests.alice()], 'an expired proposal pushes to the proposer only');

-- ------------------- D14: accepting late fails whatever the phone's clock says
select tests.login(tests.alice());
select public.meet_propose('60000000-0000-4000-8000-000000000002', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.set_clock('2026-01-10 19:02:00+00');
select tests.login(tests.bob());
select throws_ok(
  $$select public.meet_respond('60000000-0000-4000-8000-000000000002', true, 300, 30)$$,
  'P0001', 'meet_expired', 'D14: a proposal past its server deadline cannot be accepted, swept or not');
select tests.logout();
select is(public.expire_meets(), 1, 'the sweep then expires it');

-- ------------------------------------------------------- an active meet
select tests.login(tests.alice());
select public.meet_propose('60000000-0000-4000-8000-000000000003', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('60000000-0000-4000-8000-000000000003', true, 1200, 120);
-- Accepted at 19:02 with a longest estimate of 20 minutes: the sweep may not
-- touch it before 19:02 + 20 min + 45 min = 20:07.
select tests.login(tests.alice());
select public.meet_progress_update('60000000-0000-4000-8000-000000000003', 500, 50, 1500,
  'navigating', '2026-01-10 19:03:00+00');

select tests.logout();
select tests.set_clock('2026-01-10 19:30:00+00');
select is(public.expire_meets(), 0, 'D5: a participant silent for 20 minutes does not expire the meet');
select tests.set_clock('2026-01-10 20:06:00+00');
select is(public.expire_meets(), 0, 'D5: nor does anything before 45 minutes after the longest estimate');

-- One participant keeps reporting: the meet stays alive past the deadline.
select tests.set_clock('2026-01-10 20:00:00+00');
select tests.login(tests.alice());
select public.meet_progress_update('60000000-0000-4000-8000-000000000003', 100, 10, 300,
  'navigating', '2026-01-10 20:00:00+00');
select tests.logout();
select tests.set_clock('2026-01-10 20:30:00+00');
select is(public.expire_meets(), 0, 'progress from either participant in the last 45 minutes keeps it open');

select tests.set_clock('2026-01-10 20:46:00+00');
select is(public.expire_meets(), 1, 'with no progress for 45 minutes past the deadline it expires');
select results_eq(
  $$select status, end_reason from public.meets where meet_id = '60000000-0000-4000-8000-000000000003'$$,
  $$values ('expired'::text, 'timeout'::text)$$, 'expired with reason timeout');
select is(
  (select count(*)::int from public.push_outbox
   where kind = 'meet.expired' and payload ->> 'meet_id' = '60000000-0000-4000-8000-000000000003'),
  2, 'an expired active meet pushes to both participants');

select tests.login(tests.bob());
select is((public.meet_end('60000000-0000-4000-8000-000000000003', 'arrived')).status, 'expired',
  'ending an expired meet returns it unchanged');
select ok((public.meet_current()).meet_id is null, 'neither participant has an open meet afterwards');

select * from finish();
rollback;
