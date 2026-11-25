-- Search by name (migration 0019) as self, friend, stranger and blocked.
-- Rules out: finding yourself, finding someone you blocked, search telling
-- someone they were blocked,
-- accounts that never finished onboarding being listed, a wildcard in the query
-- matching everyone, search returning anything beyond the name and photo, and
-- anon reaching it at all.
begin;
select no_plan();

-- Two more people besides the five seeded ones, and one account still on its
-- sign-up placeholder (no name in the metadata).
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-00000000000f', 'authenticated', 'authenticated',
   'frank@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Frank"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f1000000-0000-4000-8000-0000000000f1', 'authenticated', 'authenticated',
   'gina@powdermeet.test', '', now(), '{"provider":"apple","providers":["apple"]}', '{"display_name":"Gina Frankel"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f2000000-0000-4000-8000-0000000000f2', 'authenticated', 'authenticated',
   'new@powdermeet.test', '', now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());

-- alice: friends with bob, blocked dave, blocked by carol, has erin's request,
-- has sent one to gina; frank is a stranger.
select tests.befriend(tests.alice(), tests.bob());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.carol(), tests.alice());
insert into public.friendships (requester_id, addressee_id, status) values (tests.erin(), tests.alice(), 'pending');
insert into public.friendships (requester_id, addressee_id, status)
values (tests.alice(), 'f1000000-0000-4000-8000-0000000000f1', 'pending');
update public.profiles set avatar_url = tests.bob()::text || '/photo.jpg' where id = tests.bob();

select ok(public.display_name_is_placeholder(
            (select display_name from public.profiles where id = 'f2000000-0000-4000-8000-0000000000f2')),
  'the account with no name is on its placeholder');

-- ------------------------------------------------------------------ shape
select is(pg_get_function_result('public.search_users(text)'::regprocedure),
  'TABLE(user_id uuid, display_name text, avatar_url text, relation text)',
  'search returns the id, name, photo path and relation, and nothing else');

-- ------------------------------------------------------------------ self
select tests.login(tests.alice());
select is((select count(*)::int from public.search_users('alice')), 0,
  'search_never_lists_self: your own name finds nobody');

-- ---------------------------------------------------------------- friend
select results_eq($$select user_id, display_name, avatar_url, relation from public.search_users('bo')$$,
  $$values (tests.bob(), 'Bob'::text, tests.bob()::text || '/photo.jpg', 'friend'::text)$$,
  'a friend is found by a prefix of their name, with their photo, as a friend');
select is((select relation from public.search_users('  BOB  ')), 'friend',
  'the query is trimmed and case does not matter');

-- ----------------------------------------------------- requests either way
select is((select relation from public.search_users('erin')), 'request_received',
  'someone who sent you a request reads as request_received');
select is((select relation from public.search_users('gina')), 'request_sent',
  'someone you asked reads as request_sent');

-- -------------------------------------------------------------- stranger
select results_eq($$select user_id, relation from public.search_users('fran')$$,
  $$values ('f0000000-0000-4000-8000-00000000000f'::uuid, 'none'::text),
           ('f1000000-0000-4000-8000-0000000000f1'::uuid, 'request_sent'::text)$$,
  'a stranger reads as none; a prefix match comes before a match inside the name');

-- --------------------------------------------------------------- blocked
-- 0025: the person blocked must not be able to tell, so they find the
-- blocker as a stranger would; the blocker never sees them.
select is((select count(*)::int from public.search_users('dave')), 0,
  'search_hides_blocked: someone you blocked is not listed');
select results_eq($$select user_id, relation from public.search_users('carol')$$,
  $$values (tests.carol(), 'none'::text)$$,
  'someone who blocked you is listed as a stranger, so the block stays hidden');
select tests.login(tests.dave());
select results_eq($$select user_id, relation from public.search_users('alice')$$,
  $$values (tests.alice(), 'none'::text)$$,
  'the blocked user finds the blocker as anyone would');
select tests.login(tests.carol());
select is((select count(*)::int from public.search_users('alice')), 0,
  'and the blocked user from the blocker');
select is((select relation from public.search_users('bob')), 'none',
  'carol still finds people she has no block with');

-- ----------------------------------------------------------- placeholder
select tests.login(tests.alice());
select is((select count(*)::int from public.search_users('skier')), 0,
  'search_skips_placeholder_names: an account that has not chosen a name is not listed');
select tests.logout();
update public.profiles set display_name = 'Skier Sam' where id = 'f0000000-0000-4000-8000-00000000000f';
select tests.login(tests.alice());
select results_eq($$select user_id from public.search_users('skier')$$,
  $$values ('f0000000-0000-4000-8000-00000000000f'::uuid)$$,
  'a real name that starts with Skier is listed');

-- ------------------------------------------------------------- wildcards
select tests.logout();
update public.profiles set display_name = 'Erin 50%' where id = tests.erin();
update public.profiles set display_name = 'Bo_b' where id = tests.bob();
select tests.login(tests.alice());
select is((select count(*)::int from public.search_users('%%')), 0,
  'search_escapes_wildcards: a query of percent signs matches no one');
select is((select count(*)::int from public.search_users('__')), 0,
  'nor one of underscores');
select results_eq($$select user_id from public.search_users('0%')$$,
  $$values (tests.erin())$$, 'a percent sign in a query matches a literal percent sign');
select is((select count(*)::int from public.search_users('a_f')), 0,
  'an underscore is not a wildcard (it would match the space in Gina Frankel)');
select results_eq($$select user_id from public.search_users('o_b')$$,
  $$values (tests.bob())$$, 'it matches a literal underscore');
select is((select count(*)::int from public.search_users('a\')), 0,
  'a backslash is taken literally too');

-- ----------------------------------------------------------- short query
select is((select count(*)::int from public.search_users('b')), 0,
  'a one-character query returns nothing');
select is((select count(*)::int from public.search_users(U&'b\200B ')), 0,
  'invisible padding does not lengthen it');
select is((select count(*)::int from public.search_users(null)), 0, 'nor does a null query');

-- ----------------------------------------------------------------- limit
select tests.logout();
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
select '00000000-0000-0000-0000-000000000000', gen_random_uuid(), 'authenticated', 'authenticated',
       'mogul' || n || '@powdermeet.test', '', now(), '{"provider":"email","providers":["email"]}',
       jsonb_build_object('display_name', 'Mogul ' || lpad(n::text, 2, '0')), now(), now()
from generate_series(1, 25) n;
select tests.login(tests.alice());
select is((select count(*)::int from public.search_users('mogul')), 20, 'at most 20 people come back');
select is((select display_name from public.search_users('mogul') limit 1), 'Mogul 01', 'in name order');

-- ------------------------------------------------------------ rate limit
select tests.login('f1000000-0000-4000-8000-0000000000f1');
do $$
begin
  for i in 1..60 loop
    perform public.search_users('frank');
  end loop;
end;
$$;
select throws_ok($$select public.search_users('frank')$$, 'P0001', 'rate_limited',
  'the 61st search in a minute is refused');

-- ------------------------------------------------------------------ anon
select tests.login_anon();
select throws_ok($$select * from public.search_users('alice')$$, '42501', null, 'anon cannot search');
select throws_ok($$select public.display_name_is_placeholder('Skier 123456')$$, '42501', null,
  'or call the placeholder helper');
select tests.login(tests.alice());
select throws_ok($$select public.display_name_is_placeholder('Skier 123456')$$, '42501', null,
  'nor can a signed-in user');

select * from finish();
rollback;
