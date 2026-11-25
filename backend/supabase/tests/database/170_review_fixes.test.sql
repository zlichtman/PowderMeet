-- The fixes in migration 0023.
-- Rules out: propose-then-cancel push spam (meet_propose_rate_limited), an
-- estimate that keeps a meet open for decades, a phone clock running ahead
-- freezing meet progress (D14), a state change on the same fix being dropped,
-- an ending nobody can word ("who left"), a block that leaves a live meet
-- open, positions kept in realtime.messages past the TTL, a deleted user left
-- in other people's queued pushes, and an unconfirmed sign-up being matchable
-- by contacts.
-- The expected hash is `printf %s '<address>' | shasum -a 256`.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
select tests.befriend(tests.alice(), tests.erin());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
insert into public.device_tokens (user_id, token, environment)
select u, md5(u::text), 'development'
from unnest(array[tests.alice(), tests.bob(), tests.carol(), tests.dave(), tests.erin()]) u;

-- How many of a user's presence broadcasts realtime.messages holds, or -1 when
-- the table cannot be read here.
create function pg_temp.presence_broadcasts(p_user uuid) returns int language plpgsql as $$
declare
  v int;
begin
  select count(*)::int into v from realtime.messages rm
  where rm.event = 'presence' and rm.payload -> 'data' ->> 'user_id' = p_user::text;
  return v;
exception when others then
  return -1;
end;
$$;

-- ------------------------------------- meet_propose: who may, under 0023
select tests.login(tests.alice());
select throws_ok(
  $$select public.meet_propose('71000000-0000-4000-8000-0000000000f1', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'self: nobody proposes a meet to themselves');
select throws_ok(
  $$select public.meet_propose('71000000-0000-4000-8000-0000000000f1', tests.bob(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 86401, 60)$$,
  'P0001', 'invalid', 'an estimate over a day is refused');
select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_propose('71000000-0000-4000-8000-0000000000f1', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_non_friend_rejected: a stranger still cannot propose');
select tests.login(tests.dave());
select throws_ok(
  $$select public.meet_propose('71000000-0000-4000-8000-0000000000f1', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_blocked_rejected: a blocked user still cannot propose, told only not_friends (0025)');

-- ------------------------------------------------ meet_propose_rate_limited
select tests.login(tests.alice());
do $$
begin
  for i in 1 .. 20 loop
    perform public.meet_propose(('71000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, tests.bob(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
    perform public.meet_end(('71000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid, 'user_cancelled');
  end loop;
end;
$$;
select is((select count(*)::int from public.meets where proposer_id = tests.alice()), 20,
  'a friend may propose and withdraw 20 times in an hour');
select throws_ok(
  $$select public.meet_propose('71000000-0000-4000-8000-000000000021', tests.bob(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'rate_limited', 'meet_propose_rate_limited: the 21st proposal in the hour is refused');
select is(
  (public.meet_propose('71000000-0000-4000-8000-000000000020', tests.bob(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'cancelled', 'an idempotent retry is not a new proposal and still answers');
select tests.login(tests.bob());
select is(
  (public.meet_propose('71000000-0000-4000-8000-0000000000b1', tests.alice(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'proposed', 'the limit is the proposer''s own: the friend can still propose');
select public.meet_end('71000000-0000-4000-8000-0000000000b1', 'user_cancelled');

select tests.set_clock('2026-01-10 19:00:00+00');
select tests.login(tests.alice());
select is(
  (public.meet_propose('72000000-0000-4000-8000-000000000001', tests.bob(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'proposed', 'the next hour starts a new window');

-- ------------------------------------------------------ the invitee's estimate
select tests.login(tests.bob());
select throws_ok(
  $$select public.meet_respond('72000000-0000-4000-8000-000000000001', true, 86401, 90)$$,
  'P0001', 'invalid', 'the invitee''s estimate is capped at a day too');
select is((public.meet_respond('72000000-0000-4000-8000-000000000001', true, 900, 90)).status, 'active',
  'a sane estimate is accepted');

-- ----------------------------------------------------- D14: a clock running ahead
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 800, 80, 2400,
  'navigating', '2026-01-10 21:00:00+00');
select tests.logout();
select is(
  (select fix_at from public.meet_progress
   where meet_id = '72000000-0000-4000-8000-000000000001' and user_id = tests.bob()),
  '2026-01-10 19:01:00+00'::timestamptz, 'D14: a fix two hours ahead is stored at most a minute past server time');

select tests.set_clock('2026-01-10 19:05:00+00');
select tests.login(tests.bob());
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 500, 50, 1500,
  'navigating', '2026-01-10 19:05:00+00');
select tests.logout();
select results_eq(
  $$select eta_s, updated_at from public.meet_progress
    where meet_id = '72000000-0000-4000-8000-000000000001' and user_id = tests.bob()$$,
  $$values (500, '2026-01-10 19:05:00+00'::timestamptz)$$,
  'D14: once the clock is right, the next fix is applied and the progress stays fresh for the sweep');

select tests.login(tests.bob());
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 500, 50, 1500,
  'lost', '2026-01-10 19:05:00+00');
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 480, 50, 1500,
  'navigating', '2026-01-10 19:05:00+00');
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 1, 1, 1,
  'lost', '2026-01-10 19:04:00+00');
select tests.logout();
select results_eq(
  $$select state, eta_s from public.meet_progress
    where meet_id = '72000000-0000-4000-8000-000000000001' and user_id = tests.bob()$$,
  $$values ('navigating'::text, 480)$$,
  'a state change on the same fix is kept, and an older fix is still ignored (I-19)');

-- A future time stored before 0023 no longer blocks anything.
update public.meet_progress set fix_at = '2026-01-10 23:00:00+00'
where meet_id = '72000000-0000-4000-8000-000000000001' and user_id = tests.bob();
select tests.set_clock('2026-01-10 19:06:00+00');
select tests.login(tests.bob());
select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 400, 40, 1200,
  'navigating', '2026-01-10 19:06:00+00');
select tests.logout();
select results_eq(
  $$select eta_s, fix_at from public.meet_progress
    where meet_id = '72000000-0000-4000-8000-000000000001' and user_id = tests.bob()$$,
  $$values (400, '2026-01-10 19:06:00+00'::timestamptz)$$,
  'a fix stored in the future earlier is replaced by the next honest one');

select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 1, 1, 1,
      'arrived', '2026-01-10 19:06:00+00')$$,
  'P0001', 'not_participant', 'a stranger cannot report progress');
select tests.login(tests.dave());
select throws_ok(
  $$select public.meet_progress_update('72000000-0000-4000-8000-000000000001', 1, 1, 1,
      'arrived', '2026-01-10 19:06:00+00')$$,
  'P0001', 'not_participant', 'nor can a blocked user');

-- ------------------------------------------------------------ who ended it
select tests.login(tests.alice());
select is((public.meet_end('72000000-0000-4000-8000-000000000001', 'user_cancelled')).ended_by, tests.alice(),
  'self: the participant who ends a meet is recorded');
select tests.login(tests.bob());
select is((select ended_by from public.meets where meet_id = '72000000-0000-4000-8000-000000000001'), tests.alice(),
  'friend: the partner reads who ended it');
select tests.login(tests.carol());
select is((select count(*)::int from public.meets where meet_id = '72000000-0000-4000-8000-000000000001'), 0,
  'stranger: reads no meet at all');

select tests.login(tests.alice());
select public.meet_propose('72000000-0000-4000-8000-000000000002', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select is((public.meet_respond('72000000-0000-4000-8000-000000000002', false)).ended_by, tests.bob(),
  'a decline records the invitee');

select tests.login(tests.alice());
select public.meet_propose('72000000-0000-4000-8000-000000000003', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('72000000-0000-4000-8000-000000000003', true, 900, 90);
select public.friend_remove(tests.alice());
select tests.logout();
select results_eq(
  $$select status, end_reason, ended_by from public.meets where meet_id = '72000000-0000-4000-8000-000000000003'$$,
  $$values ('invalidated'::text, 'partner_left'::text, tests.bob())$$,
  'unfriending ends the meet with partner_left and records who left');
select tests.befriend(tests.alice(), tests.bob());

-- A block ends a live meet: the blocked person can no longer act on it.
select tests.login(tests.alice());
select public.meet_propose('72000000-0000-4000-8000-000000000004', tests.erin(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.erin());
select public.meet_respond('72000000-0000-4000-8000-000000000004', true, 900, 90);
select tests.login(tests.alice());
select public.block_user(tests.erin());
select tests.logout();
select results_eq(
  $$select status, end_reason, ended_by from public.meets where meet_id = '72000000-0000-4000-8000-000000000004'$$,
  $$values ('invalidated'::text, 'partner_left'::text, tests.alice())$$,
  'blocked: a block ends the live meet with partner_left and records the blocker');
select tests.login(tests.erin());
select throws_ok(
  $$select public.meet_progress_update('72000000-0000-4000-8000-000000000004', 1, 1, 1,
      'navigating', '2026-01-10 19:06:00+00')$$,
  'P0001', 'invalid_state', 'blocked: no progress on the ended meet');
select throws_ok(
  $$select public.meet_respond('72000000-0000-4000-8000-000000000004', true, 900, 90)$$,
  'P0001', 'meet_not_proposed', 'blocked: nor an answer to it');
select tests.logout();
select ok(
  not exists (select 1 from public.presence_recipients(tests.erin(), 'whistler-blackcomb') r where r = tests.alice()),
  'blocked: and the meet no longer carries positions between them');

select tests.login(tests.alice());
select public.meet_propose('72000000-0000-4000-8000-000000000005', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.logout();
select tests.set_clock('2026-01-10 19:37:00+00');
select public.expire_meets();
select results_eq(
  $$select status, ended_by from public.meets where meet_id = '72000000-0000-4000-8000-000000000005'$$,
  $$values ('expired'::text, null::uuid)$$,
  'an ending by the server records nobody');

-- --------------------------------------- presence broadcasts leave with the TTL
select tests.set_clock('2026-01-10 19:40:00+00');
select tests.login(tests.bob());
select public.profile_update('{"current_resort_id": "whistler-blackcomb"}'::jsonb);
select tests.login(tests.alice());
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-10 19:40:00+00');
select tests.logout();
select cmp_ok(pg_temp.presence_broadcasts(tests.alice()), '>', 0,
  'a position sent to a friend is stored in realtime.messages');
select tests.set_clock('2026-01-10 19:50:00+00');
select public.presence_cleanup();
select cmp_ok(pg_temp.presence_broadcasts(tests.alice()), '>', 0,
  'presence_cleanup keeps a broadcast still inside the 15 minute TTL');
select tests.set_clock('2026-01-10 19:56:00+00');
select public.presence_cleanup();
select is(pg_temp.presence_broadcasts(tests.alice()), 0,
  'and removes it once the TTL has passed');

-- ------------------------------------ account_delete leaves no one's push behind
select tests.set_clock('2026-01-10 20:00:00+00');
delete from public.push_outbox;
select tests.login(tests.alice());
select public.profile_update('{"current_resort_id": "whistler-blackcomb"}'::jsonb);
select public.presence_update('whistler-blackcomb', -122.95, 50.09, 5, 3, 90, '2026-01-10 20:00:00+00');
select tests.login(tests.bob());
select public.presence_update('whistler-blackcomb', -122.96, 50.08, 5, 3, 90, '2026-01-10 20:00:00+00');
select tests.login(tests.alice());
select public.meet_propose('72000000-0000-4000-8000-000000000006', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select public.friend_request(tests.carol());
select tests.login(tests.bob());
select public.meet_respond('72000000-0000-4000-8000-000000000006', true, 900, 90);
select tests.logout();
-- One of the pushes naming alice was already delivered.
update public.push_outbox set sent_at = public.clock()
where user_id = tests.bob() and kind = 'meet.proposed';
select is(
  (select count(*)::int from public.push_outbox
   where user_id <> tests.alice() and payload::text like '%' || tests.alice()::text || '%'),
  2, 'before the delete, a friend and a stranger hold pushes naming alice');
select cmp_ok(pg_temp.presence_broadcasts(tests.bob()), '>', 0, 'and the friend has broadcast a position to her');

select tests.login(tests.alice());
select lives_ok($$select public.account_delete()$$, 'account_delete succeeds');
select tests.logout();
select is(
  (select count(*)::int from public.push_outbox where payload::text like '%' || tests.alice()::text || '%'),
  0, 'no queued or sent push names the deleted user');
select is((select count(*)::int from public.push_outbox where user_id = tests.carol()), 0,
  'the friend request push to a stranger is gone');
select results_eq(
  $$select kind, sent_at is null, payload ->> 'end_reason', payload ->> 'meet_id',
           payload ?| array['partner_id', 'user_id', 'display_name', 'avatar_url'], payload ->> 'partner_name'
    from public.push_outbox where user_id = tests.bob()$$,
  $$values ('meet.ended'::text, true, 'partner_left'::text, '72000000-0000-4000-8000-000000000006'::text, false,
            'Alice'::text)$$,
  'the partner still gets the meet.ended push, with no photo or id, and the name only until it is sent (0026)');
select is(pg_temp.presence_broadcasts(tests.alice()), 0, 'the deleted user''s broadcast positions are gone');
select is(pg_temp.presence_broadcasts(tests.bob()), 0,
  'and so are the positions friends sent to her topic, which nobody can read any more (0025)');

-- ------------------------------------------ only a confirmed email is matchable
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values ('00000000-0000-0000-0000-000000000000', 'f6000000-0000-4000-8000-0000000000f6', 'authenticated',
        'authenticated', 'unconfirmed.match@powdermeet.test', '', null,
        '{"provider":"email","providers":["email"]}', '{"display_name":"Uma"}', now(), now());
select is((select email_hash from public.profiles where id = 'f6000000-0000-4000-8000-0000000000f6'), null,
  'an unconfirmed sign-up gets no hash');
select tests.login(tests.carol());
select is(
  (select count(*)::int from public.find_users(
     array['3373ba41bafc8aca59a436d2cc090434a808df1bc6eae714068632917226075a'], '{}')),
  0, 'so contacts cannot find an address nobody has proved they own');
select tests.logout();
update auth.users set email_confirmed_at = now() where id = 'f6000000-0000-4000-8000-0000000000f6';
select is((select email_hash from public.profiles where id = 'f6000000-0000-4000-8000-0000000000f6'),
  '3373ba41bafc8aca59a436d2cc090434a808df1bc6eae714068632917226075a',
  'confirming the address sets the hash');
select tests.login(tests.carol());
select results_eq(
  $$select id from public.find_users(array['3373ba41bafc8aca59a436d2cc090434a808df1bc6eae714068632917226075a'], '{}')$$,
  $$values ('f6000000-0000-4000-8000-0000000000f6'::uuid)$$,
  'and contacts find it from then on');
select tests.logout();

select ok(not has_function_privilege('authenticated', 'public.meets_ended_by()', 'EXECUTE'),
  'clients cannot call the ended_by trigger function');

select * from finish();
rollback;
