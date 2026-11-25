-- Reporting a user (App Store guideline 1.2; specs/04-SCHEMA.md sections 2 and 6).
--
-- Additive: one table and one RPC. A report is written only through
-- `report_user`, which is rate limited; no client role can read, change or
-- delete a report, its own included. The reported name and photo path are
-- copied into the row, so what was reported survives a later rename or a new
-- photo. Reports outlive both accounts: deleting either one clears its id and
-- keeps the row. Reports are reviewed by the owner in the dashboard, where
-- `reviewed_at` and `review_note` record the outcome.

create table public.user_reports (
  id bigint generated always as identity primary key,
  reporter_id uuid references public.profiles (id) on delete set null,
  reported_id uuid references public.profiles (id) on delete set null,
  reported_name text not null,
  reported_avatar_url text,
  reason text not null check (reason in (
    'inappropriate_photo', 'inappropriate_name', 'harassment', 'spam', 'impersonation', 'other')),
  note text check (note is null or char_length(note) between 1 and 500),
  -- Where in the app the report was made.
  context text check (context is null or context in ('friend', 'request', 'contact', 'code')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  review_note text
);
create index user_reports_reported on public.user_reports (reported_id, created_at desc);
create index user_reports_unreviewed on public.user_reports (created_at) where reviewed_at is null;
alter table public.user_reports enable row level security;
revoke all on public.user_reports from public, anon, authenticated;

-- Anyone can report anyone but themselves: a friend, a request in either
-- direction, a contact match or the owner of a code. `invalid` for an unknown
-- user, the caller, a reason outside the list, a note over 500 characters or an
-- unknown context.
create function public.report_user(
  p_user uuid, p_reason text, p_note text default null, p_context text default null)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_me uuid := require_uid();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_profile profiles;
begin
  if p_user is null or p_user = v_me then
    raise exception 'invalid';
  end if;
  select p.* into v_profile from profiles p where p.id = p_user;
  if not found then
    raise exception 'invalid';
  end if;
  if p_reason is null or p_reason not in (
       'inappropriate_photo', 'inappropriate_name', 'harassment', 'spam', 'impersonation', 'other')
     or char_length(coalesce(v_note, '')) > 500
     or (p_context is not null and p_context not in ('friend', 'request', 'contact', 'code')) then
    raise exception 'invalid';
  end if;
  perform rate_limit(v_me, 'report_user', 10, interval '1 hour');
  insert into user_reports (reporter_id, reported_id, reported_name, reported_avatar_url, reason, note,
                            context, created_at)
  values (v_me, p_user, v_profile.display_name, v_profile.avatar_url, p_reason, v_note, p_context, clock());
end;
$$;

revoke execute on function public.report_user(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.report_user(uuid, text, text, text) to service_role, authenticated;
