-- Friendships and blocks. Rules out a hole where any user could insert an
-- `accepted` friendship and read the other person's location and pace.
begin;
select no_plan();

-- ---------------------------------------- forged_accepted_friendship_rejected
select tests.login(tests.alice());
select throws_ok(
  $$insert into public.friendships (requester_id, addressee_id, status)
    values (tests.alice(), tests.carol(), 'accepted')$$,
  '42501', null, 'forged_accepted_friendship_rejected: direct insert as a client is denied');
select throws_ok(
  $$insert into public.friendships (requester_id, addressee_id, status)
    values (tests.alice(), tests.carol(), 'pending')$$,
  '42501', null, 'a client cannot insert even a pending friendship directly');

select tests.logout();
select throws_ok(
  $$insert into public.friendships (requester_id, addressee_id, status)
    values (tests.alice(), tests.carol(), 'accepted')$$,
  'P0001', 'invalid_state',
  'forged_accepted_friendship_rejected: the trigger refuses an accepted insert from any role');

-- Request through the RPC, then try to accept it as the requester.
select tests.login(tests.alice());
select is((public.friend_request(tests.carol())).status, 'pending', 'friend_request creates a pending row');
select is((public.friend_request(tests.carol())).status, 'pending', 'friend_request is idempotent');
select is((select count(*)::int from public.friendships), 1, 'the repeat did not add a row');
select throws_ok(
  format('select public.friend_respond(%L, true)',
         (select id from public.friendships where requester_id = tests.alice() and addressee_id = tests.carol())),
  'P0001', 'invalid_state', 'forged_accepted_friendship_rejected: the requester cannot accept through the RPC');
select throws_ok($$select public.friend_request(tests.alice())$$, 'P0001', 'invalid',
  'a user cannot befriend themselves');
select throws_ok(
  $$update public.friendships set status = 'accepted' where requester_id = tests.alice()$$,
  '42501', null, 'a client cannot update a friendship directly');
select throws_ok(
  $$delete from public.friendships where requester_id = tests.alice()$$,
  '42501', null, 'a client cannot delete a friendship directly');

select tests.logout();
select ok(not public.is_accepted_friend(tests.alice(), tests.carol()),
  'a pending request is not a friendship');
select set_config('tests.request_id',
  (select id::text from public.friendships where requester_id = tests.alice() and addressee_id = tests.carol()),
  true);

-- A stranger to the request can neither see nor answer it.
select tests.login(tests.dave());
select is((select count(*)::int from public.friendships), 0, 'a stranger sees no row of someone else''s friendship');
select throws_ok(
  format('select public.friend_respond(%L, true)', current_setting('tests.request_id')),
  'P0001', 'not_found', 'a stranger cannot answer someone else''s request');

-- The addressee answers.
select tests.login(tests.carol());
select is((select count(*)::int from public.friendships), 1, 'the addressee sees the request');
select is(
  (public.friend_respond((select id from public.friendships where addressee_id = tests.carol()), false)).status,
  'pending', 'declining returns the request as it was');
select is((select count(*)::int from public.friendships), 0, 'declining deletes the request');

select tests.login(tests.alice());
select is((public.friend_request(tests.carol())).status, 'pending', 'alice asks again');
select tests.login(tests.carol());
select is(
  (public.friend_respond((select id from public.friendships where addressee_id = tests.carol()), true)).status,
  'accepted', 'the addressee accepts');
select is(
  (public.friend_respond((select id from public.friendships where addressee_id = tests.carol()), true)).status,
  'accepted', 'accepting twice is idempotent');
select ok(public.is_accepted_friend(tests.carol(), tests.alice()), 'they are friends now');

-- Both ask each other: the second request accepts the first.
select tests.login(tests.erin());
select is((public.friend_request(tests.alice())).status, 'pending', 'erin asks alice');
select tests.login(tests.alice());
select is((public.friend_request(tests.erin())).status, 'accepted',
  'asking someone who already asked you accepts their request');

select tests.login(tests.dave());
select ok(not public.is_accepted_friend(tests.alice(), tests.erin()),
  'is_accepted_friend answers false about a pair the caller is not part of');

-- ------------------------------------------------------- transition trigger
select tests.logout();
select throws_ok(
  $$update public.friendships set status = 'pending' where status = 'accepted'$$,
  'P0001', 'invalid_state', 'an accepted friendship cannot go back to pending');
select throws_ok(
  $$update public.friendships set requester_id = tests.dave() where addressee_id = tests.carol()$$,
  'P0001', 'invalid_state', 'the people in a friendship cannot be rewritten');

-- -------------------------------------------------------------- remove
select tests.login(tests.alice());
select lives_ok($$select public.friend_remove(tests.carol())$$, 'friend_remove deletes the friendship');
select lives_ok($$select public.friend_remove(tests.carol())$$, 'friend_remove is idempotent');
select ok(not public.is_accepted_friend(tests.alice(), tests.carol()), 'they are no longer friends');

-- --------------------------------------------------------------- blocks
select tests.logout();
select tests.befriend(tests.alice(), tests.dave());
select tests.login(tests.alice());
select ok(public.is_accepted_friend(tests.alice(), tests.dave()), 'alice and dave start as friends');
select lives_ok($$select public.block_user(tests.dave())$$, 'block_user succeeds');
select lives_ok($$select public.block_user(tests.dave())$$, 'block_user is idempotent');
select ok(not public.is_accepted_friend(tests.alice(), tests.dave()), 'blocking ends the friendship');
select is((select count(*)::int from public.user_blocks where blocked_id = tests.dave()), 1,
  'the blocker can see their block');
select throws_ok($$select public.friend_request(tests.dave())$$, 'P0001', 'invalid',
  'the blocker cannot request the person they blocked: invalid, as for an unknown user (0025)');
select throws_ok($$select public.block_user(tests.alice())$$, 'P0001', 'invalid', 'a user cannot block themselves');
select throws_ok(
  $$insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.bob())$$,
  '42501', null, 'a client cannot insert a block directly');

select tests.login(tests.dave());
select is((select count(*)::int from public.user_blocks), 0, 'the blocked user cannot see the block row');
select is((public.friend_request(tests.alice())).status, 'pending',
  'the blocked user''s request to the blocker looks pending, as an unanswered one does (0025)');
select tests.login(tests.alice());
select is((select count(*)::int from public.friendships where requester_id = tests.dave()), 0,
  'and the blocker never sees it');
select tests.login(tests.dave());
select lives_ok($$select public.friend_remove(tests.alice())$$, 'the blocked user withdraws it');

-- A block overrides a friendship row even if one somehow exists.
select tests.logout();
select tests.befriend(tests.alice(), tests.dave());
select ok(not public.is_accepted_friend(tests.alice(), tests.dave()),
  'is_accepted_friend is false while a block exists, whatever the friendship row says');
delete from public.friendships
where least(requester_id, addressee_id) = least(tests.alice(), tests.dave())
  and greatest(requester_id, addressee_id) = greatest(tests.alice(), tests.dave());

select tests.login(tests.alice());
select lives_ok($$select public.unblock_user(tests.dave())$$, 'unblock_user succeeds');
select tests.login(tests.dave());
select is((public.friend_request(tests.alice())).status, 'pending', 'after the unblock a request is possible again');

-- ------------------------------------------------------------- snapshot
select tests.login(tests.alice());
select is(jsonb_array_length(public.social_snapshot() -> 'friends'), 1, 'social_snapshot lists friends (erin)');
select is(public.social_snapshot() -> 'friends' -> 0 ->> 'display_name', 'Erin', 'with their display name');
select is(jsonb_array_length(public.social_snapshot() -> 'pending_in'), 1, 'and incoming requests (dave)');
select is(jsonb_array_length(public.social_snapshot() -> 'pending_out'), 0, 'and outgoing requests');
select is(jsonb_array_length(public.social_snapshot() -> 'blocks'), 0, 'and blocks');
select set_eq($$select user_id from public.friends_view$$, array[tests.erin()],
  'friends_view lists accepted friends only');

select * from finish();
rollback;
