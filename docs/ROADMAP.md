# PowderMeet roadmap

The one list of what is left until the app is complete: the owner's part first, then
Claude's, each in order. How the app works is in `specs/`; an item here that changes
behaviour updates the spec it touches. A new session reads `AGENTS.md`, then this.

Updated 23 Nov 2026.

## Where it stands

- **App:** 3.0.0, finished for the public beta. `main` builds and its tests pass.
- **Owner's phone:** build 2026112401, with everything under "Check on the phone".
- **TestFlight:** build 2026112305 (23 Nov) is uploaded, one behind the phone's, and
  every older build is expired. Not yet submitted for Beta App Review. Link:
  https://testflight.apple.com/join/dejcRSgp
- **Backend:** live through migration 0028. Workers match the repository.
- **Resorts:** all 161 in the catalog are published with pipeline 1.5.0 (23 Nov),
  22 of them with live lift status. Snowmass, Rusutsu, Boston Mills & Brandywine,
  Crystal Mountain, Kimberley, Alpine Valley Resort (Wisconsin) and Snow King are
  new that day.
- **Website and README:** current demos; the TestFlight button is hidden until Apple
  approves.
- **GitHub:** public, one squashed commit, synced with each phone build.

## Owner to do

Keys, accounts and dashboard settings are listed apart in `_local/OWNER-TODO.md`,
which stays off GitHub.

### To open the beta

- [ ] Add build 2026112305 to the Public Beta group.
- [ ] App Store Connect → Business → Agreements: accept anything pending. The review
      submission fails with "try again later" until then.
- [ ] Submit the build for Beta App Review (TestFlight → Public Beta → the build →
      Submit for Review).
- [ ] Supabase dashboard → Authentication: turn on leaked-password protection.

### Check on the phone

Built and seen only in the simulator or in tests.

- [ ] Two phones: a meet completes with one phone waiting in a pocket for several
      minutes, and the battery over a long meet.
- [ ] Panning while a mountain loads no longer snaps back.
- [ ] Sort buttons in every list. "Nearest" needs a real position.
- [ ] "Meet here" on a place card, tapped on the map while picking where to meet.
- [ ] Badges: the row of pins, the list, its sorts and level dots.
- [ ] The screen shown before a resort is picked.
- [ ] Meeting options spread over different parts of the mountain.
- [ ] The run's figures on the navigation card; the step list at the largest text size.
- [ ] The three run colourings and their legend.
- [ ] The question card on every delete, remove and block.
- [ ] Name, photo and font in Account.
- [ ] With VoiceOver: the send button and the photo crop.
- [ ] The snow overlay, the arrival bell, the drawn ski fallback.
- [ ] Sun Bowl Chutes at Whistler: no gap below the two arms.
- [ ] Runs and lifts without a name: "Unnamed blue run · 120m" on the map (is it too
      much on a busy mountain?), and the same name on the card, Go to, the steps
      and the logs. Every run is unnamed at Hakuba Goryu, Hakuba 47 and Mt. T,
      and most at Myoko Suginohara, Hakuba Iwatake and Zao.
- [ ] The run card swiped up: the elevation profile, on a long run and a black one.
- [ ] The resort picker: the freshness pill ("Today", "This week", "22 Nov") at the
      largest text size, and "Request a resort" at the foot (opens GitHub issues).
- [ ] Onboarding with a new account: the name saves at the name step, the photo
      step after it (skip, upload, a failed upload), and a friend request from the
      contacts step carries the chosen name.
- [ ] Badges with Units set to Metric, and the message when a badge is earned
      (import a day or record a run that earns one).
- [ ] Meeting options: the short reason when the weather chose a route ("Sunny
      side", "Out of the wind", "Out of the slush", "Better visibility").
- [ ] Settings → Dev, redone: Teleport Me and Show Dev People at the top, three dev
      people placed apart on the mountain (Shuffle, a page each), Solver Time with
      presets, pretend Weather, and the Diagnostics page with Copy as text. The
      banner over the map is the only place that says "Teleported · GPS ignored".
- [ ] The profile: "Skied · 42 of 213 runs" under the skis, on the smallest
      iPhone too (the panel does not scroll and is about 50 pt taller).
- [ ] Badges: First Meet, Crew, Regulars and First Chair Crew are live, read from
      the server's meet history for the first time: check with a real account.
- [ ] The run card's Moguls meter on a mogul run (Stoker Bumps at Whistler) against
      an ordinary ungroomed one.

### Check on the mountain, in season

- [ ] One real two-phone meet: steps, live states, easiest way down.
- [ ] One contact matched by email (Hide My Email accounts can't match).
- [ ] A push notification arriving; a profile photo upload.
- [ ] Opening the resort the phone is standing in.
- [ ] Snow while scrubbing the timeline; frame rate; the horizon at dusk.
- [ ] A Whistler meet timed from tap to options.

### Decisions wanted

- [ ] Megève: add the Saint-Gervais, Saint-Nicolas, Combloux and La Giettaz side?
      It is one lift-linked area, which OpenSkiMap files under Evasion Mont Blanc,
      and Mont Joly's base is only reached through it. Les Contamines carries the
      same name and is not linked, so the catalog needs a way to leave it out, and
      Megève needs a fresh extract.
- [ ] Whistler: may skiers ride Peak Express and Fitzsimmons Express down? The map
      says yes, so the app can route down them. A source is needed either way.
- [ ] Totals that tick up run by run during an import, or refresh at the end as now.
- [ ] Terms at first launch: the safety notice lives in About only, by a decision
      recorded in the code ("not in onboarding, where it would scare people off").
      Keep it there, or show it once at first launch?
- [ ] From the secrets scan of 23 Nov (no keys, tokens or passwords in any tracked
      file): the test GPS logs are your own ski days from 2024 to 2026, so check
      that none starts or ends somewhere private; look over the demo images in
      `Demos/` and `docs/screenshots/` for a friend's name or photo; the Whistler
      pipeline fixture carries 17 business e-mail addresses from OpenStreetMap,
      which could be stripped.
- [ ] Blueprint and PowderMeet map styles: keep or retire.
- [ ] Game Center for badges, or not.
- [ ] Paid tier: which features are paid (needs the Paid Apps agreement).
- [ ] Sign in with Apple revoke on account deletion: needs the Apple key in Supabase.

## Claude to do

### Next, small

- [ ] After Apple approves: the TestFlight button on the site
      (`testflight: { href: … }` in `PORTFOLIO/src/app/data.ts`) and the link under
      Install in the README.
- [ ] A live recording of an imported day can still count twice when the phone has
      no signal (the history read fails and only the server's 80 % rule is left:
      that needs a server change). Runs already doubled are not cleaned up.

### Resorts

- [ ] Zermatt's Cieloalto chair unloads with no run mapped within 500 m of its
      top. Read the Cervinia trail map for the runs it serves and draw them with
      `add_runs`. Megève's Mont Joly waits on the decision above.
- [ ] Six lifts 200 to 250 m from the nearest run, each with a link the report
      proposes; none had a source that could be opened on 23 Nov: Arlberg's
      Angerlift (beside Kinderland Stuben; the panorama PDF was a 404), Mount
      Snow's Covered Bridge #4 (drawn as a conveyor by the tubing park, but in the
      lift status feed), Les Ménuires' Jardin d'Enfants, the golf-course platters
      at Crans-Montana, an unnamed rope tow by Sölden's Gaislachalm piste, one at
      Verbier.
- [ ] Other lifts still cut off or unloading onto nothing: Kitzbühel's Aschau
      practice lifts (real beginner lifts; nothing goes back up from Aschau) and
      Bärenbadkogel I (its run starts 278 m from the top: OpenStreetMap needs
      fixing), Big Sky's Homer, Hintertux's Kaserer 2 (the runs leave 33 m below
      the mapped top, just over the 30 m limit: a link would do it), St. Moritz's
      Ponylift Marguns, Valle Nevado's Ancla (a closed loop with A Todo Pulmón),
      Rusutsu's Tower Pair (on foot, by its trail map), a Fieberbrunn drag lift.
- [ ] Monterosa: with the Punta Indren cable car gone, Salati 2 ends at Passo dei
      Salati with nothing leaving it. The report proposes a 202 m link to the
      Salati run; it needs a map that shows it.
- [ ] Les 3 Vallées: way 1505821791 is an unnamed chair whose ends are tagged as
      columns "from an old chair lift": a likely `exclude_ways`.
- [ ] The `no_ways` list of every published resort (official names with no line
      on the map).
- [ ] Live lift status for more resorts than the 16 reviewed ones.
- [ ] Stowe goes without live lift status: its provider maps 9 of 12 lifts, under
      the 80 % rule. Log the unmapped names, or compare the feed with the map's
      status names. Mammoth and Snow Valley are fixed (their "expected" lifts now
      count as on hold; worker version 6, 23 Nov). Schweitzer is closed for the
      season and Crested Butte probably is; both write nothing by design.
- [ ] A `manifest_hash` column on `resort_bundles` (a migration), so a rebuild of
      the same manifest keeps its number. Since 1.4.1 `publish` records each bundle
      above every number the server holds, so the column orders bundles as
      published.
- [ ] Change notes in bundles for the Maps list.

### Solver

- [ ] Tree cover per run, so sheltered runs differ in wind and flat light (pipeline
      change and a republish).
- [ ] Cloud top and valley fog.
- [ ] Tune the weather coefficients against a season of recorded runs.
- [ ] A heading on `MountainCore.Fix`; an end reason for a meet the server expired.
- [ ] Golden solver tests on a published bundle.
- [ ] Whistler has four times the meeting places since 1.4.0 (386, was 94). One
      solve in a Release build on the Mac takes about 0.32 s, up from 0.13 s, and
      still returns three options. Time it on a phone before deciding whether the
      solver should weigh fewer places.

### App

- [ ] The name's font shown to friends (a profile column and a migration).
- [ ] An onboarding step, "Bring your ski days" (planned 23 Nov, owner: not now):
      Apple Health first, then a row per app (Slopes, Ski Tracks, Strava, Garmin)
      with how to export from it and the Files picker. The app already takes all
      three routes; no Strava or Garmin sign-in. Confirm on a phone which apps
      write routes to Health.
- [ ] Resort picker: record demand for a requested resort (today the row opens
      GitHub issues).
- [ ] Light themes, a glare theme, and a shorter theme list.
- [ ] iPad and landscape layouts.
- [ ] A polish pass: time each open, close and transition; fix the slow ones.

### Housekeeping

- [ ] pgTAP for migration 0020 in CI.
- [ ] Measure map load size per look with `MapLoadProbe`.
- [ ] Watch the Open-Meteo quota if the catalog grows (about 3,700 of 10,000 calls a
      day now).

### Badges

26 of the 42 are earned from the run history and the meets reached; 16 show as
"Soon".

- [ ] The weather badges (Found You, Powder Day, Bluebird, Storm Chaser, Cold Snap)
      need the weather kept with each ski day or meet on the server. Right On Time
      needs both arrival times on the meet row; Summit Meeting and Lodge Lizards
      the kind of meeting place.
- [ ] Regulars and Crew count within the 200 newest meets the server returns: gold
      can be out of reach. It needs paging or a count on the server.
- [ ] Badges on a friend's card (needs the server).
- [ ] Whole Mountain and the terrain badges, with run tracking.

### From the tree review

The review of 22 Nov listed 224 findings. These are the ones checked as still open
on 23 Nov; the rest are fixed or decided. The full review is archived on the Mac.

- [ ] A skier moving at lift speed right beside a lift line can still be placed
      on the lift (faster or standing ones no longer are). It needs the heading
      on `Fix`, under Solver.
- [ ] A limit that blocks every route mid-meet ends the meet as "A closure blocks the
      route". It needs its own reason.
- [ ] Presence never carries a heading (goes with the heading on `Fix`, under Solver).
- [ ] Pipeline: publish is several calls, not one server transaction.
- [ ] Pipeline: a lift's mid-station is classed as a lift top.
- [ ] Pipeline: same-named meeting places still renumber when the first one is
      removed (a newly mapped namesake no longer takes an existing id, since
      1.4.1), and same-named lift and trail groups are numbered by sort order
      (`_assign_group_ids`).
- [ ] Pipeline, to check: the PBF path was never compared with Overpass element
      for element.

## Later: the ski day

Do what Slopes does, better, from what PowderMeet already knows: every recorded run
is matched to a named trail, and the app can route. In this order:

- [ ] **Run tracking.** All-day recording, a Live Activity, a day page. Measure
      battery on a real ski day first.
- [ ] **Mountain completion.** The profile shows it for the open mountain. Still to
      do: every mountain skied (each needs its map read), the day page, and the
      Whole Mountain and Halfway There badges.
- [ ] **Replay.** The day played on the 3D map, friends' tracks alongside.
- [ ] **Snow.** Overnight and daytime snowfall, a multi-day outlook, wind by lift.
- [ ] **Terrain.** Steepness and facing across the whole mountainside (own terrain
      tiles: check the hosting cost first).
- [ ] **Paid tier.** StoreKit 2 subscription: meeting up, friends and maps free; the
      ski-day features paid.
- [ ] **Apple Watch.** Recording and the next step at a glance.

## If it goes to the App Store

PowderMeet is a public beta and a demo project, not an App Store release (owner,
21 Nov 2026).

- [ ] Screenshots, privacy manifest, App Privacy answers, support and privacy URLs,
      age rating.
- [ ] A review account and a script for a two-phone meet.

## Not planned

- AR, and avalanche danger (wrong data there is a safety problem).
- Synthetic trees or 3D tree models.
- Marching lift dashes: they redraw the map every frame.
- A second resort builder: every resort goes through `pipeline/`.
- A Liftie status adapter, while Liftie refuses automated requests.

## Decided

- Friends are found by name or hashed contact email, never by phone number. Name
  search finds only people who have signed up.
- The fake backend ships in Release: TestFlight reviewers use the Dev menu on it.
- The Dev page stays open to every TestFlight build (owner, 23 Nov). A server-side
  lock exists unused: migration 0027's `developer_accounts` and `is_developer()`.
- `ThemeManager.shared` stays: every colour is read through `HUDTheme`'s static names.
  The custom-theme editor is gone; a saved custom theme still works.
- `resort_catalog` stays a SECURITY DEFINER view: making it SECURITY INVOKER would
  open unpublished resorts. The ten tables with row security and no policy are
  closed to clients on purpose.
- Brand ski images keep shipping. Non-Latin place names get ids of their own.
- A deleted account ends its open meet for the partner as "left".
- Weather scrubbing changes the forecast and the map, not the meeting options.
- The workers' User-Agent strings stay "/2.0".

## How things are done

- **Phone build:** Release build from a clean worktree of `HEAD` (copy the untracked
  `apps/ios/Secrets.xcconfig` in), then `xcrun devicectl device install app`. One
  `xcodebuild` at a time.
- **GitHub sync** (standing approval, with each phone build, after a secrets check):
  `git commit-tree "main^{tree}" -m PowderMeet`, then force-push that commit to
  `origin/main` with `--force-with-lease`. Local `main` keeps its full history.
- **TestFlight upload** (ask the owner first): archive, then `-exportArchive` with
  method `app-store-connect` and destination `upload`, signed with the App Store
  Connect API key in `~/.appstoreconnect/`.
- **Backend tests:** the Mac has no Docker, so pgTAP runs on CI: push, then
  `gh workflow run backend.yml --ref main`. Apply a migration only after it passes.
- **Republishing resorts:** from the Mac, `pm-pipeline build-all --reuse-extracts
  --only <ids>`, then `pm-pipeline publish <id> --bundle <bundle>` with
  `SUPABASE_SERVICE_ROLE_KEY` from `_local/secrets/supabase/`. GitHub's
  `publish-resort` workflow can build but not publish. If `uv run` says
  `No module named 'powdermeet_pipeline'`, iCloud hid the venv's `.pth`:
  `chflags nohidden pipeline/.venv/lib/python3.12/site-packages/*.pth`.
- **Website media:** files in `PORTFOLIO/public/projects/powdermeet/media/`, wired in
  `src/app/data.ts`; each link's `?v=` is the first 12 hex of the file's SHA-256. Run
  `npm run check:assets`, push `main` (Vercel deploys it), then check the live page.
- **Demos:** staging for every still and video is in `docs/DEMO-STORYBOARD.md`. Set
  run colours back to Difficulty before a capture.

### Resort method

For a resort that fails the routing gates (90 % of lift tops must ski back to base):

- Read the resort's own trail map (its website, Epic or Ikon page, or skimap.org)
  and write what it shows into `pipeline/decisions/<id>.yaml`: missing `links`,
  `merges` and `rename`, and `difficulty` where the feed and the map disagree. Each
  entry names its source. The images stay in the cache, never in the repo or the app.
- A run on the trail map with no line (new key `add_runs`) is drawn along the fall
  line and marked approximate.
- GPS logs count as evidence for links and names.
- A lift that carries no skiers (a sightseeing cable car, a ski-jump chair) is a
  `reject`, with the freeride lines that only it serves: Courmayeur's Skyway.
