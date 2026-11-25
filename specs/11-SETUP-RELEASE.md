# 11 Setup and release

Everything outside the code that the app needs: accounts, identifiers, keys,
secrets, the notification set, and what App Store review will ask for. Steps only the
account holder can do are marked **(owner)**.

## 1. Accounts and services

| Service | Purpose | Plan / cost | Notes |
|---|---|---|---|
| Apple Developer Program **(owner)** | App ID, capabilities, APNs key, TestFlight, App Store | existing membership | |
| Supabase org `zlichtman` | one project, `PowderMeet` (DECISION 9) | free plan: projects pause after a week idle; CI runs against local Supabase, so the hosted project pauses only if nobody opens the app for a week | upgrade to Pro at launch for no pausing, backups and support |
| GitHub | repository, Actions (Linux minutes) | free | public repo, so Actions minutes are free; it holds no Supabase secrets (publishing runs from the Mac) |
| Mapbox **(owner)** | map style, terrain, offline; SPM download token | free tier is enough for development | public `pk.` token in `Secrets.xcconfig`; secret downloads token in `~/.netrc` only |
| Open-Meteo | conditions | free, no key | called by the worker only; CC BY 4.0, so the app credits it (Settings, and the third-party notices) |
| Epic and MtnPowder status feeds | live lift status | public endpoints | about one worker request per resort per 15 min (`04-SCHEMA.md` section 7); respect terms |
| Elevation | DEM tiles for the pipeline | Mapbox Terrain-RGB with the same token, or AWS Terrarium (no key) | cached in CI; Mapbox terms apply, and resort maps from OpenStreetMap carry its ODbL credit (`docs/THIRD_PARTY_NOTICES.md`) |
| App Store Connect API key **(owner)** | TestFlight uploads from the maintainer's Mac (`xcodebuild archive` + `-exportArchive`/upload) | included with the developer program | key in `~/.appstoreconnect/`; Xcode Cloud is not used |

## 2. Apple identifiers and keys (owner)

1. **App ID.** DECISION (default: reuse `com.powdermeet.PowderMeet` if it still exists in
   the portal, otherwise register it again). Capabilities: Push Notifications, Sign in
   with Apple, Background Modes (Location updates; pushes are plain alerts, so no Remote
   notifications mode), Time
   Sensitive Notifications.
2. **APNs Auth Key.** App Store Connect → Users and Access → Integrations → Keys →
   Apple Push Notifications service. Download the `.p8` once; it cannot be downloaded
   again. Store it under the project's `_local/secrets/apns/` (git-ignored) and record
   the Key ID and Team ID. One key serves both APNs environments.
3. **Sign in with Apple.** The app uses the native iOS flow only. In each Supabase project,
   enable the Apple provider and add the bundle identifier to its authorized client
   IDs. No Services ID or web secret is needed unless a web sign-in is added later.
4. **App Store Connect app record.** Create it once for TestFlight; the bundle ID above;
   internal tester group for the test devices.

## 3. Supabase project setup (one project: `PowderMeet`)

1. Project created in `us-west-1` (nearest to the launch mountains). Save the project
   ref, URL and publishable key into `Secrets.xcconfig` for the matching build
   configuration. The database password and service-role key go to the maintainer's
   password manager and `_local/secrets/supabase/`; the repository and GitHub Actions
   hold none.

   The ref, URL and keys do not change with the project's name. The client-public
   values (URL, publishable key, Mapbox public token) live in `Secrets.xcconfig`, which
   is not committed; `Secrets.xcconfig.example` names them.

   The database password was generated at creation. **(owner)** Reset it in Project
   Settings → Database, and store it in your password manager.
2. Auth: Apple provider enabled with the bundle ID; Email provider enabled with
   "Confirm email" on and minimum password length 8; redirect URLs
   `powdermeet://auth-callback` and `powdermeet://auth-callback?type=recovery`
   (Authentication → URL Configuration); JWT expiry default. The built-in mailer is
   rate-limited and meant for testing; a custom SMTP sender (Authentication → Emails →
   SMTP Settings) before TestFlight users sign up.
3. Realtime: **Allow public access OFF** (private channels only).
4. Vault: secrets `worker_secret` (random 32 bytes, base64) and `project_url` (the
   project's `https://<ref>.supabase.co`) used by cron to call workers.
5. Edge function secrets: `WORKER_SECRET` (same value), `APNS_AUTH_KEY` (full PEM),
   `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`. The `push-drain` worker picks the
   APNs host from each token's `environment` column (debug builds register `development`,
   TestFlight and App Store builds `production`), so one project serves every build.
6. Migrations are tested on a local database and then applied to the hosted project
   (`AGENTS.md`: the Supabase CLI is never run against it); buckets and policies come
   from migrations. The dashboard-only items of `04-SCHEMA.md` section 12 are checked
   by hand; `backend/scripts/check-dashboard.sh` is planned and does not exist yet.
7. GitHub Actions secrets: none are set. `publish-resort.yml` reads `SUPABASE_URL` and
   `SUPABASE_SERVICE_ROLE_KEY`, so it builds but cannot publish until they are added;
   resorts are published from the Mac (`docs/ROADMAP.md`).
8. **Launch reset.** The same project becomes production: run
   `backend/scripts/reset-app-data.sql` (planned, not written yet: truncates app tables
   and test users, keeps resorts, bundles and publications; stored files are removed
   through the Storage API, never with SQL: `04-SCHEMA.md` section 8), re-run `check-dashboard.sh`, upgrade
   to the Pro plan. If DECISION 9 is changed to a second project, create it from the
   same migrations with this checklist instead.

## 4. Where every secret lives

| Secret | Lives in | Never in |
|---|---|---|
| Supabase URL, publishable key, Mapbox public token | `Secrets.xcconfig` (client-public, git-ignored; `Secrets.xcconfig.example` is committed) | |
| Supabase service-role key, DB password, access token | `_local/secrets/supabase/`; the maintainer's password manager | repo, migrations |
| APNs `.p8`, Key ID, Team ID | `_local/secrets/apns/`; Supabase edge function secrets | repo |
| `worker_secret` | Supabase Vault and edge function secrets | repo |
| Mapbox downloads token | `~/.netrc` | repo |

## 5. Notifications (DECISION: this exact set of pushes and nothing else)

| Kind | Trigger | Interruption level | Sound | Body example |
|---|---|---|---|---|
| `meet.proposed` | `meets` insert | time-sensitive | yes | "Alex wants to meet at Roundhouse Lodge." |
| `meet.accepted` | status → active | time-sensitive | yes | "Alex is on the way. Meeting at Roundhouse Lodge." |
| `meet.declined` | status → declined | active | no | "Alex can't make Roundhouse Lodge: no route under current closures." |
| `meet.partner_arrived` | partner progress state → arrived | time-sensitive | yes | "Alex is at Roundhouse Lodge." |
| `meet.ended` | status → invalidated or cancelled by the other party | time-sensitive | yes | "Meet ended: a closure blocks the route." |
| `meet.expired` | sweep | passive | no | "Your proposal to Alex expired." |
| `friend.requested` / `friend.accepted` | friendships | active | no | |

Every kind can be muted by its recipient (Profile → Settings → Notifications; `notification_prefs`, migration 0018). A muted kind is retired by
`push_outbox_claim` and never sent; the in-app banner and the in-app lists are
unaffected. A user who has never changed a toggle gets every kind.

Rules: no presence pushes, no digests, no marketing. In the foreground the app shows
an in-app banner instead. Navigation maneuvers and arrival use audio prompts, not
notifications. The app also posts two local notifications of its own, never
prompting: runs imported and the day's recording summary (`07-CLIENT.md` section 4). The
`push_outbox` worker collapses duplicates per meet within 60 s and uses
`apns-collapse-id = meet_id`. The server knows a rendezvous by id only, so the place
name in a body is the id made readable (`roundhouse-lodge` → "Roundhouse Lodge"), and
a body carries no ETA: the invitee's ETA is computed on their phone after the push.

## 6. App Store requirements (what review asks for)

- **In-app account deletion** (guideline 5.1.1): Settings → Delete account calls
  `account_delete()`, which removes the auth user and cascades every owned row and
  device token. The client removes the photo files first, and the `avatar-sweep` worker
  removes any left within about a minute (`04-SCHEMA.md` sections 6 and 8). Required before the first App Store submission.
- **Sign in with Apple** is offered next to email and password, which satisfies the
  social-login rule (guideline 4.8).
- **Location purpose strings**: when-in-use for the map and presence; always for
  navigation and recording, requested only when a meet starts or recording is turned
  on; the strings explain both. Background modes justification in review notes.
- **Privacy nutrition labels**: precise location (linked to identity, used for app
  functionality), contacts (hashed on device, disclose as collected for app
  functionality), user ID, usage data (`client_events`). Privacy policy and support
  URLs on `zlichtman.com`.
- **Review access**: two demo accounts and a written script for a two-phone meet on
  the PowderMeet project, or the Dev page's sandbox, which simulates the partner
  (`07-CLIENT.md` section 8); without one the reviewer
  cannot exercise the core flow.
- **Third-party notices**: before each upload, `docs/THIRD_PARTY_NOTICES.md` and the
  app's `ACKNOWLEDGEMENTS.txt` name every package in `Package.resolved`, the map and
  weather data credits (OpenStreetMap ODbL, with OpenSkiMap named as the route the run
  and lift data takes, Open-Meteo CC BY 4.0, Mapbox) and any
  bundled asset that needs one.
- **Export compliance**: HTTPS only; standard exemption.
- **Age rating**: 4+; no user-generated content beyond display names and avatars (avatars
  need a report-or-block path: `block_user` suffices).

## 7. Development machine

Xcode (current release), Supabase CLI, Docker Desktop or OrbStack (local Supabase when
changing SQL; never the hosted project, `AGENTS.md`), `uv` with Python
3.12, GitHub CLI, SwiftLint, Mapbox `~/.netrc`. Build output and the DEM cache outside
iCloud Drive. One heavy job at a time.

## 8. Repository

The GitHub repository's `main` branch runs the CI workflows on push, filtered by path;
section 3 item 7 says which Actions secrets exist.
