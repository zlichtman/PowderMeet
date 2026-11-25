-- Presence (live position) as self, friend, stranger and blocked.
-- Rules out: positions readable or received by anyone but accepted friends,
-- and presence that outlives a friendship (I-19, I-22).
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());

-- ------------------------------------------------------------- write path
select tests.login(tests.alice());
select throws_ok(
  $$insert into public.presence (user_id, resort_id, lon, lat, captured_at)
    values (tests.alice(), 'whistler-blackcomb', -122.95, 50.09, now())$$,
  '42501', null, 'a client cannot insert presence directly');
select throws_ok(
  $$select public.presence_update('vail', -106.37, 39.62, 5, 3, 90, '2026-01-10 18:00:00+00')$$,
  'P0001', 'resort_not_published', 'presence at an unpublished resort is refused');
select throws_ok(
  $$select public.presence_update('whistler-blackcomb', -122.95, 95, 5, 3, 90, '2026-01-10 18:00:00+00')$$,
  'P0001', 'invalid', 'an impossible latitude is refused');
select lives_ok(
  $$select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-10 18:00:00+00')$$,
  'presence_update stores a fix');

-- --------------------------------------------- read: self, friend, others
select is((select lat from public.presence where user_id = tests.alice()), 50.09::double precision,
  'self reads own presence');
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'a friend reads the presence row');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 1,
  'presence_snapshot returns the friend at that resort');
select is((select count(*)::int from public.presence_snapshot('vail')), 0,
  'and nobody at another resort');
select tests.login(tests.carol());
select is((select count(*)::int from public.presence), 0, 'a stranger reads no presence');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 0,
  'a stranger gets an empty snapshot');
select tests.login(tests.dave());
select is((select count(*)::int from public.presence), 0, 'a blocked user reads no presence');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 0,
  'a blocked user gets an empty snapshot');

-- ------------------------------------------------------------ fan-out set
select tests.logout();
update public.profiles set current_resort_id = 'whistler-blackcomb'
where id in (tests.bob(), tests.carol(), tests.dave());
select set_eq(
  $$select r from public.presence_recipients(tests.alice(), 'whistler-blackcomb') r$$,
  array[tests.bob()],
  'positions fan out to accepted friends at the resort: not strangers, not blocked users');
update public.profiles set current_resort_id = null where id = tests.bob();
select is_empty(
  $$select r from public.presence_recipients(tests.alice(), 'whistler-blackcomb') r$$,
  'a friend looking at another resort is not sent positions');

-- ------------------------------------------------ rate limit and ordering
select tests.login(tests.alice());
select lives_ok(
  $$select public.presence_update('whistler-blackcomb', -122.90, 50.10, 5, 3, 90, '2026-01-10 18:00:01+00')$$,
  'a second fix within 2 s is accepted as a call');
select is((select lon from public.presence where user_id = tests.alice()), -122.95::double precision,
  'but dropped: at most one stored fix per 2 s');

select tests.set_clock('2026-01-10 18:00:10+00');
select public.presence_update('whistler-blackcomb', -122.80, 50.20, 5, 3, 90, '2026-01-10 17:59:00+00');
select is((select lon from public.presence where user_id = tests.alice()), -122.95::double precision,
  'a fix captured earlier than the stored one is dropped (I-19)');
select public.presence_update('whistler-blackcomb', -122.94, 50.08, 5, 3, 90, '2026-01-10 18:00:09+00');
select is((select lon from public.presence where user_id = tests.alice()), -122.94::double precision,
  'a newer fix replaces the stored one');

-- ---------------------------------------------------------------- 15 min TTL
select tests.set_clock('2026-01-10 18:16:00+00');
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'the owner still reads a stale row');
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 0,
  'a friend no longer reads it after 15 minutes of server time');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 0,
  'and it leaves the snapshot');

-- ------------------------- presence_not_visible_after_unfriend_or_block
select tests.login(tests.alice());
select public.presence_update('whistler-blackcomb', -122.93, 50.07, 5, 3, 90, '2026-01-10 18:16:00+00');
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'a fresh fix is visible to the friend again');

select tests.login(tests.alice());
select public.friend_remove(tests.bob());
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 0,
  'presence_not_visible_after_unfriend_or_block: gone on unfriend');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 0,
  'presence_not_visible_after_unfriend_or_block: gone from the snapshot on unfriend');

select tests.logout();
select tests.befriend(tests.alice(), tests.bob());
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'visible again once they are friends again');
select tests.login(tests.alice());
select public.block_user(tests.bob());
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 0,
  'presence_not_visible_after_unfriend_or_block: gone on block');
select tests.logout();
select is_empty(
  $$select r from public.presence_recipients(tests.alice(), 'whistler-blackcomb') r$$,
  'presence_not_visible_after_unfriend_or_block: and nobody is sent the next fix');

-- ---------------------------------------------------------------- cleanup
select tests.set_clock('2026-01-10 20:17:00+00');
select is(public.presence_cleanup(), 1, 'presence_cleanup deletes rows older than 2 hours');
select is((select count(*)::int from public.presence), 0, 'the row is gone');

select * from finish();
rollback;
