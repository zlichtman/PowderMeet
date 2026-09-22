-- The preferred-ski snapshot replacement switched generation stamps from a
-- wall-clock expression to nextval(), but the referenced sequence was never
-- created. Authenticated social snapshot calls therefore failed at runtime.

create sequence if not exists public.social_snapshot_generation_seq as bigint;

grant usage, select on sequence public.social_snapshot_generation_seq
  to authenticated, service_role;

revoke all on sequence public.social_snapshot_generation_seq from anon;
