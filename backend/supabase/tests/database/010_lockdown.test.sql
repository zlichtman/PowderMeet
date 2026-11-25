-- The shape of the API surface: what a client role can reach at all.
-- Rules out: anon_cannot_read_user_tables, clients writing shared tables
-- directly (I-21), and any RPC a client was not meant to have.
begin;
select no_plan();

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0, 'every table in public has row level security enabled');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'v')
     and (has_table_privilege('authenticated', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')
       or has_table_privilege('anon', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'))),
  0, 'no client role can insert, update or delete any table or view in public');

select set_eq(
  $$select c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'v') and has_table_privilege('anon', c.oid, 'SELECT')$$,
  array['resorts', 'resort_bundles', 'resort_active_bundle', 'resort_bundle_publications',
        'resort_status', 'resort_conditions', 'app_config',
        'published_resorts', 'resort_catalog', 'resort_status_current', 'resort_conditions_current'],
  'anon_cannot_read_user_tables: anon can select the resort catalog and nothing else');

select set_eq(
  $$select c.relname::text from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'v')
      and not has_table_privilege('authenticated', c.oid, 'SELECT')
      and not has_any_column_privilege('authenticated', c.oid, 'SELECT')$$,
  array['device_tokens', 'push_outbox', 'jobs', 'rate_limits', 'client_events',
        'display_name_blocked_words', 'notification_prefs', 'friend_codes', 'user_reports', 'apple_tokens', 'developer_accounts'],
  'device tokens, the push outbox, jobs, rate limits, client events, the name block list, notification preferences, add codes, reports and Apple tokens are service role only');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0, 'anon can execute no function in public');

select set_eq(
  $$select distinct p.proname::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and has_function_privilege('authenticated', p.oid, 'EXECUTE')$$,
  array['clock', 'is_accepted_friend',
        'friend_request', 'friend_respond', 'friend_remove', 'block_user', 'unblock_user',
        'find_users', 'social_snapshot', 'profile_update', 'profile_private', 'account_delete',
        'display_name_available',
        'presence_update', 'presence_snapshot', 'presence_clear',
        'device_token_register', 'device_token_unregister', 'client_event',
        'meet_propose', 'meet_respond', 'meet_progress_update', 'meet_end', 'meet_current', 'meet_history',
        'descent_upsert', 'descent_delete',
        'notification_prefs', 'notification_prefs_set',
        'friend_code_get', 'friend_code_rotate', 'friend_code_resolve', 'friend_request_by_code',
        'report_user',
        'search_users', 'is_developer'],
  'authenticated can execute exactly the client RPCs');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prosecdef
     and not exists (select 1 from unnest(p.proconfig) cfg where cfg like 'search_path=%')),
  0, 'every security definer function pins its search_path');

-- Behaviour, not just catalog state.
select tests.login_anon();
select throws_ok($$select id from public.profiles$$, '42501', null,
  'anon_cannot_read_user_tables: profiles');
select throws_ok($$select user_id from public.presence$$, '42501', null,
  'anon_cannot_read_user_tables: presence');
select throws_ok($$select meet_id from public.meets$$, '42501', null,
  'anon_cannot_read_user_tables: meets');
select throws_ok($$select id from public.friendships$$, '42501', null,
  'anon_cannot_read_user_tables: friendships');
select throws_ok($$select public.social_snapshot()$$, '42501', null,
  'anon cannot call a client RPC');
select lives_ok($$select id from public.published_resorts$$,
  'anon can read the published resort list');
select is((select count(*)::int from public.resorts), 0,
  'anon sees no unpublished resort');
select ok((select count(*) from public.resort_catalog) > 100,
  'anon can list the whole catalog for the picker');
select is((select count(*)::int from public.resort_catalog where bundle_id is not null), 0,
  'a resort with no published map has no bundle in the catalog');
select is((select region || ' ' || country from public.resort_catalog where id = 'whistler-blackcomb'),
  'BC Canada', 'the catalog says where a resort is');
select is((select aliases from public.resort_catalog where id = 'arlberg'),
  array['Ski Arlberg', 'St. Anton'], 'the catalog lists the other names a resort is searched by (0020)');
select is((select aliases from public.resort_catalog where id = 'whistler-blackcomb'),
  '{}'::text[], 'a resort with no other name has none');

select tests.login(tests.alice());
select throws_ok($$select user_id from public.device_tokens$$, '42501', null,
  'a signed-in user cannot read device tokens');
select throws_ok($$select id from public.push_outbox$$, '42501', null,
  'a signed-in user cannot read the push outbox');
select throws_ok($$select id from public.jobs$$, '42501', null,
  'a signed-in user cannot read jobs');
select throws_ok($$select * from public.jobs_claim('status_refresh', 1)$$, '42501', null,
  'a signed-in user cannot claim jobs');
select throws_ok($$select public.expire_meets()$$, '42501', null,
  'a signed-in user cannot run the expiry sweep');
select throws_ok($$select * from public.avatar_orphans(10)$$, '42501', null,
  'a signed-in user cannot list orphaned avatars');
select throws_ok($$select public.avatar_sweep_enqueue()$$, '42501', null,
  'a signed-in user cannot queue an avatar sweep');
select throws_ok(
  $$select public.bundle_publish('whistler-blackcomb', repeat('a', 64), array['x'], '{}'::jsonb, 'me')$$,
  '42501', null, 'a signed-in user cannot publish a bundle');
select throws_ok($$select public.push_enqueue(tests.bob(), 'meet.proposed', '{}'::jsonb)$$, '42501', null,
  'a signed-in user cannot queue a push');
select throws_ok($$select public.emit('user:' || tests.bob()::text, 'presence', '{}'::jsonb)$$, '42501', null,
  'a signed-in user cannot emit a realtime event');
select throws_ok(
  $$insert into public.client_events (user_id, kind) values (tests.alice(), 'x')$$, '42501', null,
  'client events are written through the RPC only');
select lives_ok($$select public.client_event('app.launch', '{"cold": true}'::jsonb)$$,
  'client_event records an event');

select tests.logout();
select is((select count(*)::int from public.client_events where user_id = tests.alice() and kind = 'app.launch'),
  1, 'the event is stored for the caller');

-- The notification set is closed: nothing else can be queued, by anyone.
select throws_ok(
  $$insert into public.push_outbox (user_id, kind) values (tests.alice(), 'presence')$$, '23514', null,
  'push_outbox rejects a kind outside the notification set');
select throws_ok(
  $$insert into public.push_outbox (user_id, kind) values (tests.alice(), 'marketing.digest')$$, '23514', null,
  'push_outbox rejects marketing');

select * from finish();
rollback;
