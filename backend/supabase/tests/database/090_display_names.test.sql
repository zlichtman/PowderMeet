-- Display names (migration 0013): one normalisation, 2 to 24 characters,
-- unique ignoring case, a server-side block list, and a free placeholder
-- for new accounts. Rules out: the silent "Skier" default, two people with the
-- same name in different case, names made of invisible characters, and slurs.
--
-- The normalisation cases are mirrored in
-- packages/PowderMeetAPI/Tests/PowderMeetAPITests/DisplayNameTests.swift.
begin;
select no_plan();

-- ---------------------------------------------------------- normalisation
select is(public.display_name_normalize('  Al  '), 'Al', 'the ends are trimmed');
select is(public.display_name_normalize('Jo    Bloggs'), 'Jo Bloggs', 'runs of spaces collapse to one');
select is(public.display_name_normalize(E'Jo\tBloggs'), 'Jo Bloggs', 'a tab is a space');
select is(public.display_name_normalize(U&'Jo\00A0Bloggs'), 'Jo Bloggs', 'a no-break space is a space');
select is(public.display_name_normalize(U&'Ann\200Be'), 'Anne', 'a zero-width space is removed');
select is(public.display_name_normalize(U&'Ma\202Ex'), 'Max', 'a bidi override is removed');
select is(public.display_name_normalize(U&'Zo\00ADe'), 'Zoe', 'a soft hyphen is removed');
select is(public.display_name_normalize(U&'\FF3A\FF41\FF43\FF48'), 'Zach', 'full-width letters fold to ASCII');
select is(public.display_name_normalize(U&'\3164\3164'), '', 'a name of Hangul fillers is empty');
select is(public.display_name_normalize(U&'Jos\00E9'), U&'Jos\00E9', 'accented letters are kept');

-- ------------------------------------------------------------------ rules
select is(public.display_name_problem('A', null), 'invalid', 'one character is too short');
select is(public.display_name_problem(U&'A\200B', null), 'invalid', 'invisible padding does not count');
select is(public.display_name_problem(repeat('a', 25), null), 'invalid', '25 characters is too long');
select is(public.display_name_problem(repeat('a', 24), null), null, '24 characters is allowed');
select is(public.display_name_problem('Al', null), null, 'two characters is allowed');
select is(public.display_name_problem('N.I.G.G.E.R', null), 'name_not_allowed', 'display_name_normalised_and_blocked: punctuation does not hide a slur');
select is(public.display_name_problem('xxfaggot99', null), 'name_not_allowed', 'a substring entry matches inside a word');
select is(public.display_name_problem('n1gg3r', null), 'name_not_allowed', 'digit stand-ins are folded');
select is(public.display_name_problem('Big Spics', null), 'name_not_allowed', 'a whole-word entry matches its plural');
select is(public.display_name_problem('Ann Spicer', null), null, 'a whole-word entry does not match inside a name');
select is(public.display_name_problem('Jim Coonan', null), null, 'nor inside a surname');
select is(public.display_name_problem('ALICE', null), 'name_taken', 'a name in use is taken in any case');
select is(public.display_name_problem('ALICE', tests.alice()), null, 'except by its owner');

-- -------------------------------------------------------- unique index
select throws_ok($$update public.profiles set display_name = 'bob' where id = tests.carol()$$,
  '23505', null, 'display_name_unique_ignoring_case: the index refuses a name that differs only in case');

-- ---------------------------------------------------------- profile_update
select tests.login(tests.alice());
select is((public.profile_update('{"display_name": "  Alice   Smith "}')).display_name, 'Alice Smith',
  'profile_update stores the normalised name');
select is((public.profile_update('{"display_name": "alice smith"}')).display_name, 'alice smith',
  'the owner can change the case of their own name');

select tests.login(tests.bob());
select throws_ok($$select public.profile_update('{"display_name": "ALICE SMITH"}')$$,
  'P0001', 'name_taken', 'another user''s name is name_taken, ignoring case');
select throws_ok($$select public.profile_update('{"display_name": "x"}')$$,
  'P0001', 'invalid', 'a one-letter name is invalid');
select throws_ok($$select public.profile_update(jsonb_build_object('display_name', repeat('b', 25)))$$,
  'P0001', 'invalid', 'a 25-character name is invalid');
select throws_ok($$select public.profile_update('{"display_name": 42}')$$,
  'P0001', 'invalid', 'a name that is not a string is invalid');
select throws_ok($$select public.profile_update('{"display_name": "faggot99"}')$$,
  'P0001', 'name_not_allowed', 'a blocked word is name_not_allowed');
select is((select display_name from public.profiles where id = tests.bob()), 'Bob',
  'a refused name leaves the stored one alone');
select is((public.profile_update('{"display_name": "Bob", "ability": "expert"}')).ability, 'expert',
  'saving the same name again with other fields works');

-- ------------------------------------------------- display_name_available
select tests.login(tests.carol());
select is(public.display_name_available('Alice Smith'), 'name_taken', 'a name in use is reported taken');
select is(public.display_name_available('carol'), 'available', 'the caller''s own name is available to them');
select is(public.display_name_available('Fresh Powder'), 'available', 'a free name is available');
select is(public.display_name_available(' '), 'invalid', 'an empty name is invalid');
select is(public.display_name_available('n.i.g.g.e.r'), 'name_not_allowed', 'a slur is not allowed');

-- A blocked user and a stranger get the same answer as anyone: names are
-- what friends see, and the check says nothing about who holds one.
select tests.login(tests.dave());
select is(public.display_name_available('alice smith'), 'name_taken', 'the answer does not depend on who asks');

select tests.login(tests.erin());
do $$
begin
  for i in 1..60 loop
    perform public.display_name_available('Name ' || i);
  end loop;
end;
$$;
select throws_ok($$select public.display_name_available('One More')$$,
  'P0001', 'rate_limited', 'the 61st check in a minute is refused');

select tests.login_anon();
select throws_ok($$select public.display_name_available('Anyone')$$, '42501', null,
  'anon cannot check names');

-- ------------------------------------------------------- sign-up trigger
select tests.logout();
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at)
values
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000001', 'authenticated',
   'authenticated', 'f1@powdermeet.test', '', '{"provider":"email"}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000002', 'authenticated',
   'authenticated', 'f2@powdermeet.test', '', '{"provider":"email"}', '{"display_name":"ALICE SMITH"}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000003', 'authenticated',
   'authenticated', 'f3@powdermeet.test', '', '{"provider":"apple"}', '{"full_name":"  Gus   Grissom "}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000004', 'authenticated',
   'authenticated', 'f4@powdermeet.test', '', '{"provider":"email"}', '{"display_name":"hitler"}', now(), now());

select matches((select display_name from public.profiles where id = 'f0000000-0000-4000-8000-000000000001'),
  '^Skier [0-9]{6}$', 'a sign-up with no name gets a placeholder, not "Skier"');
select matches((select display_name from public.profiles where id = 'f0000000-0000-4000-8000-000000000002'),
  '^Skier [0-9]{6}$', 'a sign-up whose name is taken gets a placeholder');
select is((select display_name from public.profiles where id = 'f0000000-0000-4000-8000-000000000003'),
  'Gus Grissom', 'a free, valid name from sign-up is kept, normalised');
select matches((select display_name from public.profiles where id = 'f0000000-0000-4000-8000-000000000004'),
  '^Skier [0-9]{6}$', 'a blocked name from sign-up becomes a placeholder');
select is(
  (select count(distinct lower(display_name))::int from public.profiles
   where id in ('f0000000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000002',
                'f0000000-0000-4000-8000-000000000004')),
  3, 'placeholders are distinct');

select tests.login(tests.alice());
select throws_ok($$select word from public.display_name_blocked_words$$, '42501', null,
  'clients cannot read the block list');

select * from finish();
rollback;
