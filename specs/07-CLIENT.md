# 07 Client

## 1. Sessions

Three actors, each a state machine with typed events. Lifetimes nest: `AppSession`
(per signed-in user) owns at most one `ResortSession` (per selected resort), which owns
at most one `MeetSession` (per non-terminal meet). Destroying a parent cancels its
children's task trees. No generation counters.

### AppSession
```
states: starting → ready(profile) | needsOnboarding | signedOut(reason) | failed(PowderMeetError)
events: signedIn(session) · linkOpened(session) · profileLoaded · onboardingDone · resortSelected(id) · resortCleared
      · serverEvent(ServerEvent) · reachability(Bool) · signOutRequested · tokenExpired
      · foregrounded · backgrounded (both passed to the ResortSession as appActive)
link:   online | offline | reconnecting | unconfirmed. `reconnecting` runs from the network
        returning until `meet_current()` answers (asked again with backoff while the
        failure is transient); `unconfirmed` is a network that is up with a server that
        did not answer properly, for which nothing is shown
owns:   BackendClient · one private realtime subscription (user:{me}) · FriendsStore
      · LocationProvider (not started until a ResortSession needs it) · PushRegistrar
      · Toasts · FlightRecorder · the child ResortSession
run():  subscribe realtime → load profile → social_snapshot → register device token
      → meet_current() (if non-null, select its resort and hand it to ResortSession);
        a token APNs gives the phone later (notifications allowed after sign-in, an
        answer slower than the 5 s startup wait, a token iOS replaced) is registered
        when it arrives (`PushRegistrar.tokenChanges`), and sign-out unregisters the
        latest one
signOut: cancel children → unsubscribe → signedOut (the sign-in screen shows at once) →
        then, with the tokens the backend still holds and inside the same event:
        device_token_unregister → end the meet under way (`MeetSession.leave`) →
        presence_clear → backend.signOut. None of
        these can fail the sign-out, and a sign-in started meanwhile waits for them.
        Account deletion signs out on the server before signedOut; an expired session
        makes no server call
prepareForTermination(): presence_clear when a resort is open (the app's willTerminate,
        best effort, called directly rather than through the mailbox)
intents that return a result (nonisolated): signInWithApple, signIn(email, password),
        signUp(email, password) → confirmationSent | signedIn, resendConfirmation,
        sendPasswordReset, openAuthLink(url) → isPasswordRecovery, updatePassword,
        displayNameAvailable(name); completeOnboarding(patch) throws so onboarding can
        return to the step at fault; setAvatar(jpeg) → path and removeAvatar (actor
        methods, so the saved profile is the session's), profileOnFile (the profile
        saved so far, also during onboarding, for its photo step), searchUsers(query)
        (`.social(.tooManyTries)` when rate-limited), reportUser(user, reason, note, context)
events: also socialRefreshRequested (a friend card opened)
linkOpened: same user → keep the session; another user → end the current session
        without a server sign-out (the SDK already holds the new tokens), then signedIn
```

### ResortSession
```
states: loadingBundle → ready(bundle, status?, conditions?) | failed(DataFailure)
events: bundleLoaded · statusUpdated · conditionsUpdated · fix(Fix) · friendsPresence([Presence])
      · proposeRequested(friend) · incomingMeet(Meet) · meetEnded · profileChanged(Profile)
      · appActive(Bool) (from AppSession's foregrounded / backgrounded)
owns:   BundleStore (disk cache keyed by bundle_id; verifies SHA) · status/conditions streams
      · resort topic subscription · presence publisher (presence_update throttle: 5 s moving
        (10 s with the app in the background), 30 s still, only routing-grade fixes per I-14,
        and only within `ResortVicinity.leaveM` of the bundle's box: browsing a map from
        afar publishes nothing)
      · the child MeetSession · Breadcrumbs · MeetPrefetch
        (the `MapSceneCoordinator` is not here: section 3)
```
- `MeetPrefetch` (AppCore), so tapping a friend shows options at once: one job at a time solves this phone with a friend whose fresh position is
  at this resort, nearest first, at most 6 friends. Answers are kept by friend, both
  people's coarse position (0.004° buckets, about 450 × 300 m), this phone's routing
  profile and the solve hour; a friend is solved again only when one of those changes,
  and status or conditions changing drops them all, including a job's answer that
  arrives after the change (the answer carries the bundle, status and conditions it
  was solved on). The friend's profile and pace are
  read once per session. A tap (`proposeRequested`) whose key matches starts the
  `MeetSession` on those options (`Context.seed`, with the people), and the session's own
  exact solve replaces them. Off while a meet session exists, with the app in the
  background, in Low Power Mode and before the map is ready; cancelled with the resort.
  Jobs are at least 5 s apart and four times the last solve's duration.
- `Breadcrumbs` (AppCore value): the user's own routing-grade fixes and friends' presence
  at this resort (`resort_id` this one or null), one crumb per person per 10 s by capture
  time, at most 2,880 each (eight hours), in memory only and gone when the session ends.
  An unfriend or block drops that person's trail and their position from `friends`,
  so the map loses them at once (`personRemoved`: from the
  `friend.removed` event the other side gets, and from the user's own remove or block,
  which the server does not echo). A friend who closed the resort, signed out or quit
  sends nothing more, so `friends` also drops a position once it is
  `FriendSignal.forgetAfterS` (15 minutes, the presence TTL) old, and never takes one
  that old; their trail stays for the timeline. The timeline reads
  `breadcrumbUpdates()` (a copy per kept crumb) and asks the copy `trail(for:since:)` and
  `positions(at:)`: the point between two crumbs under 60 s apart, else the last crumb
  before if under 15 minutes old, else nobody.

### MeetSession
```
states: proposing(options) → proposed(outgoing) | incoming(meet, ownRoute?) → active(route, progress)
      → ended(reason)
events: optionPicked · sent · changeProposal · proposalUpdated(meet) · accepted · declined(reason) · fix
      · statusChanged · conditionsChanged · progressFromPartner · partnerPresence
      · userConfirmedArrival · userEnded · rerouted(route) · partnerRouted · profileChanged(Profile)
      · serverHasNoMeet · resync · retry · solved · progressTick
owns:   SolveCache · route · progress · meet_progress_update timer · resync timer
```
- Resync: events are hints (protocol section 3). While the session has a meet row that
  has not ended it reads the row again every `resyncIntervalS` (60 s), on the resort's
  `reconnected`, and when partner progress arrives for a meet this phone does not hold
  as active; an active meet also reads the partner's progress again. A failed re-read
  is logged and the next one tries again. A row never moves the state backwards: a
  `proposed` row reaching an active meet is an older read and is ignored (the row has
  no version, and statuses only move forward).
- Leaving: closing or switching the resort, or signing out, ends the meet under way
  (`leave()`, after the session's tasks have ended): a proposal is withdrawn
  (`meet_end(user_cancelled)`), an invitation declined (`declined_by_user`) and an
  active meet ended `partner_left`. Best effort: a failure is logged and never blocks
  leaving. A relaunch, an expired session or another account's link ends nothing.
- Positions: only a routing-grade fix (I-14) places this phone for a solve, an
  invitation's route, navigation or a status review, and the partner's presence only
  while under `MeetPrefetch.freshPresenceS` old. An older one takes the no-fix path
  ("wait for a better GPS fix"); a status change then leaves the route alone until the
  next fix rather than ending the meet from where the skier used to be.
- Profile edits: `AppSession` sends every saved profile to the resort session
  (`profileChanged`), which passes it to the meet. Only a change to what routing
  reads (`SkierProfile`: level, hardest run, avoid, pitch, gear, body) counts: while
  `proposing` the options are solved again and the pick starts at the new best; while
  `incoming` the user's own route is worked out again. A sent or active meet keeps its
  route.
- Supersede: `changeProposal` from `proposed` re-solves into `proposing(replacing: sent)`
  under a new meet id; `sent` then calls `meet_propose(supersedes:)` and the session
  follows the new row. `userEnded` while replacing goes back to `proposed(sent)`. If the
  sent proposal is accepted meanwhile the meet goes active; if it is declined or expires,
  the pick is sent as a fresh proposal. The invitee's session, told its proposal was
  superseded, reads `superseded_by` and shows that proposal in place.
- Solves read `Dependencies.solveClock`: the real clock in an App Store build; in Debug
  and TestFlight builds an `AdjustableClock` (section 8), at real time until a pretend
  time is picked.
- Ghosts: while active, `ghostPlan` (`ghostPlans()` streams it) holds a `GhostPlan` of
  `MeetSolver.RouteProjection` tracks, which the timeline asks `ghosts(at:)` when scrubbed
  forward (the head of each skier, `arrived`, and up to 20 dots a minute apart). The
  user's track is the navigated route anchored at the last fix's progress; the
  partner's route is solved on this phone, as the meet options solve it, from their
  last presence fix on their profile and pace to the rendezvous, anchored at that fix's
  capture time and solved again from a fix at least 15 s newer (task `ghost-partner`).
  A track ends at the rendezvous; the partner's goes when their progress says
  `arrived`. Before a track's anchor it shows nothing: the past is the breadcrumbs'.
- Navigation cues come from `NavigationCues` (AppCore): each new instruction, a route
  replaced mid-meet (`rerouted`, carrying the hardest run above the skier's level when
  the new route is the easiest way down), leaving the route, the arrival, once each. The app plays them (section 6).
Every event goes through one method on the actor (`handle(_:)`); effects are `Task`s
stored in the actor and cancelled on exit from the state that started them. Results of asynchronous work are
applied only if `inputVersion` matches (one integer per session).

## 2. Features (screens) and intents

Views are stateless renderers of `@MainActor @Observable` projections published by
the sessions; they send intents, never call services.

| Feature | Projection | Intents |
|---|---|---|
| Auth and onboarding | `AuthProgress`, `AccountState` (pending confirmation, reset, new-password step, `NameCheck`), `OnboardingState` | signInWithApple, signIn(email, password), signUp(email, password), resendConfirmation, sendPasswordReset, openAuthLink(url), saveNewPassword, checkDisplayName, saveProfile(step), grantLocation, grantNotifications. One screen over the mountain backdrop: Log in / Sign up, the email form on a glass card, Or, Sign in with Apple; onboarding steps are glass cards over the same backdrop. Display names follow `DisplayName` (PowderMeetAPI); the name step starts empty or with Apple's name, never the placeholder |
| Map screen (the app; `specs/13-APP-MAP.md`) | `ResortModel` (scene, selection, `contextCard`, `goTo`, friends, meet), `AppModel.mapSheet` / `sheetPath` / `isProfilePanelOpen` / `friendRequestCount` | tap(feature), scrubTime(t), tapFriend (meeting options, or the friend's card while another meet is under way), goTo(run, lift or place), closeContextCard, open the resort picker, the profile panel and its four sections |
| Context sheet | `ResortModel.contextCard`: meet (active: a tapped run, lift or place first, nothing while the directions are put away; or just ended) > incoming > sent > options > run or lift > place > Go-to | the meet intents below; goTo, showRoute, close |
| Resort picker (sheet) | `resort_catalog` as `ResortDirectory` sections: last used, nearest, then by country; a resort with no published map is listed but cannot be selected; every row one layout, with a fixed block for passes, Map / No map yet and the map's build date or a placeholder | select(resort) |
| Friends (panel page; friend requests head it, counted on the profile button and the Friends tile) | `SocialSnapshot`, `DiscoveryState`, `PeopleSearchState`, `ReportState` | searchPeople(query) (debounced; results merged with the snapshot so a request sent since shows as sent), findFromContacts (email addresses only; once on grant, then quietly at most daily when Friends opens), request(user), respond(id, accept), withdraw, remove, block, unblock, openCard(friend) (pushed), report(user, reason, note) then offer block. A friend's card shows their photo, name, skill, ski pair, the four lifetime stats, where they are now and Meet up · Remove · Block · Report |
| Meet (context sheet) | `MeetModel.state` (options, outgoing, incoming, active, ended), `LapSuggestion` | propose(friend), pick(option), send, changeProposal, accept, decline(reason), end(reason), confirmArrival, followLap |
| Activity (sheet) | `ActivityHistory` (from `[DescentSummary]`), import progress and `[FileReport]`, `LiveRecorder.Status`, `RunDetail` | import(files) from the picker or "Open in PowderMeet" (the report is pushed inside Activity), importFromHealth, setRecording(on), openLogs, openRun, deleteDescent, deleteDay, resetAll |
| Gear (sheet) | `GearDraft`, the ability | edit (ski by name, discipline, type, length, waist, limits, body, ability); the ski picker is pushed |
| Profile panel | `Profile`, lifetime totals, `PhotoState` | rename, choosePhoto / takePhoto / removePhoto (`ProfilePhotoButton`), open a section |
| Settings (sheet: rows, each a pushed page) | `AccountState.identity`, `NotificationPrefsState`, `MapsSummary`, `MapShelf`, the location and notification permissions | Account (the email or "Apple ID, hidden email", resetPassword, signOut, deleteAccount), Appearance (theme and icon, units), Notifications (one switch per kind, sounds and voice), Permissions (location and notifications, each with its action), Maps (checkMapUpdates, downloadMap, keepMap, updateMap, removeMap, the automatic-update switch), About & Support (version, sendBugReport, links, the Mapbox and OpenStreetMap credit), Developer testing (test builds) |

Debug tooling is developer testing (section 8), inside the app and reachable only in
Debug and TestFlight builds; it covers routing checks, a test meet-up and a realtime
self-test. There is no separate debug target.

People are drawn with one view, `AvatarView(userID:path:name:size:)`: the photo at
`path` (`avatar_url`) in a circle, or the initials until there is one; for the
signed-in user the profile's own path wins, so a new photo shows everywhere at once.
Links the app opens go through `onOpenURL`: files to import, `powdermeet://auth-callback`
to `openAuthLink`. There are no add links: friends are found by name search.

## 3. Map

- `MapSceneCoordinator` (an `@Observable` class in the app's `Composition/`, owned by
  `ResortModel`; `AppCore` does not have it) builds `RenderInput` from bundle, status,
  routes, friends, selection, time and theme, calls `SceneBuilder.build` off the main
  actor, diffs, and sends `SceneDiff` to `MapboxMapController`.
- Static sources (edges, lifts, rendezvous, labels) are built once per bundle. Dynamic
  state (open/partial/closed/groomed, selected, sun exposure, route remainder,
  friends) is `feature-state` or small separate sources. A status change touches no
  geometry. Mapbox takes feature-state one feature per call, so `MapboxMapController`
  sends only the changed states of the sources a layer reads them from (closed
  segments and the meeting point); the selection is drawn from its own source.
- Closure truth: a status closure is keyed by group, so `SceneBuilder` closes all of a
  group's edges or none, and `partial` is reserved for edge-level status that no feed
  gives yet; closed segments draw exactly where they are; one open segment never makes a partially
  closed trail look open (I-15). Computed in `SceneBuilder`, from the same
  `ResortStatus` value the solver received.
- One camera owner (`MapboxMapController.camera` queue): resort intro, route framing,
  navigation follow. Catalog camera overrides are data. The intro runs once per
  mountain: the same mountain drawn again (a newer bundle, the style reloaded, runs
  recoloured) leaves the camera where the user has it.
- Camera commands (`MapCommand`): `follow(Bool)`, `recenter`, `focus(Coordinate)`,
  `resetNorth`, `showResort`, `showRoute`. Following starts by itself when a meet
  becomes active and ends when the user pans or pinches, or asks for `showResort`,
  `showRoute` or `focus`; the map reports the truth with
  `MapEvent.followingChanged`, and the follow button shows that, never what was
  last asked for. A follow asked for while another move has the camera is caught up
  when the camera next comes to rest.
- Taps: a trail or lift opens its card; a friend marker (or a chip in the friends
  bar) centres on the friend and, when no other meet is under way, sends
  `proposeRequested` at once, so the meeting-options tray opens over the map
  (`MeetSession` proposing; sending stays an explicit `sent`); a tap elsewhere backs
  out of that unsent proposal (`userEnded`, then `meetDismissed`). A place opens a
  card with its name, kind and amenities. One card at a time. Places draw the icon
  `PlaceIcon` picks from their amenities.
- GO TO: `GoToPlanner` (MapScene) gives a solo route from the phone's fix to a run's
  top or a lift's bottom station through `MeetSolver.route(for:to:in:)`, which routes
  to rendezvous only: the target is the rendezvous on the entry node, else the
  nearest within 300 m, else none. The origin is `OriginResolver` (AppCore), from a
  routing-grade fix only (else `notOnMap`): the nearest node within 35 m, else the
  nearest edge within 60 m, where a fix standing still (under 0.5 m/s) or moving
  faster than the lift can carry it (`PlaceLocator`'s bound: length ÷ ride time ×
  1.5 + 1 m/s) is never placed on a lift. It is solved off the main actor, drawn in route slot A while no meet route is, and
  framed with `showRoute` after the scene carrying it is published
  (`MapSceneCoordinator.sendAfterNextScene`).
- First load: the controller times each map from creation to style, first terrain
  tile, first view's tiles and first idle, logs it (`map load: …`) and sends
  `MapEvent.firstLoad(MapLoadTiming)` once. The app adds one `launch to map: … ms`
  line per process from that event; it is the regression check for launch speed.
- A base style that will not load (no signal, nothing cached) is tried three more
  times; then the controller sends `MapEvent.styleFailed` and loads a plain ground
  that needs no network (`MapStyle.fallbackStyleJSON`), so trails, lifts, routes,
  friends and the user still draw. The map's error card offers Retry
  (`MapCommand.reloadStyle`) until the base style is back.
- A new resort's sources are written as GeoJSON off the main actor; the
  controller applies the newest model once the text is ready and keeps it for a
  style reload.
- Maps kept on the phone (Settings → Maps, `13-APP-MAP.md` section 3): a
  resort's bundle in `BundleStore` plus a Mapbox tile region over its box
  (`MapOfflineRegions`: the satellite-streets style pack, the DEM and, per
  look, the photo or the terrain tileset). `MapShelf` (AppCore) says which
  resorts are held: the ones the user downloaded and the last three opened
  (recent, unless the user removed one; opening it again brings it back).
  Everything else on disk is cleared, bundle and region alike. Removal
  deletes the bundle, its pointer, status and conditions, removes the region
  (the style pack with the last one) and clears the SDK's ambient cache, since
  a removed region's tiles otherwise only move there. `OfflineMapPolicy`
  decides when work may run: a download the user started, on any connection
  but none (given to the SDK with no network restriction); the unattended
  work (caching recent resorts, refreshing tiles and taking newer bundles
  when "Update Downloaded Maps Automatically" is on) only when unmetered,
  outside Low Power Mode and once the open resort's map has sent `firstLoad`,
  given to the SDK with `networkRestriction: .disallowExpensive` so it does not
  continue on cellular. It runs when the catalog answers, the connection or
  map look changes, the map settles and the app comes to the foreground or
  goes to the background, inside `BackgroundGrace`; a failed pass is tried
  again the next time. The last catalog is saved in `BundleStore` and stands
  in when the server does not answer.

## 4. Offline and background

- Bundles, status and conditions are cached on disk with their expiry; the app always
  renders the last known state with its freshness label.
- Profile photos (`AvatarStore`, AppCore) are kept on disk under the composition root's
  cache directory, keyed by object path (a path names its bytes, so nothing goes
  stale), the 400 most recently used, with one download per path at a time; decoded
  copies live in memory (`AvatarImages`). Both are emptied whenever the session ends:
  other people's photos do not outlive the session that was allowed to see them. After
  each social snapshot the disk keeps only the photos it lists and the user's own
  (`AvatarStore.retain(paths:)`), so a replaced or removed photo, a deleted account or
  an unfriended person leaves nothing on the phone.
- The profile photo leaves the phone as a 512 × 512 JPEG redrawn from the square crop
  into a new bitmap, with no metadata (no location, camera or dates).
- Launch cache (`LaunchCache`, one file under the composition root's cache
  directory): the signed-in user's own `Profile`, with `current_resort_id` holding
  the resort on screen. Nothing about any other user is stored. `AppSession` writes
  it when the profile loads or is edited and when the resort changes, and removes
  it whenever the session ends. With a stored auth session and a snapshot for the
  same user whose profile is complete, `signedIn` goes straight to
  `ready(cachedProfile)` and the startup load runs behind it; `profileLoaded` then
  replaces the cached profile. If that load fails with an auth error, or the server
  has no profile for the user (signed out elsewhere, account deleted), the session
  ends in `signedOut(sessionExpired)` and the snapshot is removed. If it fails for
  any other reason the session stays `ready` on the cached profile and loads again
  when reachability returns or the app comes to the foreground.
- A resort this phone has opened before is shown from the cached bundle at once
  (still verified against its id, I-17); the catalog is asked afterwards, and a
  newer active bundle replaces the one on screen when it has downloaded and passed
  verification. A failed refresh leaves the working map alone.
- Location runs in one of the modes of `AppCore.LocationMode`, chosen by
  `LocationDemand` (an open resort, recording, an active meet, whether the phone is at
  a resort) and applied by the app's CoreLocation driver, the only code that sets
  accuracy or background updates: `navigation` (active meet: best, 5 m, background),
  `recording` (recording on at a resort: best, 5 m, background, significant changes),
  `presence` (resort open at a resort: 10 m, 30 m filter, background, so friends still
  see you with the phone locked), `browsing` (resort open far from any resort: 100 m,
  foreground only), `watching` (recording on away from resorts: 1 km while the app is
  open; with the phone locked only the significant-change service, with "Always", to
  wake on arrival), `navigationBackground` (an active meet with the app in the background
  and recording not on: 10 m, 10 m filter, background, never pausing,
  see below), `locating` (nothing else wants fixes and the app is deciding which resort
  it is in: 100 m, foreground only) and `off`. The blue indicator shows whenever
  background updates run.
- A meet with the phone in a pocket: `navigationBackground` trades best accuracy for ten
  metres and keeps activity type fitness. It does not let iOS pause updates (it did
  before 23 Nov): a skier waiting at the meeting point keeps repeating their fix, so
  their arrival stays inside the freshness bound (`03-PROTOCOL.md` section 2) and
  the friend's arrival completes the meet. Presence goes out every 10 s moving and
  30 s still, and progress every 10 s, which keeps the partner's view inside the 75 s
  "live" window.
  Outside a meet the background changes nothing.
- Opening the resort the phone is in (`ResortArrival`): at launch and
  on each return to the foreground the app asks for one usable fix (within 200 m and
  2 minutes old) for up to 30 s. Inside exactly one mapped resort's box it opens that
  resort; inside several (Alta and Snowbird overlap) the resort picker opens listing
  just those under "You're at". Never over a resort the user picked or closed this
  session, never during a meet, and never in the Debug preview stage, a scripted Debug
  launch, or while developer testing has teleported the phone or placed a dev
  person.
- Presence is cleared (`presence_clear`) on sign-out, before the server sign-out; when
  the user closes the resort without opening another, once the resort's tasks have
  ended; and best-effort when the app is terminated (up to 2 s of background time).
  Switching resorts needs no clear: the next update moves the row.
- `BackgroundGrace` (AppCore; UIKit's background task in the app) holds background time
  around the live recorder's upload of each finished run, the last one included, so a
  run that ends as the phone locks is saved before suspension. `ResortSession`'s `start`/`stop` say only whether a resort is
  open; recording and meets keep fixes coming after it stops. The `LocationProvider` is
  one `AsyncStream<Fix>` multicast to presence, navigation and recording; a `Fix`
  carries altitude and speed when the device measured them.
- Permission: onboarding asks "While Using" and says that "Always" comes later. The
  upgrade to "Always" is asked when the mode first becomes `navigation`, `recording` or
  `watching` (a meet becoming active, recording turned on), never at first launch.
- Local notifications (`LocalNotifier`, never prompting): "Runs imported · N runs" when
  an import finishes while the app is in the background, and the day's recording
  summary, one request per ski day replaced after every recorded run and due two hours
  after the last one. Their `kind` is `activity.imported` / `activity.summary`; a tap
  opens Profile. Any sign-out removes the pending and delivered summaries, so the next
  account on the phone never sees the last one's day.
- Pending uploads (descents, progress, events) go through one `OutboxQueue` actor
  with disk persistence, idempotent keys, and no silent drop: a decode failure moves
  the file aside and logs at `.fault`. Its files live in Application Support (beside
  the downloaded maps, included in the device backup), never in Caches, because a
  queued run may be the only copy; a queue an older build left in Caches is moved
  across before the first read. Only a typed refusal from the server (a meet or
  profile error code, except `not_found`, which an outdated schema cache also
  answers) moves an item to `rejected/`; every other failure, including an
  unclassified status or an unreadable answer, leaves it queued for the next pass.
  A row the database itself refuses (status 422: a bad value or a constraint) is
  set aside too. Meet progress is sent ahead of other queued items. Only one
  `presence_update` is in flight at a time: a fix due meanwhile is skipped, and a
  failed publish leaves the next fix due at once.
- What the phone keeps when the session ends. Every end (sign-out, an expired session,
  another account's link, a deleted account) removes the launch cache, other people's
  photos (above) and the contact lookup's matches, which name other people
  (`contacts.emailMatches.*`, every account's): the next sign-in looks them up again.
  A sign-out keeps what is the signed-out account's own and is only useful when it
  signs back in: its queued uploads (a queued run may be the only copy), the live
  recording file (`live-recording/<user>.json`, so recording resumes), and its
  recording switch and Apple Health watermark (`activity.liveRecording.<user>`,
  `activity.healthImportedAt.<user>`). A deleted account keeps nothing: after
  `account_delete` succeeds the session discards that user's outbox items and their
  `rejected/` copies (`OutboxQueue.discard(user:)`) and everything in `corrupt/`,
  whose owner cannot be read; once the recorder and any import have ended the app
  removes the recording file (`LiveRecorder.discardRecording`, which drops the run in
  progress rather than storing it), the two activity settings, the pending day
  summary, and the ski accent, and sweeps the outbox again for anything those tasks
  queued while ending. The recent-resorts list and the downloaded maps it keeps
  (`resorts.recent`, `maps.shelf`) belong to the phone, not the account, and stay.

## 5. Errors and logging

- `PowderMeetError` (01-ARCHITECTURE section 6). `Toasts` is a queue with
  de-duplication; flow errors render inline; blocking errors as alerts with recovery.
- A failed meet solve names who it is about, from the partner's profile name
  (`PowderMeetError.meetRouting`): `abilityBlocksAll` reads "You can't get down from
  here on runs within your limits." or "Dev 1 can't get down from where they are on
  runs within their limits."; `noRendezvousReachable` reads "Dev 1 can't reach any
  meeting point from where they are right now." when the solver names the partner, and
  "There's nowhere you and Dev 1 can both reach right now." when it names this phone's
  skier (it does so both when they reach no stop and when the two share none). With no
  name known, the unnamed `.routing` sentence stands
  (`aFailedMeetNamesTheSkierWhoCannotGetDown`).
- An easiest way down (06-SOLVER section 1) is labelled on the option card's WHY
  list, first, as a caution line: "Easiest way down for Dev 1" (or "for you") over
  "One blue run is above their level." (`MeetPresentation.easiestWayDown`). The
  invitee's and the active card show the same text from their own route
  (`MeetPresentation.easiestWayDownNote`). During a meet such a route gives way to
  a route within the level as soon as one opens.
- One transient message is on screen at a time, in one style. The connection
  (`AppSession.link`) has the slot while it is `offline` or `reconnecting` and for a
  moment after ("back online"); the notice changes its words in place and is never
  stacked with a toast that says the same thing. A badge just earned is a toast of
  its own kind (`Toast.Kind.badge`): a rosette, no action, and announced to VoiceOver
  as it appears (08-ACTIVITY section 7).
- `os.Logger` categories: `session`, `resort`, `meet`, `solver`, `map`, `realtime`,
  `location`, `activity`, `network`, `outbox`. `FlightRecorder` keeps the last 2,000
  entries at `.info` and above in a ring buffer and exports a redacted text file.
  `PMLog` writes every message as `privacy: .public`, so callers keep names, tokens and
  coordinates out of the text they log.
- `client_event` is sent for: `meet.proposed`, `meet.accepted`, `meet.declined`,
  `meet.active`, `meet.ended(reason)`, `reroute`, `bundle.loaded(ms)`,
  `solve(ms)`; a replaced proposal sends `meet.superseded` in place of `meet.proposed`.

## 6. Accessibility and UX rules

- Dynamic Type up to accessibility sizes in all non-map views; map HUD has a fixed
  large size.
- VoiceOver labels on every control. During an active meet: a soft haptic and a short
  `AVSpeechSynthesizer` prompt for each new instruction ("Ride Peak Express"), led on a
  reroute by "New route." and, on an easiest way down, "The only way down has black
  runs." in the same prompt, ducking
  other audio and releasing it after; a rigid double tap on leaving the route; an
  arrival pattern and bell (`Resources/Sounds/arrival_bell.caf`). One "sounds and
  voice" switch (`SoundsAndVoicePreference`, on this phone, default on) mutes prompt
  and bell; haptics stay.
- Option cards are headed by the solver's `Tradeoff` ("FASTEST TOGETHER", "EASIER
  TERRAIN"…). Over the options, the Meet tab says when there is no weather, or when it
  is past its expiry ("WEATHER IS STALE"; the solver keeps using the last reading).
  Each route's profile line ends with the first of its `weatherFavours` when it has
  one ("Blue max · 2 lifts · 2.2 km · Sunny side"; "Out of the slush", "Out of the
  wind", "Better visibility"; `Wording.weatherFavour`), and says nothing of the weather
  otherwise.
- A run or lift with no name is called the same everywhere it is shown (the map's
  label, its card, Go to, a route's steps, the logs and a run's sections):
  `TerrainName` in MountainCore, a run by its rating ("Unnamed blue run", "Unnamed
  park", "Unnamed run" when unrated) and a lift by its kind ("Unnamed chairlift",
  "Unnamed lift"); a link between runs is a "Connector". Its card then shows no
  kind line under the title ("Blue run", "Chairlift"), which would repeat it. On the map the label carries
  the vertical as a named one does ("Unnamed blue run · 120m") and only on runs of
  20 m drop or more and lifts of 15 m rise or more; a step adds its length.
- Glare theme: one tap in the HUD; persists per session.
- Tap targets ≥ 56 pt in meet and navigation flows.

## 7. Composition root

`CompositionRoot.swift` builds `Dependencies` on the live backend (the PowderMeet
project), `AppSession`, and the root view. There is no demo or fake backend in the app:
it is always checked on real infrastructure, with test accounts;
`FakeBackend` stays in `PowderMeetAPI` for package tests and as the developer
sandbox's private server; it is compiled into Release builds too and is reached only
when the gate in section 8 is open. Build configurations: `Debug` and `Release`; TestFlight builds
are Release archives, and developer testing tells them apart at runtime (section 8).

Debug builds read launch arguments (`DebugLaunch`, `DebugScript`) that open any screen
or state for a screenshot: `-openSheet`, `-openRoute`, `-profilePanel`, `-openResort`,
`-mapCard`, `-meetState` (through Dev 1), `-cardExpanded`,
`-debugTheme`, `-debugOnboardingStep` and `-debugImport`. Release builds ignore them.

## 8. Developer testing

A page for testing on one phone, on the live backend, pushed from its row in Settings
(the only place any developer control lives), in Debug and TestFlight builds only.

- **Gate (`DeveloperAccess`).** Debug builds always; otherwise a sandbox receipt at
  launch (`appStoreReceiptURL` named `sandboxReceipt`), confirmed or overruled once
  `AppTransaction.shared` answers: verified `.sandbox` or `.xcode` allows, verified
  `.production` refuses, and no answer or an unverified one changes nothing. A refusal
  is remembered for that build. The TestFlight binary is the one the App Store later ships, with the same
  UserDefaults after an update, so the answer is worked out on every launch and granted
  only on positive evidence. When the gate is closed at launch the composition root
  builds none of it: no `SandboxedBackend`, no `PlaceableLocationProvider`, the real
  solve clock, no `DeveloperModel`. App Review
  runs in the sandbox environment too, so reviewers see the menu.
- **Wiring (Debug and TestFlight).** `Dependencies.location` is a
  `PlaceableLocationProvider` over the real provider,
  `Dependencies.solveClock` an `AdjustableClock`, and `Dependencies.backend` a
  `SandboxedBackend` over the real backend (all in
  AppCore). `DeveloperModel` (app) is the projection; the views are `DeveloperScreen`
  (the Dev page), the pages it pushes (`PanelRoute.developerPage`: a dev person, Time,
  Weather, Diagnostics) and `DeveloperMapBanner`, the one place that says the phone is
  teleported, placing or on pretend weather, each with its way out (Back to GPS, Cancel,
  Real Weather).
- **The Dev page.** Short, so nothing on it scrolls away: Mountain (the mountain on
  screen, a Teleport Me switch, Move Me and the sharing switch while teleported), People
  (a Show Dev People switch, a row per dev person with their level and meet-up
  state, Shuffle), Solver (Time and Weather, each showing its value) and Diagnostics,
  each row opening a page of its own.
- **Mountain.** Any mountain with a published map (`selectResort`).
- **Starting spots (`DeveloperSpots`).** Meeting places and lift tops of the bundle
  (any graph node on a map with too few), each pick random among the candidates at
  least half as far from those chosen as the farthest one, so spots spread across the
  mountain. Seeded from the resort id (FNV-1a) and a shuffle count, so the same
  mountain gives the same spots on every launch. Spot 0 is this phone's: the Teleport
  Me switch puts it there at once and off is back to GPS. Spots 1 to 3 are Dev 1 to
  Dev 3: Show Dev People puts all three there (and on each mountain opened while it is
  on), off removes them all; Shuffle re-rolls the spots of those on the map; a dev
  person taken off alone is put back from their page.
- **Placing on the map.** "Move Me", "Move Dev n" and "Place by Tapping the Map" arm a
  `MapTapOverride`, which `ResortModel.handleMap` asks first about every map event, and
  send `MapCommand.captureTaps(true)` (sent again on `styleLoaded`), so a tap on a run or
  lift reports the point instead of selecting it. The point snaps to the nearest run or
  lift within 250 m (`DeveloperPlacement`); a tap farther away is refused on the banner
  and the map stays armed. A placed position is reported every 5 s with strictly newer
  capture times and 8 m accuracy, and the phone's own fixes are dropped until "back to
  GPS". In live mode a teleported position is not published (`presence_update` is
  withheld) unless "friends see my teleported position" is on, for two test accounts
  meeting from home.
- **Dev people.** Dev 1 to Dev 3 (`DeveloperSandbox.devPeople`), on this phone only.
  Each has a page, titled with their name: a level, a test meet-up while on the map,
  and Move and Remove (or Put on the Mountain and Place by Tapping the Map while off
  it). Each is placed, met and removed on its own; a removed one stops reporting and
  their marker goes at once (the sandbox unfriends and befriends them again, so this
  phone gets the `friend.removed` a real unfriend sends, after their last position); a
  meet with them ends. Ids are
  `00000000-0000-4000-8000-0000000Nf00d`, N = 0 for Dev 1 up to 2 for Dev 3 (Dev 1 keeps
  the old pretend friend's id, which the demo's friend photo uses).
- **Level.** The app's four levels (Beginner, Intermediate, Advanced, Expert) as a
  segmented control, a menu when it does not fit; Expert by default, so a dev person
  rarely blocks a meet unless asked to. A level sets the sandbox profile's `ability`,
  `max_difficulty` (the tier's usual hardest run: green, blue, black, double black) and
  `baseline_speeds` (the tier's preset), as onboarding would. The app keeps a friend's
  profile once read (`MeetPrefetch`, an open meet), so a level change unfriends and
  befriends the dev person again inside the sandbox: the next solve reads the new level,
  and a meet with them ends.
- **The sandbox.** `DeveloperSandbox` keeps a private `FakeBackend` holding the
  signed-in user (same id), the three dev people, their friendships, the mountain on
  screen with its rendezvous ids, their positions and every meet with them, each dev
  person played by a `RehearsalPartner`. `SandboxedBackend` sends `profile`/`paceModel`
  for a dev person, `meet_propose` to one, `friend_remove`/`block_user` of one (removes
  them) and `meet_respond`/`meet_end`/`meet_progress_update`/`meet`/`meet_progress` for
  the sandbox's meets there, merges the sandbox's user topic into `events()`, the rows
  of placed dev people into `presence_snapshot` and its open meet into `meet_current`,
  and forwards the rest. It keeps the user's own profile row as the real backend returns
  it, so a rehearsal routes this phone at the user's own limits. Dev people are in no
  social snapshot, so the friends screens never act on them; `AppModel.name(of:)` names
  them. While a dev person is on the mountain the meet funnel events (`meet.*`,
  `reroute`, `solve`) are not sent. The real server and the people on it never see any
  of it (`aPretendMeetNeverReachesTheRealBackend`, with two dev people).
- **Pretend time.** A time of day at the mountain (the bundle's zone), in 30-minute
  steps, or a preset (`SolverTimePreset`) on the lift day (`LiftDay`: the earliest
  opening and latest closing over the bundle's lifts on the solver's ISO weekday, a lift
  with no hours counting as the solver's 07:00 to 21:00; 09:00 to 16:00 when no lift
  runs): First Chair at the first opening, Mid-Morning 10:30, Midday 12:30, Last Chair
  15 minutes before the last closing, Night 21:30; Real Time and clearing return to real
  time. The Time page says whether any lift loads at that minute by the solver's
  half-open windows ("Open, 08:30–16:00" or "Closed at this time"). It moves only
  the solve clock, so lift hours apply; fix ageing, timers and expiries keep real time.
  A pretend time later than now reads status and weather as stale or degraded, and the
  Time page says so. It applies from the next solve.
- **Pretend weather (`PretendWeather`).** Real, Clear and Cold (−15 °C, calm, clear),
  Warm and Slushy (6 °C, sunny), Snowing (−6 °C, 18 cm new, 1.4 km visibility), Storm
  (−10 °C, wind 16 m/s gusting 26 from the west, heavy snow, 600 m) and Flat Light
  (−3 °C, fog, 300 m). `SandboxedBackend.resortConditions` returns the mountain's real
  row with that reading as `current` and in every hour from a day before now to a day
  and a half after (fresh for as long, so a pretend time still reads it), `source`
  `developer`; it keeps the last real row per mountain, so a switch shows at once
  (`ResortModel.showConditions`) and Real puts the real row back (or the real row last
  on screen, for a forecast replayed from the cache). Only this phone's
  solver, rehearsal partners and weather card read it; the backend is never told, and
  `ResortSession` never caches a `developer` row, so a relaunch starts on the real
  forecast. The banner says so while it is on.
- **Test meet-up.** "Run" on a dev person's page proposes to them from the map, as a
  tap would, and sends the first option. Their `RehearsalPartner` accepts after 4 s with
  its own estimate, routed at their level; then both skiers travel their routes at six
  times real speed, the dev person reporting presence and progress, this phone moved
  along its own route only while it is placed by hand (on GPS the tester moves
  themselves). Arrival and confirmation are the meet's own screens. A dev person can
  also be met by tapping them on the map, like any friend.
- **Diagnostics.** Its own page, refreshed every 2 s, in groups of labelled values
  (on the trailing edge while they fit, else on a line under the label): App (version
  and build, channel, server host), Connection (network from the connection notice;
  the user topic's subscription, last event and rejoins from
  `SandboxedBackend.diagnostics`), Lifts (the mountain, when the row was observed,
  the last read and whether it found a row) and Solver (time and weather). Ages read as
  "12 seconds ago" (`RelativeDateTimeFormatter`). "Copy as text" puts the same groups on
  the clipboard.
