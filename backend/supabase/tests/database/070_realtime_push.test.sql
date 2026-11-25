-- Realtime topics, the push outbox, device tokens and the job queue.
-- Rules out: positions on public channels, client broadcasts, device tokens
-- that outlive a sign-out, an open push relay.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');

-- ----------------------------------------------- realtime.messages policies
select ok(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'realtime' and c.relname = 'messages'),
  'row level security is enabled on realtime.messages');
select is(
  (select count(*)::int from pg_policies
   where schemaname = 'realtime' and tablename = 'messages' and cmd in ('INSERT', 'UPDATE', 'DELETE', 'ALL')),
  0, 'clients_cannot_insert_realtime_messages: no policy lets any role write realtime.messages');
select set_eq(
  $$select policyname::text from pg_policies
    where schemaname = 'realtime' and tablename = 'messages' and cmd = 'SELECT'$$,
  array['user_topic_read'], 'the only read policy is the private-topic policy');
select is(
  (select qual from pg_policies where schemaname = 'realtime' and policyname = 'user_topic_read') ~ 'auth\.uid\(\)',
  true, 'and it is bound to the caller''s own user id');
select is(
  (select roles::text[] from pg_policies where schemaname = 'realtime' and policyname = 'user_topic_read'),
  array['authenticated'], 'stranger_cannot_subscribe_to_user_topic: signed-out clients have no read policy at all');

select tests.login(tests.alice());
select throws_ok(
  format($$insert into realtime.messages (topic, extension, event, payload, private)
           values (%L, 'broadcast', 'presence', '{"lat": 1}'::jsonb, true)$$,
         'user:' || tests.bob()::text),
  null, null, 'clients_cannot_insert_realtime_messages: a client broadcast to another user''s topic is refused');
select throws_ok(
  format($$insert into realtime.messages (topic, extension, event, payload, private)
           values (%L, 'broadcast', 'presence', '{"lat": 1}'::jsonb, true)$$,
         'user:' || tests.alice()::text),
  null, null, 'clients_cannot_insert_realtime_messages: even to the client''s own topic');

-- Realtime authorizes a private-channel join by checking, as the joining user
-- with realtime.topic set to the channel, whether a row is visible. Do the same.
select tests.logout();
select public.emit('user:' || tests.alice()::text, 'presence', '{"probe": true}'::jsonb);
do $$
declare
  v_rows int := 0;
begin
  begin
    execute 'select count(*) from realtime.messages where topic = $1'
      into v_rows using 'user:' || tests.alice()::text;
  exception when others then
    v_rows := 0;
  end;
  perform set_config('tests.realtime_rows', v_rows::text, true);
end;
$$;

select cmp_ok(current_setting('tests.realtime_rows')::int, '>', 0,
  'an event emitted by the database is stored on its private topic');
select set_config('realtime.topic', 'user:' || tests.alice()::text, true);
select tests.login(tests.alice());
select cmp_ok((select count(*)::int from realtime.messages), '>', 0,
  'a user can read messages on their own topic');
select tests.login(tests.bob());
select is((select count(*)::int from realtime.messages), 0,
  'stranger_cannot_subscribe_to_user_topic: another user''s topic shows nothing');

-- -------------------------------------- device_token_removed_on_unregister
select tests.login(tests.alice());
select lives_ok($$select public.device_token_register(repeat('ab', 32), 'development', '42')$$,
  'device_token_register stores the token');
select lives_ok($$select public.device_token_register(repeat('ab', 32), 'production', '43')$$,
  'registering again updates it');
select throws_ok($$select public.device_token_register('not-a-token', 'production', '43')$$,
  'P0001', 'invalid', 'a malformed token is refused');
select tests.logout();
select results_eq(
  $$select user_id, environment from public.device_tokens where token = repeat('ab', 32)$$,
  $$values (tests.alice(), 'production'::text)$$, 'one row, with the latest environment');

select tests.login(tests.bob());
select public.device_token_register(repeat('ab', 32), 'production', '43');
select tests.logout();
select set_eq(
  $$select user_id from public.device_tokens where token = repeat('ab', 32)$$,
  array[tests.bob()], 'a phone that signs in as someone else stops receiving the first account''s pushes');

select tests.login(tests.bob());
select public.device_token_unregister(repeat('ab', 32));
select tests.logout();
select is((select count(*)::int from public.device_tokens), 0,
  'device_token_removed_on_unregister');

-- ------------------------------------------------------- friend pushes
insert into public.device_tokens (user_id, token, environment)
values (tests.alice(), repeat('a1', 32), 'development'), (tests.carol(), repeat('c1', 32), 'production');
select tests.login(tests.alice());
select public.friend_request(tests.carol());
select tests.login(tests.carol());
select public.friend_respond((select id from public.friendships where addressee_id = tests.carol()), true);
select tests.logout();
select results_eq(
  $$select kind, user_id, payload ->> 'display_name' from public.push_outbox order by id$$,
  $$values ('friend.requested'::text, tests.carol(), 'Alice'::text),
           ('friend.accepted'::text, tests.alice(), 'Carol'::text)$$,
  'a request pushes to the person asked; an acceptance pushes to the person who asked');

-- A user with no registered phone gets no outbox row at all.
select tests.login(tests.erin());
select public.friend_request(tests.bob());
select tests.logout();
select is((select count(*)::int from public.push_outbox where user_id = tests.bob()), 0,
  'no push is queued for a user without a device token');

-- ---------------------------------------------- outbox: claim and collapse
delete from public.push_outbox;
insert into public.push_outbox (user_id, kind, payload, created_at) values
  (tests.alice(), 'meet.partner_arrived', '{"meet_id": "m-1"}', '2026-01-10 17:59:30+00'),
  (tests.alice(), 'meet.partner_arrived', '{"meet_id": "m-1"}', '2026-01-10 17:59:40+00'),
  (tests.alice(), 'meet.proposed',        '{"meet_id": "m-0"}', '2026-01-10 17:30:00+00'),
  (tests.carol(), 'friend.accepted',      '{}',                 '2026-01-10 17:59:50+00');
select is((select count(*)::int from public.push_outbox_claim(25)), 2,
  'a claim returns one row per notification worth sending');
select set_eq(
  $$select last_error from public.push_outbox where sent_at is not null$$,
  array['collapsed', 'stale'],
  'duplicates for the same meet collapse to the newest; rows older than 15 minutes are dropped');
select is(
  (select jsonb_array_length(tokens) from public.push_outbox_claim(25)), null,
  'claimed rows are leased: a second worker gets nothing');
select is(
  (select count(*)::int from public.push_outbox where sent_at is null and leased_until > public.clock()), 2,
  'both claimed rows carry a lease');

-- Delivery outcome: one sent, one whose token APNs reported dead.
select public.push_outbox_complete(
  (select id from public.push_outbox where sent_at is null and user_id = tests.alice()));
select public.push_outbox_complete(
  (select id from public.push_outbox where sent_at is null and user_id = tests.carol()),
  null, array[repeat('c1', 32)]);
select is((select count(*)::int from public.push_outbox where sent_at is null), 0, 'completed rows are marked sent');
select is((select count(*)::int from public.device_tokens where user_id = tests.carol()), 0,
  'a token APNs reports dead is deleted');

-- A duplicate that arrives within 60 s of a delivered one is collapsed too.
select tests.set_clock('2026-01-10 18:00:30+00');
insert into public.push_outbox (user_id, kind, payload, created_at)
values (tests.alice(), 'meet.partner_arrived', '{"meet_id": "m-1"}', '2026-01-10 18:00:20+00');
select is((select count(*)::int from public.push_outbox_claim(25)), 0,
  'a repeat of a notification sent in the last 60 seconds is not sent again');

-- A failure is retried with backoff, then given up on.
insert into public.push_outbox (user_id, kind, payload, created_at)
values (tests.alice(), 'meet.ended', '{"meet_id": "m-2"}', '2026-01-10 18:00:25+00');
select is((select count(*)::int from public.push_outbox_claim(25)), 1, 'a new notification is claimed');
select public.push_outbox_complete(
  (select id from public.push_outbox where kind = 'meet.ended'), 'apns 503');
select results_eq(
  $$select sent_at is null, last_error, leased_until > public.clock() from public.push_outbox where kind = 'meet.ended'$$,
  $$values (true, 'apns 503'::text, true)$$, 'a failed send stays queued and is held back before the retry');

-- ------------------------------------------------------------------- jobs
update public.resorts set published = true where id in ('whistler-blackcomb', 'vail');
select is(public.enqueue_status_refresh(), 2, 'one status job per published live resort');
select is(public.enqueue_status_refresh(), 0, 'a queued job is not queued twice');
select is(public.enqueue_conditions_refresh(), 2, 'one conditions job per published resort');
select is((select count(*)::int from public.jobs_claim('status_refresh', 1)), 1, 'jobs_claim leases one job');
select is((select count(*)::int from public.jobs_claim('status_refresh', 5)), 1, 'a leased job is not claimed again');
select is((select count(*)::int from public.jobs_claim('status_refresh', 5)), 0, 'and then the queue is empty');
select public.jobs_complete((select min(id) from public.jobs where kind = 'status_refresh'));
select public.jobs_complete((select max(id) from public.jobs where kind = 'status_refresh'), 'provider down');
select results_eq(
  $$select attempts, last_error, leased_until is null, run_after > public.clock()
    from public.jobs where kind = 'status_refresh'$$,
  $$values (1, 'provider down'::text, true, true)$$,
  'success deletes the job; failure releases it with backoff');
select tests.set_clock('2026-01-10 18:10:00+00');
select is((select count(*)::int from public.jobs_claim('status_refresh', 5)), 1, 'the failed job is retried later');
select tests.set_clock('2026-01-10 18:16:00+00');
select is((select count(*)::int from public.jobs_claim('status_refresh', 5)), 1,
  'a job whose lease ran out is claimed again');

-- ------------------------------------- resorts without a live provider
update public.resorts set published = true, status_mode = 'scheduled_only', status_provider = null
where id = 'stowe';
select is(public.scheduled_status_rows(), 1, 'one scheduled row per published resort without a live provider');
select results_eq(
  $$select source, groups, expires_at - observed_at from public.resort_status where resort_id = 'stowe'$$,
  $$values ('scheduled'::text, '{}'::jsonb, interval '75 minutes')$$,
  'the row says "no live information" and expires like any other');
select is((select count(*)::int from public.jobs where resort_id = 'stowe'), 0,
  'and it costs no worker job');
select lives_ok(
  $$update public.resorts set status_provider = 'liftie', status_mode = 'live' where id = 'stowe'$$,
  'a resort declares its provider as data: liftie is one of three');
select throws_ok($$update public.resorts set status_provider = 'guesswork' where id = 'stowe'$$,
  '23514', null, 'an unknown provider is refused');
select throws_ok($$update public.resorts set status_provider = null where id = 'stowe'$$,
  '23514', null, 'a live resort must declare a provider');

-- ------------------------------------------------------- resort status feed
select tests.logout();
insert into public.resort_status (resort_id, observed_at, expires_at, source, groups, groomed)
values ('whistler-blackcomb', '2026-01-10 18:00:00+00', '2026-01-10 19:15:00+00', 'epic',
        '{"lift:peak-express": "open", "trail:franzs-run": "closed"}', '{}'),
       ('whistler-blackcomb', '2026-01-10 18:15:00+00', '2026-01-10 19:30:00+00', 'epic',
        '{"lift:peak-express": "hold"}', '{}'),
       ('heavenly', '2026-01-10 18:15:00+00', '2026-01-10 19:30:00+00', 'epic', '{}', '{}');
select tests.login_anon();
select results_eq(
  $$select resort_id, groups ->> 'lift:peak-express' from public.resort_status_current
    where resort_id <> 'stowe'$$,
  $$values ('whistler-blackcomb'::text, 'hold'::text)$$,
  'resort_status_current is the latest row per published resort, readable signed out');

select tests.logout();
insert into public.resort_status (resort_id, observed_at, expires_at, source, groups, groomed, wait_minutes)
values ('whistler-blackcomb', '2026-01-10 18:20:00+00', '2026-01-10 19:35:00+00', 'epic',
        '{"lift:peak-express": "open"}', '{}', '{"lift:peak-express": 7}');
select tests.login_anon();
select results_eq(
  $$select (wait_minutes ->> 'lift:peak-express')::int from public.resort_status_current
    where resort_id = 'whistler-blackcomb'$$,
  $$values (7)$$,
  'live lift waits reach the current-status view (0014)');
select results_eq(
  $$select wait_minutes from public.resort_status
    where resort_id = 'whistler-blackcomb' and observed_at = '2026-01-10 18:00:00+00'$$,
  $$values ('{}'::jsonb)$$,
  'a row written without waits has none: today''s pricing');

select * from finish();
rollback;
