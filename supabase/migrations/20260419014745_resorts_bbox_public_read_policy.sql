create policy resorts_bbox_public_read
  on public.resorts_bbox
  for select
  to anon, authenticated
  using (true);;
