-- Profiles, pace and descents as self, friend, stranger, blocked and pending.
-- Rules out: profiles and stats readable by everyone, find_users as an
-- enumeration oracle.
begin;
select no_plan();

-- alice: friend of bob, blocked dave (a stale friendship row is left in place
-- on purpose, to prove the block wins), pending request from erin, stranger
-- to carol.
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
insert into public.friendships (requester_id, addressee_id, status) values (tests.erin(), tests.alice(), 'pending');
update public.profiles
set ability = 'expert', current_resort_id = 'whistler-blackcomb',
    email_hash = repeat('a', 64),
    equipment = '{"discipline": "snowboard", "type": "freeride", "length_cm": 158}',
    avoid = '{flats}', max_pitch_deg = 30, height_cm = 178, weight_kg = 74
where id = tests.alice();
insert into public.pace_models (owner_id, difficulty_factor, stops_per_km, n_descents)
values (tests.alice(), '{"blue": 1.12}', 1.8, 4);

-- ------------------------------------------------------------- profiles
select tests.login(tests.alice());
select is((select ability from public.profiles where id = tests.alice()), 'expert', 'self reads own profile');
select throws_ok($$select email_hash from public.profiles where id = tests.alice()$$, '42501', null,
  'contact hashes are not readable through the API, even by their owner');

select throws_ok($$select height_cm from public.profiles where id = tests.alice()$$, '42501', null,
  'height is not a selectable column, even for its owner');
select is(public.profile_private(), '{"height_cm": 178, "weight_kg": 74}'::jsonb,
  'self reads own height and weight through profile_private');

select tests.login(tests.bob());
select is((select current_resort_id from public.profiles where id = tests.alice()), 'whistler-blackcomb',
  'a friend reads the profile, including the current resort');
select throws_ok($$select email_hash from public.profiles where id = tests.alice()$$, '42501', null,
  'a friend cannot read contact hashes');
select is(
  (select (equipment ->> 'discipline') || ' ' || avoid::text || ' ' || max_pitch_deg
   from public.profiles where id = tests.alice()),
  'snowboard {flats} 30', 'a friend reads equipment and limits: their phone routes this skier');
select throws_ok($$select height_cm from public.profiles where id = tests.alice()$$, '42501', null,
  'a friend cannot read height');
select throws_ok($$select weight_kg from public.profiles where id = tests.alice()$$, '42501', null,
  'a friend cannot read weight');
select is(public.profile_private(), '{"height_cm": null, "weight_kg": null}'::jsonb,
  'profile_private answers only for the caller: a friend gets their own, empty, values');

select tests.login(tests.carol());
select is((select count(*)::int from public.profiles where id = tests.alice()), 0,
  'stranger_cannot_read_profile_details: a stranger sees no profile row');
select is((select count(*)::int from public.profiles), 1, 'a stranger sees only their own profile');
select throws_ok($$select height_cm, weight_kg from public.profiles$$, '42501', null,
  'a stranger cannot read height or weight');

select tests.login(tests.dave());
select is((select count(*)::int from public.profiles where id = tests.alice()), 0,
  'a blocked user sees no profile row');
select throws_ok($$select height_cm, weight_kg from public.profiles$$, '42501', null,
  'a blocked user cannot read height or weight');
select is(public.profile_private() ->> 'height_cm', null,
  'and profile_private gives a blocked user nothing of anyone else''s');

select tests.login(tests.erin());
select is((select count(*)::int from public.profiles where id = tests.alice()), 0,
  'a pending request does not open the profile');
select is(public.social_snapshot() -> 'pending_out' -> 0 ->> 'display_name', 'Alice',
  'the requester still gets the name of the person they asked, through social_snapshot');

-- ----------------------------------------------------------------- pace
select tests.login(tests.alice());
select is((select count(*)::int from public.pace_models_friend_read where owner_id = tests.alice()), 1,
  'self reads own pace model');
select tests.login(tests.bob());
select is((select n_descents from public.pace_models_friend_read where owner_id = tests.alice()), 4,
  'a friend reads the pace model');
select tests.login(tests.carol());
select is((select count(*)::int from public.pace_models_friend_read), 0,
  'stranger_cannot_read_profile_stats_or_pace: the view is empty for a stranger');
select is((select count(*)::int from public.pace_models), 0,
  'stranger_cannot_read_profile_stats_or_pace: so is the table');
select tests.login(tests.dave());
select is((select count(*)::int from public.pace_models_friend_read), 0, 'a blocked user reads no pace model');
select tests.login(tests.erin());
select is((select count(*)::int from public.pace_models_friend_read), 0, 'a pending requester reads no pace model');

-- ------------------------------------------------------------- descents
select tests.login(tests.alice());
select results_eq(
  $$select created from public.descent_upsert(jsonb_build_object(
      'source', 'gpx', 'started_at', '2026-01-10T18:00:00Z', 'ended_at', '2026-01-10T18:10:00Z',
      'content_hash', repeat('1', 64), 'track', encode('track-bytes'::bytea, 'base64'),
      'resort_id', 'whistler-blackcomb',
      'match', jsonb_build_object('bundle_id', repeat('a', 64), 'matcher_version', 1,
        'coverage', 0.9, 'confidence', 0.8,
        'matched', jsonb_build_array(jsonb_build_object(
          'edge_id', 'w1:0', 'enter_at', '2026-01-10T18:00:00Z', 'exit_at', '2026-01-10T18:04:00Z',
          'moving_s', 200, 'stopped_s', 40)))))$$,
  $$values (true)$$, 'descent_upsert stores a new descent');
select results_eq(
  $$select created from public.descent_upsert(jsonb_build_object(
      'source', 'gpx', 'started_at', '2026-01-10T18:00:00Z', 'ended_at', '2026-01-10T18:10:00Z',
      'content_hash', repeat('1', 64), 'track', encode('track-bytes'::bytea, 'base64')))$$,
  $$values (false)$$, 'the same content hash is the same descent');
select results_eq(
  $$select created from public.descent_upsert(jsonb_build_object(
      'source', 'slopes', 'started_at', '2026-01-10T18:00:30Z', 'ended_at', '2026-01-10T18:10:00Z',
      'content_hash', repeat('2', 64), 'track', encode('other-bytes'::bytea, 'base64')))$$,
  $$values (false)$$, 'a recording that overlaps more than 80 % in time is the same descent');
select results_eq(
  $$select created from public.descent_upsert(jsonb_build_object(
      'source', 'gpx', 'started_at', '2026-01-10T19:00:00Z', 'ended_at', '2026-01-10T19:10:00Z',
      'content_hash', repeat('3', 64), 'track', encode('later-bytes'::bytea, 'base64')))$$,
  $$values (true)$$, 'a later run is a new descent');
select throws_ok(
  $$select * from public.descent_upsert('{"source": "gpx", "content_hash": "nope"}'::jsonb)$$,
  'P0001', 'invalid', 'a malformed descent is rejected');
select is((select count(*)::int from public.descents), 2, 'the owner reads their descents');
select is((select count(*)::int from public.descent_matches), 1, 'and the match');
select is((select elapsed_s::int from public.pace_observations), 240, 'and the per-edge observation derived from it');
select throws_ok(
  $$insert into public.descents (owner_id, source, started_at, ended_at, content_hash, track)
    values (tests.alice(), 'gpx', now(), now() + interval '1 minute', repeat('4', 64), 'x')$$,
  '42501', null, 'a client cannot insert a descent directly');

select tests.login(tests.bob());
select is((select count(*)::int from public.descents), 0, 'a friend cannot read raw descents');
select is((select count(*)::int from public.descent_matches), 0, 'or their matches');
select is((select count(*)::int from public.pace_observations), 0, 'or their observations');
select lives_ok(
  format('select public.descent_delete(%L)', '00000000-0000-4000-8000-000000000000'),
  'deleting a descent that is not yours is a no-op');
select tests.login(tests.carol());
select is((select count(*)::int from public.descents), 0, 'a stranger cannot read raw descents');

select tests.logout();
select is((select count(*)::int from public.descents where owner_id = tests.alice()), 2,
  'nobody else''s delete removed anything');
select is((select count(*)::int from public.jobs where kind = 'pace_recompute' and owner_id = tests.alice()), 1,
  'descent_upsert queues one pace_recompute job per owner');

-- ----------- find_users_capped_and_rate_limited_returns_minimal_columns
select tests.login(tests.carol());
select results_eq(
  $$select id, display_name, avatar_url from public.find_users(array[repeat('a', 64)], null)$$,
  $$values (tests.alice(), 'Alice'::text, null::text)$$,
  'find_users matches an email hash');
select is(
  (select array_agg(k.key order by k.key)
   from (select to_jsonb(f) as j from public.find_users(array[repeat('a', 64)], null) f) s
   cross join lateral jsonb_object_keys(s.j) as k(key)),
  array['avatar_url', 'display_name', 'id'],
  'find_users_capped_and_rate_limited_returns_minimal_columns: id, name and avatar only');
select throws_ok(
  format('select * from public.find_users(%L::text[], null)',
         (select array_agg(md5(g::text) || md5(g::text)) from generate_series(1, 51) g)),
  'P0001', 'invalid', 'find_users_capped_and_rate_limited_returns_minimal_columns: more than 50 hashes is refused');

select tests.login(tests.dave());
select is((select count(*)::int from public.find_users(array[repeat('a', 64)], null)), 1,
  'a blocked user matches the person who blocked them as anyone would, so the block stays hidden (0025)');
select is((select count(*)::int from public.profiles where id = tests.alice()), 0,
  'and the match opens nothing more than to a stranger');

select tests.login(tests.bob());
do $$
begin
  for i in 1 .. 20 loop
    perform * from public.find_users(array[repeat('a', 64)], null);
  end loop;
end;
$$;
select throws_ok(
  $$select * from public.find_users(array[repeat('a', 64)], null)$$,
  'P0001', 'rate_limited',
  'find_users_capped_and_rate_limited_returns_minimal_columns: the 21st call in a minute is refused');

-- -------------------------------------------------------- profile_update
select tests.login(tests.alice());
select is((public.profile_update('{"display_name": "  Al  ", "ability": "advanced"}')).display_name, 'Al',
  'profile_update changes whitelisted keys');
select is(
  (public.profile_update(jsonb_build_object('avatar_url', tests.alice()::text || '/me.jpg'))).avatar_url,
  tests.alice()::text || '/me.jpg', 'an avatar path under the caller''s own folder is accepted');
select throws_ok($$select public.profile_update('{"id": "a0000000-0000-4000-8000-00000000000b"}')$$,
  'P0001', 'invalid', 'a key outside the whitelist is refused');
select throws_ok($$select public.profile_update('{"avatar_url": "https://evil.example/pixel.png"}')$$,
  'P0001', 'invalid', 'an arbitrary avatar URL is refused');
select throws_ok(
  format('select public.profile_update(%L)', jsonb_build_object('avatar_url', tests.bob()::text || '/me.jpg')),
  'P0001', 'invalid', 'an avatar path under someone else''s folder is refused');
select throws_ok($$select public.profile_update('{"ability": "godlike"}')$$,
  'P0001', 'invalid', 'an invalid value is refused');
select is(
  (public.profile_update('{"equipment": {"discipline": "ski", "type": "all_mountain", "length_cm": 177, "waist_mm": 96},
    "avoid": ["park", "ungroomed", "park"], "max_pitch_deg": 28, "height_cm": 180, "weight_kg": null}')).avoid,
  '{park,ungroomed}'::text[], 'profile_update saves equipment, limits and body, and de-duplicates avoid');
select is(public.profile_private(), '{"height_cm": 180, "weight_kg": null}'::jsonb,
  'height is saved and weight cleared');
select is((public.profile_update('{"equipment": null, "max_pitch_deg": null}')).equipment, null,
  'equipment and the pitch limit can be cleared');
select throws_ok($$select public.profile_update('{"equipment": {"discipline": "sled", "type": "park"}}')$$,
  'P0001', 'invalid', 'an unknown discipline is refused');
select throws_ok($$select public.profile_update('{"equipment": {"discipline": "ski"}}')$$,
  'P0001', 'invalid', 'equipment without a type is refused');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "snowboard", "type": "park", "waist_mm": 90}}')$$,
  'P0001', 'invalid', 'a waist width on a snowboard is refused');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "ski", "type": "park", "length_cm": "long"}}')$$,
  'P0001', 'invalid', 'a length that is not a number is refused');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "ski", "type": "park", "brand": "x"}}')$$,
  'P0001', 'invalid', 'an unknown equipment key is refused');
select is(
  (public.profile_update('{"equipment": {"discipline": "ski", "type": "freeride", "waist_mm": 110,
    "ski": "atomic-bent-110", "skin": "stripes"}}')).equipment ->> 'ski',
  'atomic-bent-110', 'a catalog ski and a skin are saved');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "snowboard", "type": "park", "ski": "atomic-bent-110"}}')$$,
  'P0001', 'invalid', 'a ski model on a snowboard is refused');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "ski", "type": "park", "ski": "Atomic Bent 110"}}')$$,
  'P0001', 'invalid', 'a ski key that is not a slug is refused');
select throws_ok(
  $$select public.profile_update('{"equipment": {"discipline": "ski", "type": "park", "skin": "plaid"}}')$$,
  'P0001', 'invalid', 'an unknown skin is refused');
select is((public.profile_update('{"equipment": null}')).equipment, null, 'equipment is cleared again');
select throws_ok($$select public.profile_update('{"avoid": ["cliffs"]}')$$,
  'P0001', 'invalid', 'an unknown avoid choice is refused');
select throws_ok($$select public.profile_update('{"avoid": "park"}')$$,
  'P0001', 'invalid', 'avoid must be an array');
select throws_ok($$select public.profile_update('{"max_pitch_deg": 60}')$$,
  'P0001', 'invalid', 'a pitch limit out of range is refused');
select throws_ok($$select public.profile_update('{"height_cm": 20}')$$,
  'P0001', 'invalid', 'a height out of range is refused');
select throws_ok($$select public.profile_update('{"weight_kg": "heavy"}')$$,
  'P0001', 'invalid', 'a weight that is not a number is refused');
select throws_ok($$update public.profiles set display_name = 'x' where id = tests.alice()$$, '42501', null,
  'a client cannot update a profile directly');

-- -------------------------------------------------------- account_delete
select tests.login(tests.bob());
select lives_ok($$select public.account_delete()$$, 'account_delete succeeds');
select tests.logout();
select is((select count(*)::int from auth.users where id = tests.bob()), 0, 'the auth user is gone');
select is((select count(*)::int from public.profiles where id = tests.bob()), 0, 'so is the profile');
select is(
  (select count(*)::int from public.friendships where tests.bob() in (requester_id, addressee_id)), 0,
  'and every friendship');
select is((select count(*)::int from public.rate_limits where user_id = tests.bob()), 0,
  'and every other row the user owned');

select * from finish();
rollback;
