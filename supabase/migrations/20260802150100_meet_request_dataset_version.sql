-- Sender-authoritative mountain identity for meetup activation.
-- Manifest version alone is insufficient when graph schema/content changes.

alter table public.meet_requests
  add column if not exists dataset_version text;

comment on column public.meet_requests.dataset_version is
  'Exact MountainDataset identity (manifest, graph version, content SHA) used '
  'by the sender. Current clients require an exact local match before route '
  'activation; null identifies a legacy request that cannot navigate.';
