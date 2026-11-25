-- avatar_orphans() and the avatar_sweep job (0021).
-- Rules out: a stored photo that outlives its profile or its replacement, the
-- sweep removing a current photo or an upload still waiting for its
-- profile_update, and account_delete orphaning bytes by deleting storage rows
-- with SQL.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');

-- Alice: a current photo, a replaced one, and an upload made a minute ago.
-- Bob: one photo, uploaded a minute ago, then he deletes his account.
insert into storage.objects (bucket_id, name, owner, created_at) values
  ('avatars', tests.alice()::text || '/current.jpg', tests.alice(), '2026-01-08 12:00:00+00'),
  ('avatars', tests.alice()::text || '/replaced.jpg', tests.alice(), '2026-01-08 11:00:00+00'),
  ('avatars', tests.alice()::text || '/fresh.jpg', tests.alice(), '2026-01-10 17:59:00+00'),
  ('avatars', tests.bob()::text || '/photo.jpg', tests.bob(), '2026-01-10 17:59:00+00');
update public.profiles set avatar_url = tests.alice()::text || '/current.jpg' where id = tests.alice();
update public.profiles set avatar_url = tests.bob()::text || '/photo.jpg' where id = tests.bob();

-- ---------------------------------------------------------------- privileges
select ok(has_function_privilege('service_role', 'public.avatar_orphans(int)', 'EXECUTE'),
  'the service role can list orphans');
select ok(not has_function_privilege('authenticated', 'public.avatar_orphans(int)', 'EXECUTE')
      and not has_function_privilege('anon', 'public.avatar_orphans(int)', 'EXECUTE'),
  'no client role can list orphans');
select ok(not has_function_privilege('authenticated', 'public.avatar_sweep_enqueue()', 'EXECUTE'),
  'no client can queue a sweep');

select set_eq($$select * from public.avatar_orphans(100)$$,
  array[tests.alice()::text || '/replaced.jpg'],
  'before any delete, only the replaced photo is an orphan');

-- ------------------------------------------------------------ account_delete
select tests.login(tests.bob());
select lives_ok($$select public.account_delete()$$, 'account_delete succeeds');
select tests.logout();

select is((select count(*)::int from storage.objects where bucket_id = 'avatars' and name like tests.bob()::text || '/%'),
  1, 'account_delete leaves the storage row for the Storage API to remove, bytes and all');
select ok((select p.prosrc not like '%storage.objects%' from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'account_delete'),
  'account_delete no longer deletes from storage.objects');
select is((select count(*)::int from public.jobs where kind = 'avatar_sweep' and owner_id is null and resort_id is null),
  1, 'account_delete queues one sweep that does not cascade away with the profile');

-- ------------------------------------------------------------------ orphans
select set_eq($$select * from public.avatar_orphans(100)$$,
  array[tests.bob()::text || '/photo.jpg', tests.alice()::text || '/replaced.jpg'],
  'a deleted owner''s photo (at once) and a stale replaced photo are orphans; the current photo and a fresh upload are not');
select is((select * from public.avatar_orphans(1)), tests.bob()::text || '/photo.jpg',
  'a deleted owner''s photo comes first, so a backlog cannot hold it past the limit');

update public.profiles set avatar_url = null where id = tests.alice();
select set_eq($$select * from public.avatar_orphans(100)$$,
  array[tests.bob()::text || '/photo.jpg', tests.alice()::text || '/current.jpg',
        tests.alice()::text || '/replaced.jpg'],
  'a removed photo is an orphan; a fresh upload still is not');

select tests.set_clock('2026-01-10 19:00:00+00');
select ok(tests.alice()::text || '/fresh.jpg' in (select * from public.avatar_orphans(100)),
  'an upload never saved as avatar_url is an orphan after an hour');

-- -------------------------------------------------------------- the hourly queue
select public.avatar_sweep_enqueue();
select is((select count(*)::int from public.jobs where kind = 'avatar_sweep'), 1,
  'the hourly enqueue adds nothing while a sweep is waiting');
update public.jobs set leased_until = '2026-01-10 19:05:00+00' where kind = 'avatar_sweep';
select public.avatar_sweep_enqueue();
select is((select count(*)::int from public.jobs where kind = 'avatar_sweep'), 2,
  'but queues one behind a sweep that is running');

select * from finish();
rollback;
