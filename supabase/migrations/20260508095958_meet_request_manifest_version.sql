alter table public.meet_requests
  add column if not exists manifest_version int;

comment on column public.meet_requests.manifest_version is
  'Canonical manifest version of the resort graph the sender used. '
  'Receiver fetches this exact version via get-resort-graph before '
  'solving so both devices route on byte-identical graphs. Null = '
  'legacy meet sent before canonical path was wired (drift fallback '
  'in MeetupSessionController applies).';;
