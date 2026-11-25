# PowderMeet specs

This folder is the contract for PowderMeet. Everything needed to build a piece that
fits the rest is written down here: if code and spec disagree, the spec wins, and a
spec that is wrong is fixed in the same change.

## How to use the specs

1. Read the specs your change touches before writing code.
2. Product decisions are in `00-PRODUCT.md` section 7. Each spec states the default it
   assumes; change the spec, not the code, if a decision changes.
3. Testing is deliberately lean: see "Tests" in `AGENTS.md`, which overrides the
   fuller matrix in `09-TESTING-CI.md`.
4. Open work is in `docs/ROADMAP.md`, not here.

## Spec index

| File | Normative content |
|---|---|
| `specs/00-PRODUCT.md` | What the product promises, user journeys, acceptance criteria, non-goals, UX rules, decisions with defaults |
| `specs/01-ARCHITECTURE.md` | System shape, repository layout, packages and their public surfaces, dependency rules, concurrency and error models, environments |
| `specs/02-DOMAIN.md` | Identifiers, the resort bundle format, status, conditions, profiles, pace, meets, descents, time handling |
| `specs/03-PROTOCOL.md` | The meet protocol: states, transitions, RPC signatures, realtime events, idempotency, expiry, recovery, divergence scenarios as tests |
| `specs/04-SCHEMA.md` | Postgres schema, RLS, RPCs, triggers, realtime topics and policies, jobs, cron, storage, push outbox, pgTAP matrix |
| `specs/05-PIPELINE.md` | Resort data pipeline stages, validation thresholds, providers, CLI, CI workflow, report format, launch resorts |
| `specs/06-SOLVER.md` | MeetSolver package: inputs, cost model, search, ranking, ETA, progress, reroute, determinism, performance, fixtures |
| `specs/07-CLIENT.md` | AppCore sessions and state machines, features and intents, MapScene, offline, errors, logging, accessibility |
| `specs/08-ACTIVITY.md` | DescentKit: parsers, descents, matching as a derivation, server-side pace learning |
| `specs/09-TESTING-CI.md` | Test matrix, CI workflows, device checklist |
| `specs/10-INVARIANTS.md` | Domain invariants as test names, each mapped to a package |
| `specs/11-SETUP-RELEASE.md` | Accounts, Apple identifiers and keys, Supabase project setup, secret locations, the notification set, App Store review requirements |
| `specs/12-DESIGN-BRIEF.md` | Screen-by-screen design brief, Liquid Glass rules, acceptance for the design |
| `specs/13-APP-MAP.md` | What each screen is for and how the screens connect |

## Conventions used in the specs

- MUST, SHOULD, MAY have their usual normative meaning.
- `DECISION (default: …)` marks a product decision the spec assumes. Change the
  default in `00-PRODUCT.md` section 7 and the dependent specs follow.
- Identifiers, table names, RPC names, event types and Swift type names are exact.
  Use them as written so pieces built apart fit together.
- "Fail closed" means return a typed failure; "degrade" means proceed and label.
