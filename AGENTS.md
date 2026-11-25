# PowderMeet: rules for coding agents

Rules for agents changing this repository. How the system works is in `specs/`; how to
build it is in `docs/DEVELOPING.md`; what is in flight and what the maintainer has
decided is in `docs/ROADMAP.md`; how to review the whole tree is in `docs/REVIEW.md`.

## Before you change anything

- `specs/` is the contract. Read the specs your change touches before writing code. If
  code and spec disagree, the spec wins; if the spec is wrong, fix it in the same commit
  and say so in the commit message.
- Identifiers in the specs (types, tables, RPCs, events, IDs) are exact. Don't rename
  them.
- Check `docs/ROADMAP.md` before starting work that looks open: it may be decided,
  in flight or deliberately dropped.

## Boundaries

- Packages under `packages/` import Foundation (plus the `CZlib` and `CSQLite` system
  targets) and each other only as `specs/01-ARCHITECTURE.md` section 4 allows: no
  UIKit, SwiftUI, MapboxMaps or Supabase. `MapboxAdapter` is the only module that
  imports MapboxMaps and `SupabaseBackend` the only one that imports Supabase, so the
  rest builds and tests on Linux.
- The app target composes packages. Business logic in a view is a review failure.
- Shared state between two phones lives in Postgres and changes only through the RPCs in
  `specs/04-SCHEMA.md`. No direct table writes from the client, and clients never
  broadcast on Realtime: everything arrives on the user's private topic.
- Resort maps come from the one pipeline in `pipeline/`. What it can't work out on its
  own goes in `pipeline/decisions/<resort_id>.yaml`, each entry naming its source. Trail
  maps and other resort artwork are read, never committed or shipped.

## Quality bar

- Swift 6 language mode with strict concurrency. No `@unchecked Sendable` or
  `nonisolated(unsafe)` without a comment giving the reason.
- No `try?` on a path the user started. Failures are `PowderMeetError` values, and the
  user sees what happened in plain words.
- No singletons: dependencies arrive through the composition root. No generation
  counters: lifecycle is cancellation of a task tree.
- Logging goes through `os.Logger` with the categories in `specs/07-CLIENT.md`. Never log
  locations, tokens or personal data as public.
- Small units: one type per job, files split by feature once they pass about 800 lines.
  No dead code, commented-out code or TODOs in a commit; open work goes in the roadmap.
- Comments say why, not what.
- UI is built from the components in `specs/12-DESIGN-BRIEF.md`, never styled by hand,
  and `specs/13-APP-MAP.md` says what each screen is for. Every screen works with
  Dynamic Type, VoiceOver, Reduce Motion and the smallest supported iPhone.
- Copy is for skiers: plain words, no internal names.
- The map keeps its frame rate while panning and zooming. Nothing heavy runs on the
  main actor.
- Privacy: location goes only to accepted friends, and nothing is stored that no feature
  uses. A deleted account or a replaced photo leaves nothing behind.

## Tests

Write only what catches a regression you can name:

- the meeting scenarios in `packages/MeetSolver/Tests`, which must stay green;
- pgTAP privacy cases for every policy and RPC that guards location, friendship or a
  meet: self, friend, stranger and blocked;
- parser tests over the GPS corpus in `packages/DescentKit/Tests`;
- a test for a bug you fix, when it is cheap.

No UI tests, protocol simulations, benchmarks, nightly jobs or tests that restate the
code. Check behaviour in the simulator yourself: the Debug launch arguments in
`apps/ios/PowderMeet/Composition/DebugLaunch.swift` stage demo data; anything that
talks to the backend is checked on the live backend, signed in with a test account.

## Building

- Build output stays outside iCloud Drive, under `~/Library/Caches/PowderMeet/`.
- `apps/ios/project.yml` is the source of the Xcode project: run `xcodegen` after
  changing it and commit the result.
- One `xcodebuild` at a time, and never in a loop. Heavy jobs (Release builds, pipeline
  builds) run one at a time; the pipeline builds one resort at a time locally.
- Backend SQL is tested locally (`supabase db start`, `supabase db reset --local`,
  `supabase test db` in `backend/`) when you change it. Never run the Supabase CLI
  against the hosted project.
- CI runs on push to `main`, filtered by path. Actions minutes cost money: run checks
  locally, push finished batches, and ask before a long workflow run (the full-catalog
  resort build is one).

## Working in parallel

- Each parallel session runs only the package tests it touched, commits on its own
  branch and reports. The coordinating session merges, builds once, and does the
  simulator pass and the screenshots.
- The UI is one product. Never split a screen or a flow across sessions, and remove a
  feature's old home when it moves. Parallel sessions are for work with no shared UI
  (pipeline, backend, solver internals).

## Live backend

- The hosted Supabase project is live. Never edit a migration that has been applied:
  schema changes go in a new numbered migration, applied after its tests pass.
- Edge workers are deployed from `backend/supabase/functions/`, and the deployed code
  matches the repository.

## Secrets and personal data

- Secrets live in Supabase secrets, `_local/secrets/` (git-ignored),
  `~/.appstoreconnect/` and GitHub Actions: never in the repository, a migration, a log
  or a reply. `apps/ios/Secrets.xcconfig` holds client-public values only and is not committed.
- Personal photos used in demos stay in `_local/`. Demo media is recorded on the Mac.

## Git and releases

- Commit locally on `main` as you go, with messages that say what changed for the user.
- GitHub holds one root commit named "PowderMeet". Each sync re-squashes into it and
  force-pushes. Standing approval (maintainer, 21 Nov 2026): sync each time a new build
  goes to the maintainer's phone, after checking the change for secrets and personal
  data. Any other squash or force-push needs their confirmation. No pull requests.
- TestFlight builds are archived on the Mac and uploaded with the App Store Connect API
  key. Confirm with the maintainer before each upload.
