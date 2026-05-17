-- Stamp the canonical manifest version on outgoing meet requests so the
-- receiver can verify it holds the same authoritative graph as the sender
-- before solving. Eliminates the existing graph-drift fallback in
-- MeetupSessionController ("graph drift suspected" → re-solve via solve()).
--
-- Lifecycle:
--   1. Migration adds nullable column. Old senders (legacy IPA build,
--      flag still off) leave it null. Receivers treat null as "legacy
--      meet — fall back to today's drift handling."
--   2. CanonicalGraphFetcher.swift, when the useCanonicalGraphFetch flag
--      is on, has the sender stamp the current manifest_version on send.
--      Receiver, before solving, force-fetches the matching manifest_version
--      via get-resort-graph (server retains every historical version).
--   3. After useCanonicalGraphFetch is at 100% and the legacy path is
--      retired, a follow-up migration adds NOT NULL + drops the legacy
--      drift fallback in client code.
--
-- Why nullable now: existing rows don't have a manifest_version, and
-- backfilling them with a guess could mislead receivers into thinking
-- a v0 graph existed for a resort. Null is the correct "I don't know"
-- value here.

alter table public.meet_requests
  add column if not exists manifest_version int;

comment on column public.meet_requests.manifest_version is
  'Canonical manifest version of the resort graph the sender used. '
  'Receiver fetches this exact version via get-resort-graph before '
  'solving so both devices route on byte-identical graphs. Null = '
  'legacy meet sent before canonical path was wired (drift fallback '
  'in MeetupSessionController applies).';
