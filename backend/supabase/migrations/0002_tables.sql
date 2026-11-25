-- 0002 Tables. specs/04-SCHEMA.md section 2.
-- User-owned rows reference profiles with ON DELETE CASCADE, so deleting the
-- auth user removes everything that user owns (App Store guideline 5.1.1).

-- ---------------------------------------------------------------- resorts

create table public.resorts (
  id text primary key check (id ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  name text not null,
  timezone text not null,
  bbox jsonb,                      -- [minLon, minLat, maxLon, maxLat]
  center jsonb,                    -- [lon, lat]
  camera jsonb,
  pass_products text[] not null default '{}',
  -- The live status provider this resort uses, if any. A resort with none is
  -- `scheduled_only`.
  status_provider text check (status_provider in ('epic', 'mtnpowder', 'liftie')),
  status_mode text not null default 'scheduled_only' check (status_mode in ('live', 'scheduled_only')),
  published boolean not null default false,
  review_minutes int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (status_mode <> 'live' or status_provider is not null)
);

create table public.resort_bundles (
  bundle_id text primary key check (bundle_id ~ '^[0-9a-f]{64}$'),
  resort_id text not null references public.resorts (id),
  schema_version int not null,
  manifest_version int not null,
  extract_id text not null,
  built_at timestamptz not null,
  pipeline_version text not null,
  size_bytes int not null check (size_bytes > 0),
  integrity jsonb not null,
  report_url text,
  created_at timestamptz not null default now()
);
create index resort_bundles_resort on public.resort_bundles (resort_id, built_at desc);

-- rendezvous_ids is the active bundle's rendezvous catalog as ids. It is what
-- meet_propose checks and what the invalidation trigger compares against.
create table public.resort_active_bundle (
  resort_id text primary key references public.resorts (id),
  bundle_id text not null references public.resort_bundles (bundle_id),
  rendezvous_ids text[] not null default '{}',
  published_at timestamptz not null,
  published_by text not null
);

create table public.resort_bundle_publications (
  id bigserial primary key,
  resort_id text not null references public.resorts (id),
  bundle_id text not null references public.resort_bundles (bundle_id),
  published_at timestamptz not null,
  published_by text not null,
  previous_bundle_id text,
  rendezvous_ids text[] not null default '{}',
  report jsonb
);
create index resort_bundle_publications_resort on public.resort_bundle_publications (resort_id, published_at desc);

create table public.resort_status (
  id bigserial primary key,
  resort_id text not null references public.resorts (id),
  observed_at timestamptz not null,
  expires_at timestamptz not null,
  source text not null check (source in ('epic', 'mtnpowder', 'liftie', 'scheduled')),
  groups jsonb not null check (jsonb_typeof(groups) = 'object'),
  groomed text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index resort_status_latest on public.resort_status (resort_id, observed_at desc);

create table public.resort_conditions (
  id bigserial primary key,
  resort_id text not null references public.resorts (id),
  observed_at timestamptz not null,
  expires_at timestamptz not null,
  source text not null,
  "current" jsonb,
  hourly jsonb,
  created_at timestamptz not null default now()
);
create index resort_conditions_latest on public.resort_conditions (resort_id, observed_at desc);

-- ------------------------------------------------------- people and social

-- avatar_url holds the object path inside the `avatars` bucket
-- (`<user id>/<file>`), never an arbitrary URL; clients build the public URL.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 40),
  avatar_url text,
  ability text not null default 'intermediate'
    check (ability in ('beginner', 'intermediate', 'advanced', 'expert')),
  max_difficulty text not null default 'blue'
    check (max_difficulty in ('green', 'blue', 'black', 'double_black')),
  baseline_speeds jsonb not null default '{}' check (jsonb_typeof(baseline_speeds) = 'object'),
  -- What the skier rides, as the solver uses it (specs/02-DOMAIN.md section 5.1).
  -- CASE keeps a cast from running on a value of the wrong type.
  equipment jsonb check (
    jsonb_typeof(equipment) = 'object'
    and equipment - array['discipline', 'type', 'length_cm', 'waist_mm'] = '{}'::jsonb
    and coalesce(equipment ->> 'discipline' in ('ski', 'snowboard'), false)
    and coalesce(equipment ->> 'type' in ('all_mountain', 'carving', 'freeride', 'park'), false)
    and case
      when not equipment ? 'length_cm' then true
      when jsonb_typeof(equipment -> 'length_cm') = 'number'
        then (equipment ->> 'length_cm')::numeric between 60 and 220
          and (equipment ->> 'length_cm')::numeric % 1 = 0
      else false
    end
    and case
      when not equipment ? 'waist_mm' then true
      when equipment ->> 'discipline' = 'ski' and jsonb_typeof(equipment -> 'waist_mm') = 'number'
        then (equipment ->> 'waist_mm')::numeric between 55 and 140
          and (equipment ->> 'waist_mm')::numeric % 1 = 0
      else false
    end
  ),
  -- Terrain and lifts the skier is never routed onto.
  avoid text[] not null default '{}'
    check (avoid <@ array['ungroomed', 'flats', 'park', 'surface_lifts']
           and array_position(avoid, null) is null),
  -- Steepest pitch the skier will take, in degrees; null is no limit.
  max_pitch_deg smallint check (max_pitch_deg between 10 and 45),
  -- Private: no column grant, so not even a friend can select them (0003).
  height_cm smallint check (height_cm between 100 and 230),
  weight_kg smallint check (weight_kg between 25 and 200),
  email_hash text unique check (email_hash ~ '^[0-9a-f]{64}$'),
  phone_hash text unique check (phone_hash ~ '^[0-9a-f]{64}$'),
  current_resort_id text references public.resorts (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index profiles_current_resort on public.profiles (current_resort_id) where current_resort_id is not null;

create table public.user_blocks (
  blocker_id uuid not null references public.profiles (id) on delete cascade,
  blocked_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index user_blocks_blocked on public.user_blocks (blocked_id);

create table public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references public.profiles (id) on delete cascade,
  addressee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (requester_id <> addressee_id)
);
create unique index friendships_pair
  on public.friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_requester on public.friendships (requester_id);
create index friendships_addressee on public.friendships (addressee_id);

-- ------------------------------------------------------------------ meets

-- bundle_id and superseded_by are advisory pointers and carry no foreign key.
create table public.meets (
  meet_id uuid primary key,
  resort_id text not null references public.resorts (id),
  bundle_id text,
  rendezvous_id text not null,
  proposer_id uuid not null references public.profiles (id) on delete cascade,
  invitee_id uuid not null references public.profiles (id) on delete cascade,
  status text not null
    check (status in ('proposed', 'active', 'completed', 'declined', 'cancelled', 'expired', 'invalidated')),
  end_reason text
    check (end_reason in ('arrived', 'declined_by_user', 'declined_cannot_route', 'user_cancelled',
                          'timeout', 'rendezvous_removed', 'status_blocks_route', 'partner_left', 'superseded')),
  proposer_eta_s int check (proposer_eta_s >= 0),
  proposer_eta_sd_s int check (proposer_eta_sd_s >= 0),
  invitee_eta_s int check (invitee_eta_s >= 0),
  invitee_eta_sd_s int check (invitee_eta_sd_s >= 0),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  ended_at timestamptz,
  expires_at timestamptz not null,
  superseded_by uuid,
  check (proposer_id <> invitee_id),
  check ((status in ('proposed', 'active')) = (end_reason is null))
);
-- A user may be in at most one non-terminal meet in either role (I-23).
-- These two indexes cover each role; meet_propose covers the cross-role case
-- under advisory locks on both user ids.
create unique index meets_one_active_proposer on public.meets (proposer_id) where status in ('proposed', 'active');
create unique index meets_one_active_invitee on public.meets (invitee_id) where status in ('proposed', 'active');
create index meets_proposer_history on public.meets (proposer_id, created_at desc);
create index meets_invitee_history on public.meets (invitee_id, created_at desc);
create index meets_open_by_resort on public.meets (resort_id) where status in ('proposed', 'active');

create table public.meet_progress (
  meet_id uuid not null references public.meets (meet_id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  eta_s int,
  eta_sd_s int,
  remaining_m int,
  state text not null check (state in ('navigating', 'rerouting', 'arrived', 'lost')),
  fix_at timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (meet_id, user_id)
);

-- --------------------------------------------------------------- presence

create table public.presence (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  resort_id text references public.resorts (id),
  lon double precision not null check (lon between -180 and 180),
  lat double precision not null check (lat between -90 and 90),
  accuracy_m real,
  speed_ms real,
  heading_deg real,
  captured_at timestamptz not null,
  received_at timestamptz not null default now(),
  app_build text
);
create index presence_resort on public.presence (resort_id, received_at desc);

-- --------------------------------------------------------- activity, pace

create table public.descents (
  descent_id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles (id) on delete cascade,
  source text not null check (source in ('live', 'slopes', 'gpx', 'tcx', 'fit', 'healthkit')),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  track bytea not null,
  resort_id text references public.resorts (id),
  device text,
  app_build text,
  created_at timestamptz not null default now(),
  unique (owner_id, content_hash),
  check (ended_at > started_at)
);
create index descents_owner_time on public.descents (owner_id, started_at desc);

create table public.descent_matches (
  descent_id uuid not null references public.descents (descent_id) on delete cascade,
  bundle_id text not null references public.resort_bundles (bundle_id),
  matcher_version int not null,
  matched jsonb not null check (jsonb_typeof(matched) = 'array'),
  coverage real,
  confidence real,
  created_at timestamptz not null default now(),
  primary key (descent_id, bundle_id, matcher_version)
);

create table public.pace_observations (
  id bigserial primary key,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  descent_id uuid not null references public.descents (descent_id) on delete cascade,
  bundle_id text not null,
  edge_id text not null,
  elapsed_s real,
  moving_s real,
  length_m real,
  observed_at timestamptz,
  conditions_id bigint
);
create index pace_observations_owner on public.pace_observations (owner_id);
create index pace_observations_descent on public.pace_observations (descent_id);

create table public.pace_models (
  owner_id uuid primary key references public.profiles (id) on delete cascade,
  computed_at timestamptz not null default now(),
  difficulty_factor jsonb not null default '{}',
  edge_factor jsonb not null default '{}',
  stops_per_km real,
  n_descents int not null default 0
);

-- ------------------------------------------------------------------- push

create table public.device_tokens (
  user_id uuid not null references public.profiles (id) on delete cascade,
  token text not null check (token ~ '^[0-9a-fA-F]{32,200}$'),
  environment text not null check (environment in ('development', 'production')),
  app_build text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, token)
);
create index device_tokens_token on public.device_tokens (token);

-- The kind check is the whole notification set (specs/11-SETUP-RELEASE.md
-- section 5). Nothing else can be queued.
create table public.push_outbox (
  id bigserial primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null
    check (kind in ('meet.proposed', 'meet.accepted', 'meet.declined', 'meet.partner_arrived',
                    'meet.ended', 'meet.expired', 'friend.requested', 'friend.accepted')),
  payload jsonb not null default '{}',
  created_at timestamptz not null default now(),
  leased_until timestamptz,
  attempts int not null default 0,
  sent_at timestamptz,
  last_error text
);
create index push_outbox_unsent on public.push_outbox (id) where sent_at is null;
create index push_outbox_user on public.push_outbox (user_id, kind);

-- ------------------------------------------------------------------- jobs

create table public.jobs (
  id bigserial primary key,
  kind text not null
    check (kind in ('status_refresh', 'conditions_refresh', 'push_drain', 'expiry_sweep', 'pace_recompute')),
  resort_id text references public.resorts (id) on delete cascade,
  owner_id uuid references public.profiles (id) on delete cascade,
  run_after timestamptz not null,
  leased_until timestamptz,
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now()
);
create index jobs_claimable on public.jobs (kind, run_after) where leased_until is null;
-- One queued job per (kind, resort) and per (kind, owner): enqueueing again
-- while one is waiting or running is a no-op.
create unique index jobs_one_per_resort on public.jobs (kind, resort_id) where resort_id is not null;
create unique index jobs_one_per_owner on public.jobs (kind, owner_id) where owner_id is not null;

-- ---------------------------------------------------------- miscellaneous

create table public.client_events (
  id bigserial primary key,
  user_id uuid references public.profiles (id) on delete cascade,
  kind text not null,
  props jsonb,
  at timestamptz not null default now(),
  app_build text
);
create index client_events_at on public.client_events (at);

create table public.app_config (
  key text primary key,
  value jsonb not null
);

create table public.rate_limits (
  user_id uuid not null references public.profiles (id) on delete cascade,
  bucket text not null,
  window_start timestamptz not null,
  count int not null default 0,
  primary key (user_id, bucket, window_start)
);
