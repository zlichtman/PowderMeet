-- Reporting a user (migration 0017) as self, friend, stranger and blocked.
-- Rules out: reading or editing reports from the app, reporting yourself,
-- unbounded report spam, and a report blocking account deletion.
begin;
select no_plan();

select tests.befriend(tests.alice(), tests.bob());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
insert into public.friendships (requester_id, addressee_id, status) values (tests.erin(), tests.alice(), 'pending');
update public.profiles set avatar_url = tests.dave()::text || '/photo.jpg' where id = tests.dave();

-- --------------------------------------------------------------- reports
select tests.login(tests.alice());
select lives_ok($$select public.report_user(tests.bob(), 'harassment', 'Rude in chat', 'friend')$$,
  'a friend can be reported');
select lives_ok($$select public.report_user(tests.carol(), 'spam', null, 'contact')$$,
  'a stranger (a contact match) can be reported');
select lives_ok($$select public.report_user(tests.erin(), 'inappropriate_name', '   ', 'request')$$,
  'so can whoever sent a request; a blank note is no note');
select lives_ok($$select public.report_user(tests.dave(), 'inappropriate_photo')$$,
  'and someone already blocked');

select throws_ok($$select public.report_user(tests.alice(), 'spam')$$, 'P0001', 'invalid',
  'nobody can report themselves');
select throws_ok($$select public.report_user('f0000000-0000-4000-8000-0000000000ff', 'spam')$$, 'P0001', 'invalid',
  'an unknown user cannot be reported');
select throws_ok($$select public.report_user(tests.bob(), 'rude')$$, 'P0001', 'invalid',
  'a reason outside the list is refused');
select throws_ok($$select public.report_user(tests.bob(), 'other', repeat('x', 501))$$, 'P0001', 'invalid',
  'a note over 500 characters is refused');
select throws_ok($$select public.report_user(tests.bob(), 'other', null, 'map')$$, 'P0001', 'invalid',
  'an unknown context is refused');

-- -------------------------------------------------------------- no reads
select throws_ok($$select id from public.user_reports$$, '42501', null,
  'reports_written_only_through_report_user: the reporter cannot read reports, their own included');
select throws_ok($$update public.user_reports set note = 'x'$$, '42501', null, 'or change them');
select throws_ok($$delete from public.user_reports$$, '42501', null, 'or delete them');
select tests.login(tests.bob());
select throws_ok($$select id from public.user_reports$$, '42501', null, 'the reported user cannot read them');

select tests.logout();
select is((select count(*)::int from public.user_reports where reporter_id = tests.alice()), 4,
  'four reports were stored');
select is((select note from public.user_reports where reported_id = tests.erin()), null,
  'the blank note was stored as none');
select is((select reported_avatar_url from public.user_reports where reported_id = tests.dave()),
  tests.dave()::text || '/photo.jpg', 'the reported photo path is kept with the report');
select is((select reported_name from public.user_reports where reported_id = tests.bob()), 'Bob',
  'and the reported name');

-- ------------------------------------------------------------ rate limit
select tests.login(tests.alice());
do $$
begin
  for i in 1..6 loop
    perform public.report_user(tests.carol(), 'spam');
  end loop;
end;
$$;
select throws_ok($$select public.report_user(tests.carol(), 'spam')$$, 'P0001', 'rate_limited',
  'the eleventh report in an hour is refused');

select tests.login_anon();
select throws_ok($$select public.report_user(tests.bob(), 'spam')$$, '42501', null, 'anon cannot report');

-- ------------------------------------------------------- account deletion
-- dave is reported and erin is a reporter; both can still delete their
-- accounts. A report on a deleted account goes with it, since it holds their
-- name, photo and what was said about them (0025); a report the deleted user
-- filed stays, without their id.
select tests.login(tests.erin());
select lives_ok($$select public.report_user(tests.bob(), 'other')$$, 'erin reports bob');
select lives_ok($$select public.account_delete()$$, 'a reporter can delete their account');
select tests.login(tests.dave());
select lives_ok($$select public.account_delete()$$, 'a reported user can delete their account');
select tests.logout();
select is((select count(*)::int from public.user_reports where reported_name = 'Dave' or reported_id is null), 0,
  'reports_hold_no_deleted_account: the report on dave is gone with his account');
select is((select count(*)::int from public.user_reports where reporter_id is null and reported_id = tests.bob()), 1,
  'reports_survive_reporter_deletion: erin''s report stays, without her id');

select * from finish();
rollback;
