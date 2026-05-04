# send-push — APNs fan-out for PowderMeet

This edge function delivers push notifications for four peer events:
`friend_request`, `friend_added`, `meet_request`, `meet_started`. It's
called by AFTER triggers on `friendships` / `meet_requests` (see
`supabase/migrations/20260502_device_tokens_and_push.sql`) via
`pg_net.http_post`, looks up the recipient's iOS device tokens, and
POSTs to APNs HTTP/2 with provider-token JWT auth.

## One-time setup

1. **Create an APNs Auth Key** in App Store Connect → Keys → "+":
   - Enable "Apple Push Notifications service (APNs)".
   - Download the `.p8` file (you only get to download it once).
   - Note the **Key ID** (10 chars) and your **Team ID** (10 chars,
     visible at the top right of the developer portal).

2. **Set Supabase secrets:**

   ```sh
   supabase secrets set \
     APNS_AUTH_KEY="$(cat AuthKey_XXXXXXXXXX.p8)" \
     APNS_KEY_ID=XXXXXXXXXX \
     APNS_TEAM_ID=YYYYYYYYYY \
     APNS_BUNDLE_ID=com.powdermeet.PowderMeet \
     APNS_ENVIRONMENT=development   # use "production" for App Store builds
   ```

   `APNS_AUTH_KEY` must include the full PEM body, including the
   `-----BEGIN PRIVATE KEY-----` and `-----END PRIVATE KEY-----`
   lines. The shell-quoting `"$(cat …)"` form handles that cleanly.

3. **Deploy the function:**

   ```sh
   supabase functions deploy send-push --no-verify-jwt
   ```

   `--no-verify-jwt` is required because `pg_net.http_post` from
   triggers runs without an authenticated user context — the function
   relies on the service-role key in the request body for DB access
   and on its own logic for trust boundaries.

4. **Tell Postgres where the function lives:**

   ```sh
   psql "$DATABASE_URL" <<'SQL'
   alter database postgres set app.send_push_url = 'https://<project-ref>.supabase.co/functions/v1/send-push';
   alter database postgres set app.send_push_anon_key = '<anon-or-service-role-key>';
   SQL
   ```

   Use the project's anon key for `app.send_push_anon_key` — it's only
   used to satisfy the gateway's `Authorization` header check; the
   function reads the service-role key from its own env separately.

5. **Add the iOS push entitlement.** In Xcode:
   - Project settings → Signing & Capabilities → "+" → Push
     Notifications.
   - The entitlement `com.apple.developer.aps-environment` lands in
     `PowderMeet.entitlements`. Set it to `development` for sims and
     debug builds, `production` for App Store / TestFlight.

## How a request flows

1. User A inserts/accepts a row that's interesting to user B
   (friend request, meet request, etc.).
2. The matching AFTER trigger fires `public.send_push(B, kind, payload)`.
3. `send_push` does `pg_net.http_post` to this edge function.
4. The function reads `device_tokens` for B, signs a JWT with the
   APNs auth key, and POSTs to `https://api.push.apple.com/3/device/{token}`
   for each token.
5. APNs delivers the push. iOS shows the system banner if the app is
   backgrounded; if foregrounded, `Notify.swift`'s
   `UNUserNotificationCenterDelegate` intercepts and renders an in-app
   banner instead.

## Troubleshooting

- **No pushes after setup.** Tail the function logs:
  `supabase functions logs send-push --tail`. Common causes:
  expired JWT (key ID mismatch), wrong bundle id, sandbox vs
  production mismatch (`APNS_ENVIRONMENT` must match the build's
  entitlement).
- **`device_tokens lookup failed`.** Service role key not configured
  on the function. The trigger doesn't supply auth context, so the
  function reads `SUPABASE_SERVICE_ROLE_KEY` from its own env.
- **`apns 410` followed by silence.** The token was retired (user
  uninstalled or wiped). The function deletes the dead token so the
  next event for that user only targets live devices.
