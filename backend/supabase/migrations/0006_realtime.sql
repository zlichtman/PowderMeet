-- 0006 Realtime authorization. specs/04-SCHEMA.md section 5.
--
-- Two kinds of topic, both private: `user:{uuid}` and `resort:{resort_id}`.
-- Events are written only by database triggers through realtime.send(). A
-- client may join its own user topic and any resort topic, and may never send:
-- there is no insert policy for `authenticated` or `anon`, so a broadcast from
-- a phone is refused.
--
-- The project must also have Realtime "Allow public access" switched OFF
-- (dashboard setting), so channels that skip `private: true` cannot be used.

-- Realtime enables row level security on realtime.messages itself; the pgTAP
-- suite asserts it is on.

create policy user_topic_read on realtime.messages
  for select to authenticated
  using (
    realtime.topic() = 'user:' || (select auth.uid())::text
    or realtime.topic() like 'resort:%');
