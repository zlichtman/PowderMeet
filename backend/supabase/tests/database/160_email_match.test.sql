-- The server-kept email hash (migration 0022).
-- Rules out: a new account that contacts cannot find, a hash that differs from
-- the one the app computes (trim, lowercase, SHA-256 hex), an Apple private
-- relay address being matchable, an email change leaving the old hash, a
-- shared address failing a sign-up, and a client writing the hash itself.
-- The expected hashes are `printf %s '<address>' | shasum -a 256`.
begin;
select no_plan();

-- --------------------------------------------------------------- sign-up
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'f3000000-0000-4000-8000-0000000000f3', 'authenticated', 'authenticated',
   '  Hana.Match@PowderMeet.TEST ', '', now(), '{"provider":"email","providers":["email"]}', '{"display_name":"Hana"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f4000000-0000-4000-8000-0000000000f4', 'authenticated', 'authenticated',
   'abc123@privaterelay.appleid.com', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Ivan"}', now(), now());

select is((select email_hash from public.profiles where id = 'f3000000-0000-4000-8000-0000000000f3'),
  '6f6d9398538405aa61faff903cd7b892d27ace3d17459fd5ef2c29e240f1ba84',
  'sign-up sets the hash of the trimmed, lowercased address, as the app computes it');
select is((select display_name from public.profiles where id = 'f3000000-0000-4000-8000-0000000000f3'), 'Hana',
  'the profile is created as before');
select is((select email_hash from public.profiles where id = 'f4000000-0000-4000-8000-0000000000f4'), null,
  'an Apple private relay address gets no hash');
select is((select email_hash from public.profiles where id = tests.alice()),
  public.email_hash_of('alice@powdermeet.test'), 'seeded accounts have their hash too');

-- ---------------------------------------------------------- email change
update auth.users set email = 'hana.new@powdermeet.test' where id = 'f3000000-0000-4000-8000-0000000000f3';
select is((select email_hash from public.profiles where id = 'f3000000-0000-4000-8000-0000000000f3'),
  '49a8931a103f09c89f81f45d7eee0b9a536918f36be4de1ba917846c669cbe63',
  'an email change replaces the hash');

-- ------------------------------------------------------- shared address
-- Bob already holds the hash of dup@; a new account with that address signs
-- up anyway and stays unmatched.
update public.profiles set email_hash = 'ab1a9b0e644f6874112056eb2a9c483a64cf791a2342bca95c7f4123edb3f989'
where id = tests.bob();
select lives_ok($$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', 'f5000000-0000-4000-8000-0000000000f5', 'authenticated',
          'authenticated', 'Dup@powdermeet.test', '', now(), '{"provider":"email","providers":["email"]}',
          '{"display_name":"Jo"}', now(), now())$$,
  'a sign-up whose address another account holds still succeeds');
select is((select email_hash from public.profiles where id = 'f5000000-0000-4000-8000-0000000000f5'), null,
  'the later account is left without a hash');
select is((select email_hash from public.profiles where id = tests.bob()),
  'ab1a9b0e644f6874112056eb2a9c483a64cf791a2342bca95c7f4123edb3f989', 'the earlier one keeps it');

-- ------------------------------------------------------------ discovery
select tests.login(tests.carol());
select results_eq(
  $$select id from public.find_users(array['49a8931a103f09c89f81f45d7eee0b9a536918f36be4de1ba917846c669cbe63'], '{}')$$,
  $$values ('f3000000-0000-4000-8000-0000000000f3'::uuid)$$,
  'find_users matches the server-kept hash');

-- --------------------------------------------------- the client cannot write it
select tests.login(tests.alice());
select lives_ok($$select public.profile_update(jsonb_build_object('email_hash', repeat('c', 64)))$$,
  'profile_update drops email_hash from older builds');
select lives_ok($$select public.profile_update('{"ability": "expert"}'::jsonb)$$,
  'profile_update still saves the other keys');
select tests.logout();
select is((select email_hash from public.profiles where id = tests.alice()),
  public.email_hash_of('alice@powdermeet.test'), 'the hash is unchanged');

select ok(not has_function_privilege('authenticated', 'public.email_hash_of(text)', 'EXECUTE'),
  'clients cannot call the hash helper');
select ok(not has_function_privilege('authenticated', 'public.profiles_email_hash_from_auth()', 'EXECUTE'),
  'clients cannot call the trigger function');

select * from finish();
rollback;
