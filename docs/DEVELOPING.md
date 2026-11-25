# Developing PowderMeet

## Layout

| Path | What it is |
|---|---|
| `apps/ios` | The iPhone app (SwiftUI, iOS 26), composed from the packages |
| `packages` | Swift 6 packages: `MountainCore` (resort bundles and graph), `MeetSolver` (meeting points and routes), `DescentKit` (GPS import and run matching), `MapScene` (map content), `MapboxAdapter` (the only Mapbox code), `PowderMeetAPI`, `SupabaseBackend` (the only Supabase code), `AppCore` (sessions and state) and `Support` |
| `backend/supabase` | Postgres schema, row-level security, RPCs, edge workers (lift status, conditions, push, photo cleanup) and pgTAP tests |
| `pipeline` | `pm-pipeline`, the Python tool that builds, checks and publishes resort maps |
| `specs` | The contract: product, architecture, domain, protocol, schema, pipeline, solver, client, design |
| `docs` | This file, the roadmap, the review guide, the privacy policy, the demo storyboard and third-party notices |

## Building

```sh
swift test --package-path packages/MeetSolver --scratch-path ~/Library/Caches/PowderMeet/spm/MeetSolver
(cd pipeline && uv run pytest)
(cd apps/ios && xcodegen && open PowderMeet.xcodeproj)
```

The app needs `apps/ios/Secrets.xcconfig` (copy `Secrets.xcconfig.example`) with a
Mapbox token and the Supabase project's public URL and key. Rules for coding agents
working in this repository are in [AGENTS.md](../AGENTS.md); a guide for reviewing the
whole tree is in [REVIEW.md](REVIEW.md).
