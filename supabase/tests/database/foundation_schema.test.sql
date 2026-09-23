begin;

select plan(51);

select has_table('public', 'profiles', 'profiles foundation table exists');
select has_table('public', 'friendships', 'friendships foundation table exists');
select has_table('public', 'meet_requests', 'meet_requests foundation table exists');

select has_function(
  'public',
  'handle_new_user',
  array[]::text[],
  'signup profile trigger function exists'
);
select has_function(
  'public',
  'update_updated_at',
  array[]::text[],
  'profile timestamp trigger function exists'
);
select has_trigger(
  'auth',
  'users',
  'on_auth_user_created',
  'auth signup creates a profile'
);
select has_trigger(
  'public',
  'profiles',
  'profiles_updated_at',
  'profile updates stamp updated_at'
);

select is(
  (
    select count(*)
    from pg_tables
    where schemaname = 'public'
      and not rowsecurity
      and tablename <> 'spatial_ref_sys'
  ),
  0::bigint,
  'every application-owned public table has RLS enabled'
);
select is(
  (
    select count(*)
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename in ('friendships', 'meet_requests', 'live_presence')
  ),
  3::bigint,
  'all three social tables are in the realtime publication'
);
select is(
  (
    select count(*)
    from pg_policies
    where schemaname = 'public'
      and tablename = 'meet_requests'
      and policyname = 'Users can respond to meet requests'
  ),
  0::bigint,
  'superseded receiver-only meet update policy is absent'
);
select is(
  (select count(*) from storage.buckets where id = 'avatars'),
  1::bigint,
  'avatars bucket exists'
);

select has_table(
  'public',
  'resort_canonical_publication',
  'canonical publication history exists'
);
select has_table(
  'public',
  'resort_canonical_active',
  'canonical active pointer exists'
);
select has_function(
  'public',
  'publish_canonical_manifest',
  array['text', 'integer', 'text', 'date', 'text'],
  'atomic canonical publication RPC exists'
);
select has_sequence(
  'public',
  'social_snapshot_generation_seq',
  'social snapshot generation sequence exists'
);
select ok(
  has_sequence_privilege(
    'authenticated',
    'public.social_snapshot_generation_seq',
    'USAGE'
  ),
  'authenticated snapshot callers can advance the sequence'
);
select ok(
  exists (
    select 1
    from supabase_migrations.schema_migrations
    where version = '20260301000000'
  ),
  'foundation migration is recorded'
);

select lives_ok(
  $$
    insert into auth.users (id, email, raw_user_meta_data)
    values (
      '00000000-0000-4000-8000-000000000001',
      'foundation-one@powdermeet.local',
      '{"display_name":"Foundation One"}'::jsonb
    )
  $$,
  'first synthetic signup succeeds'
);
select is(
  (
    select display_name
    from public.profiles
    where id = '00000000-0000-4000-8000-000000000001'
  ),
  'Foundation One'::text,
  'signup trigger copies the display name into profiles'
);
select lives_ok(
  $$
    insert into auth.users (id, email, raw_user_meta_data)
    values (
      '00000000-0000-4000-8000-000000000002',
      'foundation-two@powdermeet.local',
      '{"display_name":"Foundation Two"}'::jsonb
    )
  $$,
  'second synthetic signup succeeds'
);

select lives_ok(
  $$
    insert into public.friendships (
      id, requester_id, addressee_id, status
    ) values (
      '00000000-0000-4000-8000-000000000101',
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
      'pending'
    )
  $$,
  'pending friendship can be created'
);
select lives_ok(
  $$
    update public.friendships
    set status = 'accepted'
    where id = '00000000-0000-4000-8000-000000000101'
  $$,
  'pending friendship can be accepted'
);
select throws_ok(
  $$
    update public.friendships
    set status = 'pending'
    where id = '00000000-0000-4000-8000-000000000101'
  $$,
  '23514',
  'invalid friendships status transition: accepted -> pending',
  'accepted friendship cannot move backwards'
);

select lives_ok(
  $$
    insert into public.meet_requests (
      id,
      sender_id,
      receiver_id,
      resort_id,
      meeting_node_id,
      status
    ) values (
      '00000000-0000-4000-8000-000000000201',
      '00000000-0000-4000-8000-000000000001',
      '00000000-0000-4000-8000-000000000002',
      'foundation-resort',
      'foundation-node',
      'pending'
    )
  $$,
  'pending meet request can be created'
);
select lives_ok(
  $$
    update public.meet_requests
    set status = 'accepted'
    where id = '00000000-0000-4000-8000-000000000201'
  $$,
  'pending meet request can be accepted'
);
select throws_ok(
  $$
    update public.meet_requests
    set status = 'pending'
    where id = '00000000-0000-4000-8000-000000000201'
  $$,
  '23514',
  'invalid meet_requests status transition: accepted -> pending',
  'accepted meet request cannot move backwards'
);

select set_config(
  'request.jwt.claim.sub',
  '00000000-0000-4000-8000-000000000001',
  true
);
select lives_ok(
  $$select public.get_social_snapshot(null::text)$$,
  'authenticated-shaped social snapshot executes with a generation stamp'
);

select has_column(
  'public',
  'profile_edge_speeds',
  'equipment_key',
  'edge-speed learning retains its equipment cohort'
);
select ok(
  (
    select attnotnull
    from pg_attribute
    where attrelid = 'public.profile_edge_speeds'::regclass
      and attname = 'equipment_key'
      and not attisdropped
  ),
  'equipment cohort cannot be null'
);
select is(
  (
    select pg_get_expr(adbin, adrelid)
    from pg_attrdef
    where adrelid = 'public.profile_edge_speeds'::regclass
      and adnum = (
        select attnum
        from pg_attribute
        where attrelid = 'public.profile_edge_speeds'::regclass
          and attname = 'equipment_key'
      )
  ),
  '''neutral''::text'::text,
  'legacy edge-speed rows default to the neutral equipment cohort'
);
select is(
  (
    select array_agg(att.attname order by key_column.ordinality)
    from pg_constraint constraint_row
    cross join lateral unnest(constraint_row.conkey)
      with ordinality as key_column(attnum, ordinality)
    join pg_attribute att
      on att.attrelid = constraint_row.conrelid
     and att.attnum = key_column.attnum
    where constraint_row.conrelid = 'public.profile_edge_speeds'::regclass
      and constraint_row.contype = 'p'
  ),
  array[
    'profile_id',
    'resort_id',
    'edge_id',
    'conditions_fp',
    'equipment_key'
  ]::name[],
  'edge-speed primary key separates equipment cohorts'
);

select has_column(
  'public',
  'imported_runs',
  'edge_observations',
  'runs retain exact edge-local pace evidence'
);
select ok(
  (
    select attnotnull
    from pg_attribute
    where attrelid = 'public.imported_runs'::regclass
      and attname = 'edge_observations'
      and not attisdropped
  ),
  'edge observations cannot be null'
);
select is(
  (
    select pg_get_expr(adbin, adrelid)
    from pg_attrdef
    where adrelid = 'public.imported_runs'::regclass
      and adnum = (
        select attnum
        from pg_attribute
        where attrelid = 'public.imported_runs'::regclass
          and attname = 'edge_observations'
      )
  ),
  '''[]''::jsonb'::text,
  'legacy rows safely default to no exact edge observations'
);
select is(
  public.valid_edge_pace_observations(
    '[{"edge_id":"edge-a","conditions_fp":"default","speed_ms":8,"peak_speed_ms":10,"duration_s":20,"distance_m":160}]'::jsonb
  ),
  true,
  'well-formed edge pace evidence passes ingress validation'
);
select is(
  public.valid_edge_pace_observations(
    '[{"edge_id":"edge-a","conditions_fp":"default","speed_ms":8,"peak_speed_ms":10,"duration_s":20,"distance_m":160},{"edge_id":"edge-a","conditions_fp":"default","speed_ms":9,"peak_speed_ms":11,"duration_s":20,"distance_m":180}]'::jsonb
  ),
  false,
  'duplicate edge attribution inside one run fails closed'
);
select is(
  public.edge_pace_observations_match_segments(
    '[{"edge_id":"edge-a","conditions_fp":"default","speed_ms":8,"peak_speed_ms":10,"duration_s":20,"distance_m":160}]'::jsonb,
    array['edge-b']
  ),
  false,
  'pace evidence cannot claim an edge outside the accepted run sequence'
);

select lives_ok(
  $$
    insert into public.imported_runs (
      profile_id,
      resort_id,
      edge_id,
      difficulty,
      speed_ms,
      duration_s,
      vertical_m,
      run_at,
      dedup_hash,
      dataset_version,
      matched_segment_ids,
      match_confidence,
      match_method,
      equipment_id_at_activity
    ) values
      (
        '00000000-0000-4000-8000-000000000001',
        'equipment-test',
        'equipment-edge',
        'blue',
        8,
        100,
        100,
        now(),
        'equipment-a',
        'equipment-dataset',
        array['equipment-edge'],
        1,
        'polyline_sequence',
        '10000000-0000-4000-8000-000000000001'
      ),
      (
        '00000000-0000-4000-8000-000000000001',
        'equipment-test',
        'equipment-edge',
        'blue',
        12,
        100,
        100,
        now(),
        'equipment-b',
        'equipment-dataset',
        array['equipment-edge'],
        1,
        'polyline_sequence',
        '20000000-0000-4000-8000-000000000002'
      ),
      (
        '00000000-0000-4000-8000-000000000001',
        'equipment-test',
        'equipment-edge',
        'blue',
        10,
        100,
        100,
        now(),
        'equipment-neutral',
        'equipment-dataset',
        array['equipment-edge'],
        1,
        'polyline_sequence',
        null
      )
  $$,
  'equipment provenance fixtures insert'
);
select lives_ok(
  $$
    select public.recompute_profile_edge_speeds(
      '00000000-0000-4000-8000-000000000001'
    );
    select public.recompute_profile_edge_speeds(
      '00000000-0000-4000-8000-000000000001'
    )
  $$,
  'equipment-conditioned speed recompute is idempotent'
);
select is(
  (
    select count(*)
    from public.profile_edge_speeds
    where profile_id = '00000000-0000-4000-8000-000000000001'
      and resort_id = 'equipment-test'
      and edge_id = 'equipment-edge'
  ),
  3::bigint,
  'one edge retains two ski-specific cohorts and one neutral cohort'
);
select is(
  (
    select string_agg(
      equipment_key || '=' || rolling_speed_ms::text,
      ','
      order by equipment_key
    )
    from public.profile_edge_speeds
    where profile_id = '00000000-0000-4000-8000-000000000001'
      and resort_id = 'equipment-test'
      and edge_id = 'equipment-edge'
  ),
  '10000000-0000-4000-8000-000000000001=8,20000000-0000-4000-8000-000000000002=12,neutral=10'::text,
  'equipment cohorts preserve independent learned speeds'
);

select lives_ok(
  $$
    insert into public.imported_runs (
      profile_id,
      resort_id,
      edge_id,
      difficulty,
      speed_ms,
      peak_speed_ms,
      duration_s,
      vertical_m,
      run_at,
      dedup_hash,
      dataset_version,
      matched_segment_ids,
      edge_observations,
      match_confidence,
      match_method
    ) values
      (
        '00000000-0000-4000-8000-000000000001',
        'edge-attribution-test',
        'fast-edge',
        'blue',
        9,
        16,
        60,
        100,
        now(),
        'precise-multi-edge',
        'edge-attribution-dataset',
        array['fast-edge', 'slow-edge'],
        '[
          {"edge_id":"fast-edge","conditions_fp":"groomed","speed_ms":14,"peak_speed_ms":16,"duration_s":20,"distance_m":280},
          {"edge_id":"slow-edge","conditions_fp":"moguls","speed_ms":4,"peak_speed_ms":6,"duration_s":40,"distance_m":160}
        ]'::jsonb,
        1,
        'polyline_sequence'
      ),
      (
        '00000000-0000-4000-8000-000000000001',
        'edge-attribution-test',
        'fast-edge',
        'blue',
        20,
        25,
        30,
        100,
        now(),
        'legacy-multi-edge',
        'edge-attribution-dataset',
        array['fast-edge', 'slow-edge'],
        '[]'::jsonb,
        1,
        'polyline_sequence'
      )
  $$,
  'precise and legacy multi-edge fixtures insert'
);
select lives_ok(
  $$
    select public.recompute_profile_edge_speeds(
      '00000000-0000-4000-8000-000000000001'
    )
  $$,
  'edge-attributed speed recompute succeeds'
);
select is(
  (
    select count(*)
    from public.profile_edge_speeds
    where profile_id = '00000000-0000-4000-8000-000000000001'
      and resort_id = 'edge-attribution-test'
  ),
  2::bigint,
  'one physical multi-edge run emits exactly two learned edge rows'
);
select is(
  (
    select string_agg(
      edge_id || '=' || conditions_fp || '=' || rolling_speed_ms::text,
      ','
      order by edge_id
    )
    from public.profile_edge_speeds
    where profile_id = '00000000-0000-4000-8000-000000000001'
      and resort_id = 'edge-attribution-test'
  ),
  'fast-edge=groomed=14,slow-edge=moguls=4'::text,
  'each edge learns its own timed pace while legacy multi-edge fan-out is ignored'
);

-- Activity data is owner-scoped (20260923170000_owner_scoped_activity_data).
select policies_are(
  'public',
  'imported_runs',
  array[
    'imported_runs_delete_own',
    'imported_runs_insert_own',
    'imported_runs_select_own',
    'imported_runs_update_own'
  ],
  'imported_runs has no public read policy'
);

set local role anon;
set local request.jwt.claims = '{"role":"anon"}';
select is(
  (select count(*) from public.imported_runs),
  0::bigint,
  'anon cannot read anyone''s imported runs'
);
select throws_ok(
  $$ select public.recompute_profile_stats('00000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'anon cannot trigger a stats recompute'
);

set local role authenticated;
set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(
  (
    select count(*)
    from public.imported_runs
    where profile_id = '00000000-0000-4000-8000-000000000001'
  ),
  0::bigint,
  'a signed-in user cannot read another user''s imported runs'
);
select throws_ok(
  $$ select public.recompute_profile_edge_speeds('00000000-0000-4000-8000-000000000001') $$,
  '42501',
  null,
  'a signed-in user cannot recompute another user''s edge speeds'
);

set local request.jwt.claims =
  '{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}';
select lives_ok(
  $$ select public.recompute_profile_stats('00000000-0000-4000-8000-000000000001') $$,
  'the owner can still recompute their own stats'
);
reset role;

select * from finish();

rollback;
