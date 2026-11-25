-- Local and CI only. Seed files are never applied to the hosted project.
--
-- Five fixed users for the pgTAP privacy matrix, and the helpers the suite
-- uses to act as one of them. The roles they play in most tests:
--   alice  self
--   bob    accepted friend of alice
--   carol  stranger
--   dave   blocked by alice
--   erin   has a pending request to alice
-- The relationships themselves are set up inside each test's transaction.

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'a0000000-0000-4000-8000-00000000000a', 'authenticated', 'authenticated',
   'alice@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Alice"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'b0000000-0000-4000-8000-00000000000b', 'authenticated', 'authenticated',
   'bob@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Bob"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-4000-8000-00000000000c', 'authenticated', 'authenticated',
   'carol@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Carol"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'd0000000-0000-4000-8000-00000000000d', 'authenticated', 'authenticated',
   'dave@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Dave"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'e0000000-0000-4000-8000-00000000000e', 'authenticated', 'authenticated',
   'erin@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Erin"}', now(), now())
on conflict (id) do nothing;

create schema if not exists tests;
grant usage on schema tests to anon, authenticated;

create or replace function tests.alice() returns uuid language sql immutable as $$ select 'a0000000-0000-4000-8000-00000000000a'::uuid $$;
create or replace function tests.bob()   returns uuid language sql immutable as $$ select 'b0000000-0000-4000-8000-00000000000b'::uuid $$;
create or replace function tests.carol() returns uuid language sql immutable as $$ select 'c0000000-0000-4000-8000-00000000000c'::uuid $$;
create or replace function tests.dave()  returns uuid language sql immutable as $$ select 'd0000000-0000-4000-8000-00000000000d'::uuid $$;
create or replace function tests.erin()  returns uuid language sql immutable as $$ select 'e0000000-0000-4000-8000-00000000000e'::uuid $$;

-- Act as a signed-in user for the rest of the transaction, the way PostgREST
-- does: the `authenticated` role plus the JWT claims auth.uid() reads.
create or replace function tests.login(p_user uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end;
$$;

-- Act as a signed-out client.
create or replace function tests.login_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('role', 'anon', true);
end;
$$;

-- Back to the test runner (table owner, no caller).
create or replace function tests.logout() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', true);
  perform set_config('request.jwt.claims', '', true);
end;
$$;

-- Pin or move server time for the rest of the transaction (see public.clock()).
create or replace function tests.set_clock(p_at timestamptz) returns void language plpgsql as $$
begin
  perform set_config('powdermeet.clock', p_at::text, true);
end;
$$;

-- An accepted friendship, made the only way the schema allows: pending, then
-- accepted. Run as the test runner.
create or replace function tests.befriend(a uuid, b uuid) returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  insert into public.friendships (requester_id, addressee_id, status)
  values (a, b, 'pending')
  returning id into v_id;
  update public.friendships set status = 'accepted' where id = v_id;
  return v_id;
end;
$$;

-- A published resort with an active bundle and two rendezvous. Run as the
-- test runner.
create or replace function tests.publish_whistler() returns void language plpgsql as $$
begin
  update public.resorts set published = true where id = 'whistler-blackcomb';
  insert into public.resort_bundles (bundle_id, resort_id, schema_version, manifest_version, extract_id,
                                     built_at, pipeline_version, size_bytes, integrity)
  values (repeat('a', 64), 'whistler-blackcomb', 1, 1, 'test-extract', now(), '0.0.0', 1, '{}'),
         (repeat('b', 64), 'whistler-blackcomb', 1, 2, 'test-extract', now(), '0.0.0', 1, '{}')
  on conflict (bundle_id) do nothing;
  perform public.bundle_publish('whistler-blackcomb', repeat('a', 64),
                                array['roundhouse-lodge', 'rendezvous-lodge'], '{}'::jsonb, 'tests');
end;
$$;
