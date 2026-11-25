-- Notification preferences (0018).
-- Rules out: muting or reading another user's notifications, a kind outside
-- the notification set, and a muted kind still reaching the phone.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.befriend(tests.alice(), tests.bob());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());

-- ------------------------------------------------------------------ self
select tests.login(tests.alice());
select is(public.notification_prefs(), '{}'::text[], 'with no row every notification is on');
select is(
  public.notification_prefs_set(array['meet.expired', 'friend.requested', 'meet.expired']),
  array['friend.requested', 'meet.expired'], 'muting stores each kind once, sorted');
select is(public.notification_prefs(), array['friend.requested', 'meet.expired'], 'and reads back');
select is(
  public.notification_prefs_set(array['friend.requested', 'meet.expired']),
  array['friend.requested', 'meet.expired'], 'setting the same kinds again is a no-op');
select throws_ok($$select public.notification_prefs_set(array['presence'])$$,
  'P0001', 'invalid', 'a kind outside the notification set is refused');
select throws_ok($$select public.notification_prefs_set(array['marketing.digest', 'meet.ended'])$$,
  'P0001', 'invalid', 'one bad kind refuses the whole call');
select throws_ok($$select public.notification_prefs_set(array[null::text])$$,
  'P0001', 'invalid', 'a null kind is refused');
select is(public.notification_prefs(), array['friend.requested', 'meet.expired'],
  'a refused call leaves the stored choice alone');
select throws_ok($$select user_id from public.notification_prefs$$, '42501', null,
  'the owner reads through the RPC only');
select throws_ok(
  format($$insert into public.notification_prefs (user_id, muted_kinds) values (%L, '{}')$$, tests.alice()),
  '42501', null, 'and cannot write the table directly');

-- -------------------------------------------- friend, stranger and blocked
-- The RPCs take no user argument: each caller can only ever reach their own row.
select tests.login(tests.bob());
select is(public.notification_prefs(), '{}'::text[], 'a friend sees their own choices, not alice''s');
select throws_ok($$select muted_kinds from public.notification_prefs$$, '42501', null,
  'a friend cannot read the table');
select is(public.notification_prefs_set(array['meet.proposed']), array['meet.proposed'],
  'a friend sets their own');

select tests.login(tests.carol());
select is(public.notification_prefs(), '{}'::text[], 'a stranger sees only their own (none)');
select throws_ok($$select muted_kinds from public.notification_prefs$$, '42501', null,
  'a stranger cannot read the table');

select tests.login(tests.dave());
select is(public.notification_prefs(), '{}'::text[], 'a blocked user sees only their own (none)');
select is(public.notification_prefs_set(null), '{}'::text[], 'null means everything on');

select tests.login_anon();
select throws_ok($$select public.notification_prefs()$$, '42501', null, 'anon cannot read preferences');
select throws_ok($$select public.notification_prefs_set(array['meet.proposed'])$$, '42501', null,
  'anon cannot set preferences');

select tests.logout();
select results_eq(
  $$select user_id, muted_kinds from public.notification_prefs order by user_id$$,
  $$values (tests.alice(), array['friend.requested', 'meet.expired']::text[]),
           (tests.bob(), array['meet.proposed']::text[]),
           (tests.dave(), '{}'::text[])$$,
  'each call wrote the caller''s own row and nobody else''s');

-- ----------------------------------------------------- the worker's claim
delete from public.push_outbox;
insert into public.push_outbox (user_id, kind, payload, created_at) values
  (tests.alice(), 'friend.requested', '{}', '2026-01-10 17:59:00+00'),
  (tests.alice(), 'friend.accepted',  '{}', '2026-01-10 17:59:10+00'),
  (tests.bob(),   'friend.requested', '{}', '2026-01-10 17:59:20+00'),
  (tests.carol(), 'friend.requested', '{}', '2026-01-10 17:59:30+00');
select set_eq(
  $$select user_id::text || ' ' || kind from public.push_outbox_claim(25)$$,
  array[tests.alice()::text || ' friend.accepted', tests.bob()::text || ' friend.requested',
        tests.carol()::text || ' friend.requested'],
  'a claim leaves out the kinds each recipient muted and sends the rest');
select results_eq(
  $$select sent_at = public.clock(), last_error from public.push_outbox
    where user_id = tests.alice() and kind = 'friend.requested'$$,
  $$values (true, 'muted'::text)$$,
  'a muted row is retired as muted, never handed to APNs');

-- Turning a kind back on applies to the next notification.
select tests.login(tests.alice());
select public.notification_prefs_set('{}');
select tests.logout();
insert into public.push_outbox (user_id, kind, payload, created_at)
values (tests.alice(), 'friend.requested', '{}', '2026-01-10 17:59:50+00');
select is((select count(*)::int from public.push_outbox_claim(25) where user_id = tests.alice()), 1,
  'once unmuted, the kind is sent again');

-- --------------------------------------------------------- account_delete
select tests.login(tests.bob());
select public.account_delete();
select tests.logout();
select is((select count(*)::int from public.notification_prefs where user_id = tests.bob()), 0,
  'deleting the account deletes its preferences');

select * from finish();
rollback;
