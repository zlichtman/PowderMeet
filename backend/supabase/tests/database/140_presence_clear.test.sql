-- presence_clear() (0020) as self, friend, stranger and blocked, and the
-- presence read rule.
-- Rules out: a presence row that outlives sign-out or leaving a resort, one
-- person clearing another's position, and a friend-read policy that depends on
-- the viewer's own presence row (friend_sees_presence_without_own_row).
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());

-- --------------------------------------- friend_sees_presence_without_own_row
select tests.login(tests.alice());
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-10 18:00:00+00');
select tests.logout();
select is((select count(*)::int from public.presence where user_id = tests.bob()), 0,
  'the viewer has no presence row of their own');
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'friend_sees_presence_without_own_row: a friend sees my presence when the viewer has no presence row');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 1,
  'friend_sees_presence_without_own_row: and in the snapshot');

-- ------------------------------------- nobody clears another person's row
select tests.login(tests.bob());
select lives_ok($$select public.presence_clear()$$, 'a friend may call presence_clear');
select tests.logout();
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'but it clears only their own row: the friend''s stays');
select tests.login(tests.carol());
select public.presence_clear();
select tests.login(tests.dave());
select public.presence_clear();
select tests.logout();
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'a stranger or a blocked user clearing changes nobody else''s row');

select tests.login_anon();
select throws_ok($$select public.presence_clear()$$, '42501', null, 'anon cannot call presence_clear');

-- ---------------------------------------------------------- self clears
select tests.login(tests.alice());
select lives_ok($$select public.presence_clear()$$, 'the owner clears their presence');
select is((select count(*)::int from public.presence where user_id = tests.alice()), 0,
  'the row is gone for its owner');
select tests.login(tests.bob());
select is((select count(*)::int from public.presence where user_id = tests.alice()), 0,
  'and for a friend');
select is((select count(*)::int from public.presence_snapshot('whistler-blackcomb')), 0,
  'it leaves the snapshot at once, without waiting out the 15 minute TTL');
select is(public.social_snapshot() #> '{friends,0,last_seen}', 'null'::jsonb,
  'and the friend card no longer says where they were');

-- ------------------------------------------- idempotent and not rate-limited
select tests.login(tests.alice());
select lives_ok($$select public.presence_clear()$$, 'clearing with no row is fine');
select lives_ok($$select public.presence_clear()$$, 'and repeating it at once is not rate-limited');
select tests.set_clock('2026-01-10 18:00:05+00');
select public.presence_update('whistler-blackcomb', -122.94, 50.08, 5, 3, 90, '2026-01-10 18:00:05+00');
select is((select count(*)::int from public.presence where user_id = tests.alice()), 1,
  'the next fix after a clear is stored again');

select * from finish();
rollback;
