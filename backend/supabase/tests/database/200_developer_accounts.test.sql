-- developer_accounts and is_developer() (0027).
-- Rules out: the Dev page opening for someone not on the list
-- (developer_only_when_listed), and a client reading or writing the list
-- (developer_list_closed_to_clients).
begin;
select no_plan();

insert into public.developer_accounts (user_id) values (tests.alice());

select ok((select relrowsecurity from pg_class where oid = 'public.developer_accounts'::regclass),
  'developer_accounts has row level security on');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'developer_accounts'), 0,
  'developer_accounts has no policy');

select tests.login(tests.alice());
select is(public.is_developer(), true, 'developer_only_when_listed: a listed user is a developer');
select throws_ok($$select user_id from public.developer_accounts$$, '42501', null,
  'developer_list_closed_to_clients: a listed user cannot read the table');
select throws_ok($$insert into public.developer_accounts (user_id) values (tests.bob())$$, '42501', null,
  'developer_list_closed_to_clients: a client cannot add themselves or anyone');

select tests.login(tests.bob());
select is(public.is_developer(), false, 'developer_only_when_listed: an unlisted user is not a developer');
select throws_ok($$select user_id from public.developer_accounts$$, '42501', null,
  'developer_list_closed_to_clients: an unlisted user cannot read the table');
select throws_ok($$insert into public.developer_accounts (user_id) values (tests.bob())$$, '42501', null,
  'developer_list_closed_to_clients: an unlisted user cannot insert');

select tests.login_anon();
select throws_ok($$select public.is_developer()$$, '42501', null, 'anon cannot call is_developer');
select throws_ok($$select user_id from public.developer_accounts$$, '42501', null,
  'anon cannot read the developer list');

select tests.logout();
delete from auth.users where id = tests.alice();
select is((select count(*)::int from public.developer_accounts), 0,
  'deleting the account removes the listing');

select * from finish();
rollback;
