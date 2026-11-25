-- Add codes (migration 0016) as self, friend, stranger and blocked. Rules out:
-- reading anyone's code from the table, a replaced code still working, a code
-- telling a blocked user they were blocked, guessing codes without limit, and a
-- request sent by code reaching the person who blocked its sender.
begin;
select no_plan();

select tests.befriend(tests.alice(), tests.bob());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());

-- ------------------------------------------------------------------ self
select tests.login(tests.alice());
select matches(public.friend_code_get(), '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{10}$',
  'friend_code_get makes a ten-character code on first ask');
select set_config('tests.alice_code', public.friend_code_get(), true);
select is(public.friend_code_get(), current_setting('tests.alice_code'), 'asking again returns the same code');
select is(public.friend_code_resolve(current_setting('tests.alice_code')) ->> 'relation', 'self',
  'resolving your own code says it is yours');
select ok(public.friend_request_by_code(current_setting('tests.alice_code')) is null,
  'a request to your own code sends nothing');
select throws_ok($$select code from public.friend_codes$$, '42501', null,
  'a client cannot read the code table, its own row included');
select throws_ok($$insert into public.friend_codes (user_id, code) values (tests.alice(), 'AAAAAAAAAA')$$,
  '42501', null, 'or write it');

-- ---------------------------------------------------------------- friend
select tests.login(tests.bob());
select is(public.friend_code_resolve(current_setting('tests.alice_code')) ->> 'relation', 'friend',
  'a friend resolving the code sees they are friends');
select is(public.friend_code_resolve(lower(current_setting('tests.alice_code'))) ->> 'display_name', 'Alice',
  'case does not matter');
select is(
  public.friend_code_resolve(substr(current_setting('tests.alice_code'), 1, 5) || ' - '
                             || substr(current_setting('tests.alice_code'), 6)) ->> 'user_id',
  tests.alice()::text, 'nor do spaces and dashes');

-- -------------------------------------------------------------- stranger
select tests.login(tests.carol());
select is(public.friend_code_resolve(current_setting('tests.alice_code')) ->> 'relation', 'none',
  'a stranger with the code sees who it belongs to');
select ok(not (public.friend_code_resolve(current_setting('tests.alice_code')) ? 'equipment'),
  'and nothing but the name and photo');
select is(public.friend_request_by_code(current_setting('tests.alice_code')) ->> 'status', 'pending',
  'friend_request_by_code sends a pending request');
select is(public.friend_code_resolve(current_setting('tests.alice_code')) ->> 'relation', 'request_sent',
  'the code now reads as a request sent');
select is(public.friend_request_by_code(current_setting('tests.alice_code')) ->> 'status', 'pending',
  'sending again is idempotent');
select is((select count(*)::int from public.friendships), 1, 'carol sees one friendship row: hers to alice');

select tests.login(tests.alice());
select is((select count(*)::int from public.friendships where requester_id = tests.carol() and status = 'pending'),
  1, 'alice has carol''s request');
select is(public.friend_code_resolve(public.friend_code_get()) ->> 'relation', 'self', 'alice still owns her code');

-- -------------------------------------------------------------- rotation
select set_config('tests.alice_new', public.friend_code_rotate(), true);
select isnt(current_setting('tests.alice_new'), current_setting('tests.alice_code'), 'rotate makes a new code');
select is(public.friend_code_get(), current_setting('tests.alice_new'), 'and get returns the new one');
select tests.login(tests.erin());
select ok(public.friend_code_resolve(current_setting('tests.alice_code')) is null,
  'replaced_friend_code_names_nobody: the replaced code names nobody');
select ok(public.friend_request_by_code(current_setting('tests.alice_code')) is null,
  'and sends nothing');
select is(public.friend_request_by_code(current_setting('tests.alice_new')) ->> 'status', 'pending',
  'the new code works');

-- --------------------------------------------------------------- blocked
-- 0025: a block is hidden from the person blocked, so the blocker's code
-- answers them as it answers a stranger, and their request goes nowhere.
select tests.login(tests.dave());
select is(public.friend_code_resolve(current_setting('tests.alice_new')) ->> 'relation', 'none',
  'friend_code_hidden_from_blocked: a user alice blocked reads her code as a stranger does');
select is(public.friend_request_by_code(current_setting('tests.alice_new')) ->> 'status', 'pending',
  'and a request by code looks sent');
select set_config('tests.dave_code', public.friend_code_get(), true);
select tests.login(tests.alice());
select is((select count(*)::int from public.friendships where requester_id = tests.dave()), 0,
  'but alice never sees that request');
select ok(public.friend_code_resolve(current_setting('tests.dave_code')) is null,
  'and the code of someone alice blocked answers her as unknown');

-- ----------------------------------------------------------- rate limits
-- erin has used 3 of her 30 lookups above.
select tests.login(tests.erin());
do $$
begin
  for i in 1..27 loop
    perform public.friend_code_resolve('ZZZZZZZZZZ');
  end loop;
end;
$$;
select throws_ok($$select public.friend_code_resolve('ZZZZZZZZZZ')$$, 'P0001', 'rate_limited',
  'friend_code_misses_are_rate_limited: the 31st lookup in an hour is refused');
select throws_ok($$select public.friend_request_by_code(public.friend_code_get())$$, 'P0001', 'rate_limited',
  'requests by code share the limit');

select tests.login(tests.bob());
do $$
begin
  for i in 1..10 loop
    perform public.friend_code_rotate();
  end loop;
end;
$$;
select throws_ok($$select public.friend_code_rotate()$$, 'P0001', 'rate_limited',
  'the eleventh rotation in an hour is refused');

-- ------------------------------------------------------------------ anon
select tests.login_anon();
select throws_ok($$select public.friend_code_get()$$, '42501', null, 'anon cannot get a code');
select throws_ok($$select public.friend_code_resolve('ZZZZZZZZZZ')$$, '42501', null, 'or resolve one');

-- ------------------------------------------------------- account deletion
select tests.logout();
select is((select count(*)::int from public.friend_codes where user_id = tests.dave()), 1, 'dave has a code');
select tests.login(tests.dave());
select lives_ok($$select public.account_delete()$$, 'account_delete works for a user with a code');
select tests.logout();
select is((select count(*)::int from public.friend_codes where user_id = tests.dave()), 0,
  'and the code goes with the account');

select * from finish();
rollback;
