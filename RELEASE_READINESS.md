# Release readiness

Last repository check: September 23, 2026. This page records the current
release and routing gates; earlier validation and release decisions remain in
Git history.

## Testing build

PowderMeet **1.0.0 (203)** was archived and uploaded to App Store Connect on
September 23. Upload succeeded with MapboxCommon/MapboxCoreMaps missing-dSYM
warnings. The repository does not confirm Apple processing or tester
availability. Do not describe this upload as a public or fully validated
release.

The build includes two-phone **TEST** meetups on frozen preview maps. They are
visibly non-live and unavailable in App Store builds. Preview routing does not
establish that live mountain navigation is ready.

## Live routing gate

At the September 23 production readback, there were **zero** published
canonical manifests and graph blobs. Mountains therefore loaded frozen preview
maps, and live Go To and meetup navigation remained gated. A resort needs a
reviewed canonical trail/lift manifest, a validated built graph, publication,
and fresh matching operational status before live routing can be enabled.

Whistler still had unresolved source geometry, including unnamed ways and lift
exits without mapped downhill links. The 159 catalog entries and successful
source-graph parsing are not proof of 159 navigable live resorts.

## Acceptance still required

- Confirm App Store Connect processing and tester access for build 203.
- Review and publish canonical datasets resort by resort, then verify fresh
  operational status and strict route failures on device.
- Test live friend presence, meet request/acceptance, push, rerouting, and
  background ski recording on two physical phones.
- Field-test on-mountain routing before making coverage claims.

The source and operator contracts are in [AGENTS.md](AGENTS.md); setup and
product behavior are in [the project guide](docs/PROJECT_GUIDE.md).
