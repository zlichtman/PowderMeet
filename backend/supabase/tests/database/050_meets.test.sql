-- The meet protocol (specs/03-PROTOCOL.md): who may propose, respond, report
-- progress and end; the transition table; one open meet per user.
-- Rules out: a meet request (and push) to anyone, self-accept, rewriting
-- columns. Divergence scenarios D1, D2, D3, D7, D8, D9, D10, D11, D12.
begin;
select no_plan();

select tests.set_clock('2026-01-10 18:00:00+00');
select tests.publish_whistler();
select tests.befriend(tests.alice(), tests.bob());
select tests.befriend(tests.erin(), tests.bob());
select tests.befriend(tests.alice(), tests.dave());
insert into public.user_blocks (blocker_id, blocked_id) values (tests.alice(), tests.dave());
-- Everyone has a phone registered, so any push that is queued shows up.
insert into public.device_tokens (user_id, token, environment)
select u, md5(u::text), 'development'
from unnest(array[tests.alice(), tests.bob(), tests.carol(), tests.dave(), tests.erin()]) u;

-- ---------------------------------------------------------- who may propose
select tests.login(tests.carol());
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_non_friend_rejected (D9): a stranger cannot propose');
select tests.login(tests.dave());
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_blocked_rejected (D10): a blocked user cannot propose, and is told only not_friends');
select tests.login(tests.alice());
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.dave(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_blocked_rejected: nor can the blocker propose to them');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.carol(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'meet_to_non_friend_rejected: nor can anyone propose to a stranger');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.bob(),
      'vail', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'resort_not_published', 'a meet at an unpublished resort is refused');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000009', tests.bob(),
      'whistler-blackcomb', 'no-such-place', repeat('a', 64), 600, 60)$$,
  'P0001', 'rendezvous_unknown', 'I-01: a meet may end only at a rendezvous in the active bundle');
select throws_ok(
  $$insert into public.meets (meet_id, resort_id, rendezvous_id, proposer_id, invitee_id, status, expires_at)
    values ('10000000-0000-4000-8000-000000000009', 'whistler-blackcomb', 'roundhouse-lodge',
            tests.alice(), tests.carol(), 'proposed', now() + interval '1 day')$$,
  '42501', null, 'a client cannot insert a meet directly');

select tests.logout();
select is((select count(*)::int from public.meets), 0, 'no meet exists after the refused proposals');
select is((select count(*)::int from public.push_outbox), 0, 'D9: and no push was queued for anyone');

-- ------------------------------------------------------------------ propose
select tests.login(tests.alice());
select is(
  (public.meet_propose('10000000-0000-4000-8000-000000000001', tests.bob(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'proposed', 'a friend can propose');
select is(
  (select expires_at from public.meets where meet_id = '10000000-0000-4000-8000-000000000001'),
  '2026-01-10 18:30:00+00'::timestamptz, 'the proposal expires 30 minutes later, by server time');
select is(
  (public.meet_propose('10000000-0000-4000-8000-000000000001', tests.bob(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'proposed', 'meet_propose with the same meet_id is idempotent');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000002', tests.bob(),
      'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'meet_busy_proposer', 'I-23: the proposer cannot open a second meet');
select is((public.meet_current()).meet_id, '10000000-0000-4000-8000-000000000001'::uuid,
  'meet_current returns the open meet to the proposer');
select throws_ok(
  $$select public.meet_respond('10000000-0000-4000-8000-000000000001', true, 300, 30)$$,
  'P0001', 'invalid_state', 'sender_cannot_self_accept');
select throws_ok(
  $$update public.meets set status = 'active' where meet_id = '10000000-0000-4000-8000-000000000001'$$,
  '42501', null, 'participant_cannot_rewrite_meet_columns: the proposer cannot update the row');

select tests.login(tests.bob());
select is((select count(*)::int from public.meets), 1, 'the invitee reads the meet');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000001', tests.alice(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'meet_id_taken', 'someone else''s meet_id cannot be reused');
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000003', tests.alice(),
      'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'meet_busy_proposer', 'D1: both propose at once, the second proposal fails');
select throws_ok(
  $$update public.meets set rendezvous_id = 'rendezvous-lodge', invitee_eta_s = 1$$,
  '42501', null, 'participant_cannot_rewrite_meet_columns: nor can the invitee');
select throws_ok(
  $$delete from public.meets$$, '42501', null, 'a participant cannot delete the meet');
select throws_ok(
  $$select public.meet_end('10000000-0000-4000-8000-000000000001', 'user_cancelled')$$,
  'P0001', 'invalid_state', 'the invitee declines a proposal; only the proposer withdraws it');

select tests.login(tests.erin());
select throws_ok(
  $$select public.meet_propose('10000000-0000-4000-8000-000000000004', tests.bob(),
      'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'meet_busy_invitee', 'I-23: a user already in a meet cannot be invited to another');

select tests.login(tests.carol());
select is((select count(*)::int from public.meets), 0, 'a stranger reads no meet');
select ok((public.meet_current()).meet_id is null, 'meet_current is null for someone with no meet');
select throws_ok(
  $$select public.meet_respond('10000000-0000-4000-8000-000000000001', true, 300, 30)$$,
  'P0001', 'not_participant', 'a stranger cannot respond');
select throws_ok(
  $$select public.meet_end('10000000-0000-4000-8000-000000000001', 'user_cancelled')$$,
  'P0001', 'not_participant', 'a stranger cannot end the meet');

select tests.logout();
select is((select count(*)::int from public.meets where status in ('proposed', 'active')), 1,
  'D1: exactly one open meet exists');
select throws_ok(
  $$update public.meets set rendezvous_id = 'rendezvous-lodge'$$,
  'P0001', 'invalid_state', 'the trigger refuses a rewrite of the rendezvous from any role');
select throws_ok(
  $$update public.meets set status = 'completed', end_reason = 'arrived'$$,
  'P0001', 'invalid_state', 'proposed cannot jump to completed');
select throws_ok(
  $$insert into public.meets (meet_id, resort_id, rendezvous_id, proposer_id, invitee_id, status, expires_at)
    values ('10000000-0000-4000-8000-00000000000f', 'whistler-blackcomb', 'roundhouse-lodge',
            tests.carol(), tests.dave(), 'active', now())$$,
  'P0001', 'invalid_state', 'a meet cannot be born active, whoever inserts it');

-- ------------------------------------------------------- accept and progress
select tests.login(tests.bob());
select throws_ok(
  $$select public.meet_respond('10000000-0000-4000-8000-000000000001', false, null, null, 'bored')$$,
  'P0001', 'invalid_reason', 'an unknown decline reason is refused');
select is(
  (public.meet_respond('10000000-0000-4000-8000-000000000001', true, 900, 90)).status,
  'active', 'the invitee accepts');
select throws_ok(
  $$select public.meet_respond('10000000-0000-4000-8000-000000000001', true, 900, 90)$$,
  'P0001', 'meet_not_proposed', 'responding twice raises meet_not_proposed');
select lives_ok(
  $$select public.meet_progress_update('10000000-0000-4000-8000-000000000001', 800, 80, 2400,
      'navigating', '2026-01-10 18:01:00+00')$$,
  'a participant reports progress');
select throws_ok(
  $$insert into public.meet_progress (meet_id, user_id, state, fix_at)
    values ('10000000-0000-4000-8000-000000000001', tests.alice(), 'arrived', now())$$,
  '42501', null, 'D11: a participant cannot write the other participant''s progress');
select public.meet_progress_update('10000000-0000-4000-8000-000000000001', 1, 1, 1,
  'navigating', '2026-01-10 18:00:30+00');
select is((select eta_s from public.meet_progress where user_id = tests.bob()), 800,
  'a progress fix older than the stored one is ignored (I-19)');

select tests.login(tests.alice());
select is((select remaining_m from public.meet_progress where user_id = tests.bob()), 2400,
  'the other participant reads the progress');
select tests.login(tests.carol());
select is((select count(*)::int from public.meet_progress), 0, 'a stranger reads no progress');
select throws_ok(
  $$select public.meet_progress_update('10000000-0000-4000-8000-000000000001', 1, 1, 1,
      'arrived', '2026-01-10 18:02:00+00')$$,
  'P0001', 'not_participant', 'D11: a stranger cannot report progress');

-- ---------------------------------------------------------------------- end
select tests.login(tests.alice());
select throws_ok(
  $$select public.meet_end('10000000-0000-4000-8000-000000000001', 'timeout')$$,
  'P0001', 'invalid_reason', 'a client cannot end a meet with a server-only reason');
select is((public.meet_end('10000000-0000-4000-8000-000000000001', 'arrived')).status, 'completed',
  'either participant completes the meet on arrival');
select tests.login(tests.bob());
select is((public.meet_end('10000000-0000-4000-8000-000000000001', 'arrived')).end_reason, 'arrived',
  'D12: the second meet_end returns the same row');
select is((public.meet_end('10000000-0000-4000-8000-000000000001', 'user_cancelled')).status, 'completed',
  'a terminal meet never changes');
select throws_ok(
  $$select public.meet_progress_update('10000000-0000-4000-8000-000000000001', 0, 0, 0,
      'arrived', '2026-01-10 18:05:00+00')$$,
  'P0001', 'invalid_state', 'no progress on a finished meet');
select tests.logout();
select throws_ok(
  $$update public.meets set status = 'active', end_reason = null, ended_at = null$$,
  'P0001', 'invalid_state', 'the trigger refuses to reopen a terminal meet');

-- ------------------------------------- D2: accept after the proposer cancelled
select tests.set_clock('2026-01-10 18:10:00+00');
select tests.login(tests.alice());
select is(
  (public.meet_propose('20000000-0000-4000-8000-000000000001', tests.bob(),
     'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60)).status,
  'proposed', 'a new proposal is possible once the last meet ended');
select is((public.meet_end('20000000-0000-4000-8000-000000000001', 'user_cancelled')).status, 'cancelled',
  'the proposer withdraws it');
select tests.login(tests.bob());
select throws_ok(
  $$select public.meet_respond('20000000-0000-4000-8000-000000000001', true, 900, 90)$$,
  'P0001', 'meet_not_proposed', 'D2: accepting a cancelled proposal fails');
select ok((public.meet_current()).meet_id is null, 'D2: the invitee has no open meet');
select is((select status from public.meet_history(1)), 'cancelled', 'D2: and reads the outcome from history');

-- ------------------------------------------------ D3: invitee cannot route
select tests.set_clock('2026-01-10 18:20:00+00');
select tests.login(tests.alice());
select public.meet_propose('30000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select is(
  (public.meet_respond('30000000-0000-4000-8000-000000000001', false, null, null, 'declined_cannot_route')).end_reason,
  'declined_cannot_route', 'D3: the decline carries the reason');
select tests.login(tests.alice());
select is((select status from public.meets where meet_id = '30000000-0000-4000-8000-000000000001'), 'declined',
  'D3: the proposer reads it');

-- ------------------------------------------------------------ D8: supersede
select tests.set_clock('2026-01-10 18:30:00+00');
select public.meet_propose('40000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 600, 60);
select is(
  (public.meet_propose('40000000-0000-4000-8000-000000000002', tests.bob(),
     'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 500, 50,
     '40000000-0000-4000-8000-000000000001')).status,
  'proposed', 'D8: the proposer supersedes with a new rendezvous');
select results_eq(
  $$select status, end_reason, superseded_by from public.meets
    where meet_id = '40000000-0000-4000-8000-000000000001'$$,
  $$values ('invalidated'::text, 'superseded'::text, '40000000-0000-4000-8000-000000000002'::uuid)$$,
  'D8: the old proposal is invalidated and points at the new one');
select tests.login(tests.bob());
select is((public.meet_current()).rendezvous_id, 'rendezvous-lodge', 'D8: the invitee sees one open proposal');
select tests.login(tests.erin());
select throws_ok(
  $$select public.meet_propose('40000000-0000-4000-8000-000000000003', tests.bob(),
      'whistler-blackcomb', 'roundhouse-lodge', repeat('a', 64), 500, 50,
      '40000000-0000-4000-8000-000000000002')$$,
  'P0001', 'not_participant', 'only its proposer can supersede a meet');

-- ------------------------ D7: a new bundle is published without the rendezvous
select tests.logout();
select public.bundle_publish('whistler-blackcomb', repeat('b', 64), array['roundhouse-lodge'], '{}'::jsonb, 'tests');
select results_eq(
  $$select status, end_reason from public.meets where meet_id = '40000000-0000-4000-8000-000000000002'$$,
  $$values ('invalidated'::text, 'rendezvous_removed'::text)$$,
  'D7: the server invalidates a meet whose rendezvous left the active bundle');
select is(
  (select previous_bundle_id from public.resort_bundle_publications order by id desc limit 1),
  repeat('a', 64), 'the publication records the bundle it replaced');
select is((public.bundle_rollback('whistler-blackcomb', repeat('a', 64))).bundle_id, repeat('a', 64),
  'bundle_rollback re-points to an earlier bundle');
select throws_ok(
  $$select public.bundle_publish('whistler-blackcomb', repeat('c', 64), array['x'], '{}'::jsonb, 'tests')$$,
  'P0001', 'invalid', 'a bundle that was never registered cannot be published');

-- ------------------------------------------------- unfriend ends the open meet
select tests.set_clock('2026-01-10 18:40:00+00');
select tests.login(tests.alice());
select public.meet_propose('50000000-0000-4000-8000-000000000001', tests.bob(),
  'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 600, 60);
select tests.login(tests.bob());
select public.meet_respond('50000000-0000-4000-8000-000000000001', true, 900, 90);
select public.friend_remove(tests.alice());
select results_eq(
  $$select status, end_reason from public.meets where meet_id = '50000000-0000-4000-8000-000000000001'$$,
  $$values ('invalidated'::text, 'partner_left'::text)$$,
  'removing a friend ends the meet between them with partner_left');
select throws_ok(
  $$select public.meet_propose('50000000-0000-4000-8000-000000000002', tests.alice(),
      'whistler-blackcomb', 'rendezvous-lodge', repeat('a', 64), 600, 60)$$,
  'P0001', 'not_friends', 'and they can no longer propose to each other');
select is((select count(*)::int from public.meet_history()), 6, 'meet_history lists the caller''s meets');
select tests.login(tests.carol());
select is((select count(*)::int from public.meet_history()), 0, 'and nothing to a stranger');

-- -------------------------------------------------- pushes: the exact set
select tests.logout();
select set_eq(
  $$select distinct kind from public.push_outbox$$,
  array['meet.proposed', 'meet.accepted', 'meet.declined', 'meet.ended'],
  'meets queue only the kinds in the notification set');
select is(
  (select count(*)::int from public.push_outbox
   where kind = 'meet.proposed' and user_id = tests.bob()), 6,
  'each proposal pushes to the invitee');
select is(
  (select count(*)::int from public.push_outbox where kind = 'meet.proposed' and user_id <> tests.bob()), 0,
  'and to nobody else');
select is(
  (select count(*)::int from public.push_outbox where user_id in (tests.carol(), tests.dave(), tests.erin())), 0,
  'people outside a meet are never pushed about it');
select is(
  (select payload ->> 'partner_name' from public.push_outbox
   where kind = 'meet.accepted' and user_id = tests.alice() order by id limit 1),
  'Bob', 'the push payload names the other participant');
select is(
  (select count(*)::int from public.push_outbox
   where kind = 'meet.ended' and payload ->> 'end_reason' = 'superseded'), 0,
  'a superseded proposal does not push; the new proposal does');
select is(
  (select count(*)::int from public.push_outbox
   where kind = 'meet.ended' and payload ->> 'end_reason' = 'rendezvous_removed'), 2,
  'a server-side invalidation pushes to both participants');
select is(
  (select array_agg(user_id) from public.push_outbox
   where kind = 'meet.ended' and payload ->> 'end_reason' = 'partner_left'),
  array[tests.alice()], 'an ending caused by one participant pushes to the other only');

select * from finish();
rollback;
