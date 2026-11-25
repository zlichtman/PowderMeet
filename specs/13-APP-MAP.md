# 13 · App map: one screen

The finished app, screen by screen. Every view is built from the components in
section 4 and nothing else. If a feature has no place on this page, it does not
ship. There is no tab bar: the app is the map (`Views/Map/MapScreen.swift` and what
it presents). Notes in *italics* are design decisions open to revisiting.

## 0. Launch

The launch screen is the plain dark background in the map's tone; nothing red and
no wheel. A returning user goes straight to the map from the cached profile and
bundle (`LaunchCache`); the map shows its own loading inside itself if tiles are
slow. A small, calm spinner appears only when the start takes longer than 1.5 s
(first launch, signed out). A failed start offers Retry and Sign out on a glass
card. Sign-in and onboarding sit on one backdrop that `RootView` holds for both
(so it carries on between them): `PreMapBackdrop`, red and black liquid (no mountain and no map, so it stays clean), a mesh gradient in the theme's
background with two slow pools of the accent whose points drift, and the faint
2D contour lines over it. No map, so no Mapbox logo or ⓘ. Still under Reduce
Motion and Low Power Mode. Sign-in, in the theme's colours (nothing is drawn
in a fixed black or white): a top section in the theme's background whose lower
edge follows the form card's rounded top as far out as the card's side margin,
its corners concentric with the card's and its sides the screen's edges, so the
liquid shows as one even band round the card and below it, with no step; in it
the PowderMeet mark set into the page (both mountains in the accent, the one
behind softer, no tile), the word mark in primary text and the tagline in
secondary text. Then one glass card over the theme's background (the
system segmented Log in / Sign up control and the email form) and Continue with
Apple under it, with no "Or" line. Forgot? opens Reset password as a sheet with
the app's one chrome.

Onboarding is one glass card a step over the same backdrop, six steps
(`OnboardingView`): the name (saved when Continue is tapped), a profile photo, gear and
limits, location, notifications, contacts. The photo step is the photo button Account
has (choose, file, camera, crop, upload), large and centred; it is optional, Continue
never waits for an upload, and a failed one says why in the message row and leaves the
initials. Location and Contacts offer "Not now".

The map opens on the resort that was on screen last time, unless the phone is
standing in another one: then that resort opens instead, and when the phone is
inside two resorts' boxes the resort picker opens on just those, under "You're
at" (`ResortArrival`, `07-CLIENT.md` section 4). It never replaces a resort the
user picked this session, and stays out of the Debug preview stage and developer
testing.

With no resort picked (first run, or signed back in) the resort picker opens over
`PreMapBackdrop` with the mountain mark and the wordmark centred on it: no heading,
no sentence and no button, since the picker and the bottom row's "Choose a resort"
already say it.

The app is portrait only, on every iPhone: nothing is laid out for landscape. iPad
and other devices would need their own layout.

## 1. The map screen (the whole app)

The map fills the screen edge to edge. Everything else floats on it as
theme-tinted glass. From the bottom of the screen up:

1. **Bottom row** (`MapBottomRow`):
   - **Resort bar** (fills the row up to the profile button, one capsule):
     status dot, resort name, chevron; then the sky at the timeline's hour as a
     full-size symbol beside the temperature over the new snow. Tap the name:
     resort picker (each row says how fresh its map is; the last row asks for a
     resort that is not listed: `12-DESIGN-BRIEF.md` section 6). Tap the weather: the timeline jumps to now. Between the bar and
     the profile button, while a mountain is open and no meet is on, a search
     button (owner, 22 Nov) opens "Go to" (`MapSheet.goToPicker`): the mountain's
     lodges and landmarks (its meeting points) and every named run and lift (its
     own, one row a name), filtered as you type; choosing one plans the solo route
     there exactly as Go to on its card does: a run to its top, a lift to its
     bottom station (`GoToSearch`). With a friend picked the same button opens
     "Meeting places" instead (owner, 23 Nov: one search on the map). A route on screen that a closure cuts while
     the phone has no usable position is taken down with a line saying so, and
     planned again when the position is back. The name shrinks
     a little, then truncates, before anything else gives way.
   - **Profile button** (round, 52 pt, your photo or initials; a small accent
     count when friend requests are waiting). Tap: the profile panel (section 3).
   *No inbox: it would only repeat what already reaches the user. A
   meet request takes the context sheet, cannot be swiped away, and also arrives
   as a notification and as a banner over a section page; friend requests head
   the Friends page, counted on the profile button and the Friends tile.*
2. **Timeline**: always visible while the panel is closed; one glass card with
   the weather at the timeline's hour as the screen's main visual. Top: the sky as a large symbol beside the temperature, large ("25°F",
   one line, shrinking before it would wrap) over what it is doing, and at the
   trailing edge "Live · Nov 22 · 1:54 PM" (or Past, Forecast; the day at the resort) on one line, a tap back to
   now. Then four even columns in a well, the value over its word: New (snow),
   Falling (the hour's precipitation at ten to one while it snows, else None),
   Wind, Vis. Then the scrubber: what is ahead lit in the accent, what is behind
   dim, the hour ticks tinted by weather (quieter in the past), the marker in the
   theme's accent, and hours named under it three apart ("−3h", "Now", "+3h",
   "+6h" …). Scrub to see weather,
   sun and lift hours at a time; "Live" snaps back. More than 15 minutes back
   ("Past"), friends' markers replay where they were (`Breadcrumbs.positions(at:)`)
   with each friend's path since the start of the window drawn as an amber line;
   only people in the friends list now. More than 15 minutes ahead ("Forecast")
   during an active meet, both skiers become ghosts on their routes, a dotted
   trail to a labelled dot, "YOU @ 3:15 PM" in route cyan and "GlacierGlider @ 3:15 PM" (the whole name, never its first word) in
   route orange (`GhostPlan.ghosts(at:)`). Status never changes with the scrub.
3. **Friends row**: one chip per friend at this resort (photo, name, distance,
   live or last seen; while their fix is live and the map can place them, the
   run or lift takes the distance's place: "On Pika's Traverse · Live",
   "Riding Peak Express · Live", from `ResortSession.places`, which keeps each
   person's last `PlaceLocator` reading so the answer holds steady), closest first (by name without a fix of your own), scrolls
   sideways. Last chip: "+ Add friend" (Friends, with its search field already
   taking the keyboard). Tap a friend: the
   meeting options for them (section 2); the chip shows as selected. While
   another meet is under way the tap opens their card in the floating panel instead.
4. **Top**: nothing but the status bar's dark fade, the developer banner when
   developer testing has teleported, is placing or pretends the weather, and the app's one message
   (the connection notice when offline, a toast) under the status bar, or
   under the meet's pinned instruction while there is one, so it never covers
   the instruction or its open step list: it takes a row kept free under
   whatever covers the top (`MapChrome.messageRow`), which the panel, the
   context sheet and the floating lists stop under, and moves with the
   instruction on the panel's spring. The Mapbox logo and ⓘ are at the bottom
   (item 5).
5. **Mapbox logo and ⓘ** (owner, 21 Nov): side by side, centred at the
   bottom, the lowest thing on screen, under the resort bar and clear of the
   home indicator (16 pt up where there is one, 8 pt on a phone with a Home
   button); centred, the screen's rounded corners never cut them off. The
   bottom row rises just enough to leave them room (`MapChrome.bottomRoom`),
   so they never sit over a route or a card. Both are Mapbox's own views,
   unstyled ("You may not style the Mapbox logo": no tint, opacity or
   backing), the ⓘ opening their attribution (`MapAttribution`); nothing is
   ever drawn over them. The website's stills are taken without them
   (`-demoCapture`, Debug) and carry the credit as text beside the image.

On the map itself: runs and lifts by difficulty and status, the tapped run or lift
highlighted, friends' markers with photos (a live one with its run or lift in
small type just above: "On Pika's Traverse"), meeting points and amenity icons, and
routes, the boldest lines on the map; while a route is drawn the place and
lift-station icons and the whole-mountain landmarks step aside so it reads end
to end. "View route" looks down your route from behind and above you, toward
the meeting point, tilted like a trail map and zoomed to fill the map left
between the banner and the card. The camera aims at the map left between the top and the short context
sheet (`MapObscuredArea`).

The look: the satellite
photo on terrain exaggerated more at whole-mountain zoom than close in, with no
multisampling (4× MSAA left flickering pinholes in the terrain where labels
are drawn); the sun, the hillshade's light, the
sky and the atmosphere follow the timeline's hour (night navy with stars to clear
blue by day, never purple; dawn and dusk warm only the halo and the thin horizon
line; the photo dims at night; the sky is set again only when its colours visibly
change, and the tilt stops at 65° so the horizon band stays out from under the
header); run and lift
colours and labels are emissive, so the light never shades a difficulty colour.
The light changes only when the timeline's hour moves the sun a whole degree;
it is one set of style properties, never an animation. **Fly In** (Settings →
Maps, off by default, per phone): opening a resort flies in on a slow
descending orbit (3.6 s) instead of the short turn (0.8 s); Reduce Motion and
Low Power Mode skip it. **Snow**: light
flakes fall over the map, in from the top edge and down the screen with a
gentle lean in the wind, only while the forecast at the timeline's hour says
it is snowing (or strong wind lifts new snow) and the map is what the user is
looking at (no panel or picker over it), never under Reduce Motion, Low Power
Mode or in the background. They are a Core Animation layer over the map, not
the SDK's snowfall, so the map itself still draws no frames at rest while they
fall. The weather is set straight on the map controller (`setWeather`, like
`setFlyIn`), never through the scene, so nothing else is re-applied.
Otherwise nothing on the map moves at rest, so the map draws no frames
while the glass above it animates. *No marching lift dashes: a paint property changed eleven times a second would
make the 3D map redraw continuously and every glass surface over it re-sample, and
they are too thin to see at most zooms. Nothing re-applies the lighting when the
profile panel opens or folds.* *No 3D trees: the satellite style has none and models would
cost a download per resort.*

*Which maps stay on the phone for use with no signal is chosen in Settings →
Maps, not on the map.*

## 2. The context sheet (one at a time)

A single glass card above the friends row (`ContextSheet`) shows whatever the
moment is about. Short by default; a swipe up, or a tap on its grabber, shows
everything, scrolling inside the room the map leaves. × or a swipe down closes
what can be put away; a request or a meet has its own buttons. When two things
want it, the higher one wins (`ResortModel.contextCard`):

1. **Meet-up under way** (navigation must not take the screen; Apple Maps'
   turn-by-turn is the reference). The **instruction is pinned
   at the top** (`MeetNavigationBanner`, under the status bar): the cue for the
   end of the step (turn, lift, flag), how far is left of it, large; "Ski Pony
   Express" (or Ride, Take); "Then …"; under it that run's own figures on one
   line (length, vertical, grade, and the grooming, moguls and glide meters;
   a lift's ride time, length and vertical), worked out as the run card's are
   (`GroupFigures`) but over the stretch the step covers, so they never
   disagree with the step's distance; the run card need not be opened for each
   step (owner, 22 Nov); under that both arrival times, you in route
   cyan and the friend in route orange (with how old their fix is). Off route,
   or this skier being there, replaces the instruction; the friend arriving first does
   not: this skier keeps their next step, and the friend's time reads "Arrived"
   (22 Nov). Each arrival time carries the
   skier's photo ringed in their route colour (the initials disc without
   one), “You” for this phone and the friend's full name, which truncates before the time does (owner,
   21 Nov). A tap or a pull down opens every
   step under it, the current one marked, scrolling inside about half the
   screen and never more than the cards below leave, so the bottom row stays
   on screen; a push up closes the list, and pushed up again puts the directions
   away to a small pill ("Meeting GlacierGlider · you 6 min", the whole name, cut with "…" only when it runs out of room), the meet carrying on; a
   tap on the pill brings them back. The card at the bottom shows all it has
   at once, with nothing to swipe open: the meeting point, the map button
   ("View route") and put away (⌄, or a swipe down); the route as one strip,
   each run and lift a piece in its own colour, bright behind the skier and
   faint ahead, with how far is left; the lap suggestion; "End". There is no
   button to say you met: the meet completes by itself when both are there,
   and "End" is the way out when GPS can't place the two together. A
   run, lift or place tapped during the meet takes the sheet until it is closed,
   with the friends row visible while a run or lift card is open,
   under the same pinned instruction. When it ends: how it ended, Done. *The
   partner's own steps are not on this phone, only their arrival time.*
2. **Incoming request**: who, where, how long for each of you, Accept, Decline;
   swiped up, your route. Also arrives as a notification. A new request folds the
   profile panel so it shows; over a sheet it shows as a banner that
   closes the sheet when tapped.
3. **Request you sent**: waiting for them, where, your time, the countdown;
   Change spot, Cancel.
4. **Meet-up options** (after tapping a friend): their name, distance and live
   state; the option cards one per page (swipe between them; the map draws the
   one on screen); "PowderMeet" sends. Swiped up, each card shows its reasons and
   both routes. A change to the user's level, hardest run, avoid choices or
   gear (Gear) while the options show solves them again; back on the map the new
   best option is on screen, the camera frames it and its routes draw on again,
   so the meeting point visibly moves (`ResortModel.mapVisibilityChanged`).
5. **Run or lift card**: name, difficulty or lift type, open or closed, length,
   vertical, grade (or ride time); "Go to" routes you there alone. A run also
   shows three meters, four bars each: Grooming (green), Moguls (amber),
   Glide (cyan) (`TrailConditions` in MountainCore, scored from the groomed
   state, the run's pitch and aspect and the weather at the timeline's hour);
   then the weather at that hour on one line (sky, temperature, new snow, wind,
   the hour). The temperature and wind are the run's own: the forecast moved to
   its height and slope, as routing reads it (`MeetSolver.localConditions`),
   and the sky shows fog when the run is in cloud. Swiped up: the run's elevation
   profile (`ElevationProfile` in MountainCore: height against distance down the
   longest way through its edges, top on the left, the top and bottom heights over
   its ends, drawn in the run's colour and never animated; VoiceOver hears the top,
   the bottom and the card's own Vertical as the drop; none for a lift, a run whose
   vertical shows "—", or one whose longest way down is under half its mapped length); what sets the run
   apart ("On this run: in cloud · thawed and refrozen", or "in the sun"),
   groomed today or not and what the meters are judged from, or a lift's
   capacity. *Moguls: a run the bundle flags `moguls` (OSM
   `piste:grooming=mogul`) starts higher than any other ungroomed run
   (`06-SOLVER.md` section 2.2).*
6. **Place card**: meeting point or amenity: name, kind, what is there; "Go to", or "Meet here" while picking where to meet a friend: a place tapped on the map then keeps the unsent proposal, and the place joins the options.
7. **Go-to route**: where it ends, time, distance, lifts, vertical, the map
   button; swiped up, the steps; × ends it. A route that is the easiest way down
   (runs above the skier's level) says so, collapsed or open.

**Motion**: one spring family
(`MapChrome.panelSpring`, and `MapChrome.arrival(n)` for the same spring a beat
later) across the map's chrome:
- *Tapping a friend* (chip or marker): the chip shows selected, the options card
  rises from the bottom, the camera frames the option, its two routes draw on
  from their starts (1.2 s) and the meeting point drops in as the lines near it
  (a short fall with a little overshoot, 0.5 s). Swiping to another option, or a
  re-solve that moves it, replays the framing, the draw-on and the drop.
  Swiped up, the options card is a few pieces of glass straight on the map,
  with no sheet behind them and no grabber, sitting at the bottom so the map
  and the routes drawn on it stay in view above (the camera frames the
  option in that room), every row on one icon column. One block holds the
  option: its headline in title case with an icon of its own (a star only on
  the pick), "Together in …", the place, the expected wait, any caution, and
  every reason it is offered, said outright with nothing to open, then the
  lap. Then your route and the friend's route, each its own piece led by that
  person's photo ringed in their route colour, opening to its steps, one open
  at a time. The pieces grow upward, to a small gap under the status bar
  before they scroll. Under them a centred page indicator (a tap on it goes straight back to the
  first option), and the friends row. A tap on the picked friend's chip puts
  them back, so nobody need stay selected. The bottom row's search button opens "Meeting places", a
  floating list over the map like the resort picker (`MapSheet.meetPlacePicker`):
  every meeting point in the resort under Lodges, Runs, Lifts and Landmarks,
  filtered as you type. Choosing
  one adds it as one more option, "Your Pick", shown at once, with both
  routes, "Together in …" and who waits how long, to send like any other; a
  place the two cannot both reach says so instead. The list's first row takes
  the pick back. a sideways swipe anywhere on the pieces turns to the next option,
  which is fully off screen until then. The forecast scrubber is hidden, and
  the resort bar at the bottom becomes the send button ("PowderMeet" between
  two bolts). A swipe down folds the options back to the short card. The card has no header of its own: the friends row stays below it
  with the friend's chip lit, so who the options are for is plain and another
  friend is one tap away; a swipe down closes it. While a card with a route on
  it is open (options, an invitation, a sent request, Go to) the weather card
  folds to the hour and the scrubber.
- *Sending, and the friend accepting*: options, sent, incoming and under way are
  one card (`ContextCard.family`): its glass morphs to each new size while the
  state inside crossfades; no swap, no jump. Any other card rises.
- *Opening a resort*: the fly-in (when on) or the short turn; once the map has
  drawn (or after four seconds at most), the friends row and then the timeline
  rise into place in order (`ResortModel.hasSettledFirstView`).
- The pinned instruction slides down from the top; its step list and the pill
  use the same spring. Map-side motion is bounded (it stops when done) and is
  skipped under Reduce Motion.

## 3. Profile panel and its sections

The profile button opens the **floating panel** (`PanelHost`) in the space
between the message row and the bottom row, over the dimmed map. The bottom row
never moves: it is outside the swap and its own glass container. The panel grows
out of the profile button's corner (scale from bottom-trailing with a fade)
while the context sheet, friends row and timeline sink behind the bottom row and
fade, all on one spring (`MapChrome.panelSpring`); the panel, the map's stack and
the bottom row are separate glass containers, so no glass melts into a
neighbour while it moves. Nothing on the map moves at rest, so opening the
panel asks nothing of the map (section 1).

Its first level is the **profile panel**: just above the row the four sections
as equal glass tiles (`PanelTile`: icon and title on one line, one short summary
under them: "3 friends", "14 days", "Atomic Bent 110 · 184 cm", "PowderMeet"; a
summary too long for its tile shows only its first part, "Atomic Bent 110", never
a word cut off; every tile's icon sits in one column, so titles line up);
above them the **profile**, in separate glass pieces over the map with no card
behind them (owner, 22 Nov), with no pencil or camera mark, though a tap on the
photo still changes it and a tap on the name opens Account: on top a badge row (`ProfileBadgeRow`: the pins earned so far, side by side or stacked over one another when there are too many for that (never more than about a third of a pin covered; past that the first ones show), "3 of 42" and a chevron; a tap opens Badges, a floating list like the others (`BadgesFloatingPicker`): search, and a sort button with Kind (the six groups), Earned (finished ones, then those with a level still to go with the higher level first, then to earn, then soon), Level (gold, silver, bronze, earned, not yet) and Name; one row a badge, two lines that never wrap (the name over how it is earned), the pin in colour at the tier reached or grey; on the right a tiered badge shows its three levels as bronze, silver and gold dots, filled when reached, over the count toward the next ("4 / 10", or "Gold"), an earned single badge a seal, and "Soon" on those nothing is recorded for yet; `08-ACTIVITY.md` section 7); under it, in one row, the name piece on the left, its lines centred, the photo in a glass ring in the
middle and the levels piece on the right, the two sides the same width. On the
name piece, the
name in the lettering chosen in Account, with under it the selected
resort in the theme's accent and, while this phone's fix is live and the map
can place it, the run or lift ("On Little Whistler"; nothing otherwise), and at
the right two levels, one word each, each after the mark of where it comes
from, the marks in one column: on top, with Gear's sliders, the level picked
in Gear, which routing uses; under it, with a small chart mark, the level the
imported runs back, the one whose limit is the hardest marked run in the log
(`ActivityHistory.backedAbility`); that second line is absent until a rated run
is in the log, the
two on a piece of their own.
Under that row the ski pair, large, on glass of its own, with nothing written
on it (a tap opens the ski picker, as Gear's skis do, and the panel waits
under it). With a resort selected the pair glows green while this phone's fix is
live and red without one. With a mountain's map open, one piece under the
skis, as short as the badge row, says how much of it the skier has skied:
"Skied", a bar and "42 of 213 runs" on one line (`MountainCompletion`: the map's distinct named runs, and those of
them the run history at that resort names, matched as Run Completion matches
them; unnamed runs count toward neither), absent when no map is open or the
map names no runs. Then five figures in a row (distance, vertical,
average and top speed, then days, which sits over the pace row's runs), and under them, once imported runs have
calibrated the pace model, the learned pace: one cell per level learned (at
most four), its trail symbol in its colour over its speed, and a last cell
with the number of runs it rests on; nothing before then. Routing keeps the
pick. The button
again, a tap on the map, or a swipe down folds it.

Each tile continues in the same floating space (section 3a):

- **Friends**: requests waiting, your friends (tap: friend card, pushed), Contacts
  (find friends from your contacts by their hashed email addresses; phone numbers are not used), suggestions, sent
  requests, blocked. Empty sections are left out, with no "no friends" card, so a
  new user sees Contacts first and it stays on screen with the keyboard up; a
  contacts lookup that finds no one says so on its own row. The search field at the bottom finds anyone by name
  (`search_users`, debounced). While it holds a query the page shows only the
  people found, each row by its relation: a friend (tap: their card), a request
  they sent (accept), one you sent (cancel), anyone else (add). Every person row
  has "…" and a long press with Block and Report (and Remove for a friend). A
  friend's card has only Meet up at its foot; Remove, Block and Report are in the
  "…" at the end of its title bubble, away from it (12 §1). A friend here and
  live reads "On Pika's Traverse" (or "Riding Peak Express") on their Friends row
  and on their card's Now row, in place of "At Whistler Blackcomb", which stays
  when the map cannot tell.
  *People are found by name only: no codes, QR or add links.* *There is no meet
  history to show as "recent meet-ups".*
- **Activity**: view logs (days, runs, run detail: the figures, the track and
  its Route, the matcher's sections in skied order, named and unnamed runs,
  connections and off the map, each with its start time, distance and
  duration; a log row keeps the run's one name), live recording, import
  (activity files and `.powdermeet` backups, also opened from Files) and Apple
  Health (the learned pace is on the profile card); Data: Back up (makes the `.powdermeet` file and opens the
  share sheet) and reset (eight runs deleted at a time; the row counts them,
  "Resetting… 120 of 672", and a day or run delete goes the same way).
- **Gear**: the skis drawn large on their own glass tile (the button to the ski
  picker, with a "Change" swap mark and a press response) over one line; then
  one glass group per
  section: Skis (ride; custom gear: type, length, waist; a catalog ski: length,
  with type and waist read from the model; a Powder ski in the picker is
  Freeride here and in pace), How you ski (level as words, hardest
  run as the trail symbols in their colours, steepest, avoid), Body (height,
  weight), Pace (learned from n runs). Labels and values only. Edits save half a
  second after the last change (one `profile_update` per edit, not per step).
  **One gear label** (`GearDraft.label`) everywhere ridden gear is named (the
  ski button, the Gear tile, the ski strip on your card and a friend's): the
  catalog ski by name, otherwise "Skis", then the length:
  "Atomic Bent 110 · 184 cm", "Skis · 184 cm".
- **Settings**: separate glass tiles that spin out like the profile panel's,
  each a page, its value under it: **Account** (first, Profile: the photo, a tap
  changing it: Choose Photo, Choose File, Take Photo, Remove, the square crop with
  its title on top and Cancel and Use photo at its foot inside the safe area; the
  display name in a field, saved with a tick; and Font, the name's lettering on the
  profile: Standard, Bubbly, Serif or Mono, kept on this phone; then Email or Apple
  ID), **Appearance** (Theme, Map, Icon and Units as four tiles, each one word, two
  by two; Map opens a
  floating list in two parts, each row a symbol in its own colour on a small tile
  and a name, no description (owner, 22 Nov). **Map**, how the ground is drawn:
  Satellite, the default; Whiteout, white shaded relief; Blueprint, navy with cyan
  contours; PowderMeet (named Holographic before 22 Nov; `MapLook.holographic`), black
  with relief and contours in PowderMeet red whatever the theme. Their marks: a
  green globe, a pale snowflake, a blue pencil and ruler, and for PowderMeet the
  app's own icon with the wordmark as its name. PowderMeet's own entry is first in every list (themes, map styles, icons) whatever is chosen and however the list is sorted; Satellite stays the default map. **Lines** (the group's label; the foot of the list shows the map style and, after a divider, the line colouring, both as names alone), what
  the colour of each run's line says (`RunOverlay`): Difficulty, the default;
  Steepness, the steepest pitch on the run in eight steps from under 15° to 45° and
  over; Facing, the way the run faces in eighths of the compass; Run Completion (a checklist mark; named My runs before 23 Nov), how often
  this skier has skied it, from the activity history, never-skied runs grey. Each of
  the last three shows its legend under its name. While one is on, its legend sits in a capsule at the top of the map (a
  tap opens this list; it gives way to a meet's directions, open options and the
  profile panel) and the lifts draw grey, since their gold would read as one of
  its steps. They colour the runs, not the
  ground: the bundle holds each run's pitch and facing, and the lifts, closures and
  routes draw as always. A pick or a new
  theme repaints the open map in place, never reloading its style, and every
  map on the phone is asked for again with that look's tiles), **Notifications**
  (one switch for each of the eight kinds, and Voice and Bell; while iOS has notifications off or has not asked yet, a "Notifications Are Off" row leads the page with Settings, or Turn on; the tile reads how many are on, "6 of 8"), **Permissions** (location and
  notifications, each with its action), **Maps** (owner, 21 Nov: each user
  picks which resort maps stay on the phone; the tile's value is "3 maps · 1.2
  GB". The page: one small glass line on top, how many maps are on the phone
  and the space they take ("3 maps on this phone · 1.2 GB", led by "No
  connection" without one), beside Check for Updates; Fly In under "Look",
  above the list so it is found; "Update Downloaded Maps Automatically" under
  "Updates", on by default; then every resort with a published map, A to Z
  within each group, the ones on the phone first: "Downloaded" (kept until
  removed), "Recent" (the last three resorts opened, the one you are at
  among them, cached by the phone itself), then "More Resorts" ("Resorts"
  when nothing is on the phone); the search bar at the foot, and while it
  holds a query the page shows only the resorts found. A download is the
  trail map and the map imagery (`MapShelf`, `MapOfflineRegions`), so the
  resort draws and routes with no signal. Each row's detail is its size on
  the phone, or "BC · About 120 MB" before it is downloaded (estimated from the
  tiles its box covers), "Downloading · 45%", "Recent · Saves on Wi-Fi" while a
  recent one waits, or what went wrong in plain words. Each row has one
  control: Download; Stop while downloading; Remove (with a confirmation
  saying the space it frees); Update in place of Remove when updates are off
  and a newer map is published; a recent row also has Keep, which makes it a
  download. A long press holds the same actions. Remove deletes the trail map,
  its status and conditions, the imagery, and the style with the last map, and
  empties the map's tile cache, so the space is freed at once. A resort that
  falls off the recent list, or was only opened for an import, is a cache the
  phone clears. Caching the recent ones and the automatic updates run only on
  Wi-Fi, outside Low Power Mode, and after the open map has drawn its first
  view: when the catalog answers, the network or look changes, the map
  settles, and the app comes to the foreground or leaves it (inside the
  background grace). The catalog is saved on the phone, so the maps on it
  are listed and open with no connection. The words "offline" and "online"
  are not used. *The bundle carries no change notes, so a row cannot say what
  changed.*),
  **About** (version; Safety, a "Not a Safety Tool" row whose footnote is three short
  bulleted lines ending "You use PowderMeet at your own risk.", the one caption here; Bug
  Report, Support, Privacy, Map Data with the Mapbox and OpenStreetMap credit; row titles
  in Title Case), and **Dev** with a hammer (test builds only; the odd seventh tile, so it spans the whole last row, while the six others fill three even rows; every developer control
  lives there and nowhere else, on one short page: Mountain (the mountain, a Teleport
  Me switch, and while teleported Move Me and Friends See My Teleported Position); People
  (a Show Dev People switch and, while it is on, one row per dev person opening their
  page, and Shuffle);
  Solver (Time and Weather rows, each opening its page); a Diagnostics row opening its
  page. A dev person's page holds their level as the app's four levels in a segmented
  control (Expert to start), Test Meet-Up, Move and Remove; the Time page a half-hour
  stepper, whether lifts load then and the presets; the Weather page the pretend
  conditions; the Diagnostics page labelled groups and "Copy as text". "Teleported" and
  the pretend weather are said only by the banner over the map; `07-CLIENT.md`
  section 8). Row and tile titles on every Settings page are in Title Case ("Reset Password", "Meet Requests", "Voice and Bell"); details, footnotes and buttons stay in sentence case. No explanatory captions (the notification step keeps one line per kind, which 12 §7 asks for); one-word headers.

## 3a. One presentation rule

- "Pick one from a list" floats over the map: no sheet, the map
  dimmed a little behind, the list's glass rows scrolling inside a bounded area
  (never under the status bar or off the edges) with small floating labels between
  groups, the search bar under them, and at the foot the current choice in a
  bubble with × beside it as a button of its own, like a back arrow
  (`FloatingPicker`, `BottomSearchBar`). The search bar ends where that bubble
  does, and in the space above × the long lists carry a round sort button
  (`FloatingSortButton`): a menu of orders with the current one ticked, remembered
  between openings. Resorts: Country (the sections above), Nearest, Name, Pass.
  Meeting places and Go to: Kind (their groups), Name, Nearest. Nearest without a
  known position is Name. Badges: Kind, Earned, Level, Name. Logs (the page, beside its search bar): Newest, Oldest, Resort, Most Runs, Most Vertical. Themes: Name, Colour (the accent round the colour wheel), Shade (darkest background first). Skis: Brand, Type, Name, Width (narrowest underfoot first). Icons: Family, Name (the PowderMeet icon is named by the wordmark, in its row and at the foot, as the PowderMeet theme and map style are). Every list with a search bar has a sort button beside it; map styles have neither, the list being short enough to see whole.
  A tap on the map, × or a pull down closes it. The resort, theme, ski, app-icon and meeting-place pickers all
  float, in one structure: the same rows, the same search bar, the same foot. Opened from a panel page (Appearance, Gear), the panel waits
  under it and shows again on that page when the picker closes. The theme list is
  flat: themes the user made in an earlier version, PowderMeet (the default theme; a saved
  "Classic" reads as it), then every other theme alphabetically; swatch and name only. The palettes'
  licences are under About → Acknowledgements and in `docs/THIRD_PARTY_NOTICES.md`.
  The ski picker also holds the skis' glow (its one home): one switch, "Glow",
  with no icon, and while it is on two buttons for its colour: "Ski", the
  chosen ski's own accent (`SkiModel.accentHex`, measured from the topsheets;
  the PowderMeet ski's red for custom gear), or "Theme", the app theme's
  accent. The picker shows the skis once, in its header, drawn in the glow. Used wherever skis are drawn. *There is no colour bar, no
  preset dots and no Status colour.*
- "Manage" is not a sheet: floating glass panels, no backdrop. The four sections and every page inside them (Account,
  Appearance, Notifications, Permissions, Maps, About, Dev; friend card,
  blocked, report; logs, run detail, import report; delete
  account, reset password) continue in the floating panel: the level above gives
  way where it stood and the page's glass bubbles float straight over the dimmed
  map, with no sheet and no opaque or grey backing (`PanelHost`,
  `AppModel.panelPath`). A level that lists places to go is tiles
  (`PanelTile`, spinning out); a leaf page is glass groups. A page has a glass
  title bubble with a back control to the level above (the top level goes back
  to the profile panel); its groups hug their height above the bottom row and
  scroll inside once they reach the message row (`pageScroll`). Deeper slides in
  from the trailing edge; the levels underneath stay alive, so a search or an
  open day is still there on the way back. A tap on the map, a swipe down (on the
  title, or a pull past the top), or the profile button closes it all; VoiceOver's
  escape goes back one level. Editors save as they go. "+ Add friend" opens
  Friends with its search taking the keyboard; a friend tapped during another
  meet opens their card in the panel. A meet request folds the profile panel; on
  a section page it shows as a banner on top that folds the panel when tapped.
- Section headers over the map are small glass labels; small print under a
  group has its own glass.
- Only the system's own sheets remain: share, Files, the photo library, Apple
  sign-in; and sign-in's reset sheet and onboarding's ski list.
- Search sits at the foot of its page, above the bottom row and above the
  keyboard when it opens, with the list scrolling above it: `BottomSearchBar` in
  the floating pickers, Friends and Logs.

## 4. Building blocks

All in `apps/ios/PowderMeet/Theme/` and `Views/Components/`; no screen styles
itself.

- **Glass card** (`glassCard()`): theme-tinted glass, 22 pt corners, 16 pt padding.
  `glassCardControl()` for a card that is a control (a tile, a resort row).
- **Glass bar** (`glassBar()`): the resort bar; capsule, 52 pt tall.
- **Row** (`GlassRow`, `GlassNavRow`, `GlassLinkRow`, `GlassToggleRow`,
  `PersonRow`): icon, title, one-line detail, trailing value, switch or chevron;
  56 pt; rows in one card split by hairlines (`GlassDivider`).
- **Section** (`GlassSection`) and **section header** (`SectionHeader`): one size
  everywhere.
- **Buttons** (`Buttons.swift`): primary (`PrimaryButton`, accent fill, 52 pt, or
  44 pt hugging its label on a card), secondary (`SecondaryButton`, glass, or a
  well on a card; `destructive` turns its label red), icon button (`IconButton`,
  44 pt round), `CloseButton`.
- **Chip** (`glassChip()`): friend chips, status messages, the off-screen friend
  chips; one height, 44 pt. `StatusChip` for a short status inside a card.
- **Field** (`glassField()`): denser glass, or a well on a card.
- **Text**: Apple's text styles through `TextRole` (`Theme/TextRoles.swift`):
  SF Pro, Dynamic Type, sentence or title case, standard weights; no monospaced
  lettering, no custom tracking; `.monospacedDigit()` only where numbers tick.
  Map labels drawn by the map style stay as they are.
- **Colour**: the theme's accent, text and card colours, all glass tinted through
  the one `HUDGlass` source; difficulty, status and route colours on the map and
  as marks.

## 5. Not in the app

- A tab bar or a separate meet tab; a friend picker or "friends here" list (the
  friends row does both).
- Page header bars ("MAP", "PROFILE").
- A full-screen Profile page: the profile panel and its section pages do the job.
- Done buttons on sheets, custom sheet headers, an opaque content-card tier.
- A demo mode or its switches; the app runs on the live backend only. The one
  exception is Dev (section 3), in test builds (Debug and TestFlight), whose sandbox
  uses a private fake backend that ships in Release builds too (`07-CLIENT.md`
  section 8). Debug launch arguments are ignored by Release builds.
- Duplicate places for the same thing: friend requests live in Friends (counted on
  the profile button and the Friends tile); meet requests in the context sheet,
  the banner and the notification.
- An inbox: a round button in the bottom row and a card in the context sheet's
  place.
