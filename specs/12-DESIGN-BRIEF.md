# 12 Design brief

What each screen keeps, what it improves and what is new. The HUD content is dense but
readable, honest about data and consistent; the look is one design language, "Liquid
Glass" at the end of this brief. Where the sections below mention tabs, header bands,
monospaced type, upper-case labels or opaque cards, "Liquid Glass" and `13-APP-MAP.md`
win; the content, states and honesty rules they describe still hold.

**Reference material.** The theme tokens are `PowderMeet/Theme/HUDTheme.swift`,
`ThemeManager.swift` and `AppTheme.swift`: a tonal stack (bg 0.06, header 0.09,
input/card 0.13, border 0.22 luminance on the theme hue), four text tiers, accent from
the theme (see Themes at the end), trail colors green `5DEA8C`, blue `7AB8FF`, black
`F5F5F7`, double black `FF5C6E`, park `FF8533`, lifts `FFD166`, route you `38D9FF`,
route friend `FF8A3D`, meeting `FBBF24`. Type is Apple's text styles in sentence case
(`Theme/TextRoles.swift`), not monospaced upper-case lettering.

**Direction.** Photoreal pitched terrain edge to edge, every control a floating glass
layer, SF Pro for titles and large numbers, one red primary action per screen. The app
is one screen (`13-APP-MAP.md`: no tab bar, the map with a bottom row, one context
sheet, a profile panel and sheets).

## 1. Global rules

**Keep.** Dark tonal stack; monospaced uppercase chrome; section headers with a
trailing rule; the three tabs MAP · POWDERMEET · PROFILE with icon plus label; pill
badges (EPIC cyan, IKON amber, difficulty); red accent presets with the full theme
list; ski-topsheet banners as the identity element on Profile; cards at one radius (22 pt,
glass or opaque with a 1 px border; see "Liquid Glass"); all-caps
system messages.

**Improve.**
- **Liquid Glass chrome (iOS 26).** Tab bar, headers, floating map controls and sheets
  use the system glass material through standard SwiftUI (`TabView`, toolbars,
  `glassEffect`), so the app looks native on iOS 26 and gets the system's reduce-
  transparency and contrast behavior for free. Cards over the map are glass too, tinted
  with the theme's card colour for legibility against satellite imagery (see "Liquid
  Glass"). Glass is the floating layer, never the content under it.
- **Honest labels everywhere.** A status freshness badge (LIVE · n MIN, STALE, HOURS
  ONLY) on every screen that routes; friend chips carry a last-seen age; every ETA
  shows ± uncertainty; nothing the app does not know is shown as if it did.
- **One-thumb layout.** The primary action of every flow sits in the bottom third
  with a 56–60 pt height; destructive actions never sit next to primary ones.
- **Glove targets.** 44 pt minimum everywhere, 56 pt in the meet and navigation flows;
  chips 44 pt tall.
- **Glare theme.** The existing WHITEOUT preset becomes a one-tap toggle in the
  navigation HUD and map header, with opaque cards and darker trail colors.
- **Speed as a design goal.** Map updates use feature-state, so a status change
  repaints in under 100 ms with no geometry rebuild; cold launch to a rendered
  cached map in under 2 s; tab switches are instant because hidden tabs do no work.
- **Audio first during navigation.** Voice prompts and a short earcon for maneuvers
  and meet events; the screen can stay locked.

**New.** Account deletion; notification preferences; Sign in with Apple next to email; a
request-a-resort entry; a bug-report export; a "your pace" explanation.

## 2. Map

**Keep.** Red "MAP" header; the maneuver row (direction icon, DOWN · trail → next,
distance, difficulty); the active-meet row with the meeting node, both ETAs in route
colors and an END control; "YOUR PROGRESS" bar; the pitched satellite map with scale
bar, compass, friend markers, your position, gold meeting marker, lifts in gold dashes,
trails in difficulty colors; the trail info card with difficulty dot, OPEN state,
name, LENGTH · VERT · GRADE and the GRM / MOG / GLD condition indicators; the weather
strip (temperature, snowfall rate, wind, cloud, visibility); the 24-hour timeline
scrubber with date labels; the resort bar with run and lift counts; the tab bar.
(The resort bar is the header bar, centred, with the quick weather
in it and without the counts, and the scrubber is always on screen above the tab bar:
see "Liquid Glass", "How the Map tab applies it".)

**Improve.**
- Status badge in the header (LIVE · 12 MIN / STALE / HOURS ONLY) replacing nothing;
  the OPEN state on the trail card comes from the same status the solver uses, with
  PARTIAL shown when some member segments are closed (invariant I-15).
- Friend markers become chips with initials, name and last-seen age; tapping a chip
  opens the meet flow with that friend preselected.
- The maneuver row grows during an active meet (bigger glyph, next action, time to
  it), and collapses when idle.
- Timeline scrubber hours are named under it three apart in resort time (−3h, Now,
  +3h …); scrubbing updates sun, weather and lift hours, never status.
- The weather strip uses the server-cached conditions, so both phones see the same
  numbers; a stale-conditions age appears when older than 90 minutes.
- Map controls (compass, recenter, glare, layers) are glass buttons at 44 pt on the
  right edge within thumb reach.

**New.** The map offers no request-a-resort or "coming soon" entry; unpublished
resorts are not selectable at all.

## 3. PowderMeet tab

**Keep.** "POWDERMEET" header; the NAVIGATION · REQUESTS segmented control; the
"MEETING OPTIONS" section with paged cards; TOP MATCH star with total time; node name
and difficulty; elevation; the balance line ("BALANCED · ~32m WAIT EACH"); your route
and the friend's route as leg lists with per-leg times and difficulty dots; page dots;
SHOW ROUTE ON MAP; the collapsible FRIENDS HERE list with avatar, current trail,
ability and selection check; the big accent POWDERMEET action.

**Improve.**
- Each option card shows both ETAs with ± uncertainty, who waits and for how long, the
  hardest terrain for each skier, lift count per skier, and one typed reason line
  (INDOOR · LESS WAIT FOR BOTH; FASTEST FOR YOU · BLACK FOR ALEX).
- Replace "MAY USE CLOSED TERRAIN" with explicit semantics: a route never uses a
  known closure; under HOURS ONLY the card carries the degraded badge instead.
- Leg lists collapse to the first three legs with "+4 MORE"; the full list opens on
  tap. Cards stay under one screen height.
- The friend selector moves above the options as 44 pt chips with last-seen age, so
  the sequence reads friend → options → send.
- The primary action reads SEND TO ALEX · ROUNDHOUSE LODGE and is pinned at the
  bottom; SHOW ON MAP sits above it as a secondary control.
- REQUESTS becomes the incoming/outgoing list with countdowns and decline reasons.

**New.** Incoming proposal screen: the partner's own route and ETA computed on their
phone before they decide; Accept and Decline side by side as 56 pt
controls; "no route under current closures" declines automatically with the reason
shown to the proposer.

## 4. Navigation HUD

Built from the Map screen's maneuver and meet rows, promoted to a full HUD during an
active meet: large next-maneuver card (glyph, DOWN · trail, distance, then-lift and
wait); route-ahead map with the skied part dimmed; two ETA tiles (YOU, partner) with
± and progress bars, partner last-seen; three 56 pt controls (MUTE, GLARE, END MEET);
voice prompts indicator. Reroute shows a one-line banner with the reason and a new
ETA; a meet that ends because status blocks the route says so in words.

## 5. Profile

The profile is a top card and four large rows, each opening a full page with the system
back button (`ProfilePage`, the stack in `AppModel.panelPath`):

- **Top** (separate glass pieces, no shared card; `13-APP-MAP.md`): the picture
  (photo or initials), the name, the level
  with its limit (ADVANCED · UP TO BLACK), the ski pair carrying resort and position,
  and the four stats in one row (distance, vertical, average speed, top speed).
- **Friends** ("2 FRIENDS · 1 REQUEST"): the friends content as before: POWDER
  MEETERS, the "we don't store contacts" rescan card, suggestions, requests, sent,
  your friends with ability, blocked users. A friend notification opens it.
- **Activity** ("42 RUNS · 7 DAYS"): VIEW LOGS, LIVE RECORDING, the upload in
  progress, IMPORT ACTIVITY FILE, Apple Health; YOUR PACE (calibration, and that
  friends see only the summary); DATA (reset). One row per physical descent in the
  log with MATCHED / UNMATCHED; re-importing never duplicates.
- **Gear** (the ski and its limit): SKIS (the drawing, the ski picker, type,
  length, waist) and HOW YOU SKI (skill level, hardest run, steepest
  pitch, never-route-me-on, height and weight, learned pace). Labels and values only
  (`13-APP-MAP.md` section 3), in separate groups: Skis, How you ski (level, hardest
  run, steepest pitch, avoid), Body (height, weight) and Pace (learned). What each
  setting changes in routing is in `06-SOLVER.md` section 2: the level sets pace
  only; hardest run, pitch and avoid are hard gates; length works with height;
  weight helps across flats.
- **Settings** (theme, account kind): separate tiles, each opening a page with its
  value under it (`13-APP-MAP.md` section 3 is the contract for the pages):
  - ACCOUNT: the email, or "Apple ID, hidden email"; RESET PASSWORD (email accounts:
    the link goes to the account's address); SIGN OUT; DELETE ACCOUNT with a
    confirmation that says what is deleted (App Store requirement). After a delete the
    theme, icon and units go back to the defaults.
  - APPEARANCE: theme, map style (Satellite, Whiteout, Blueprint, PowderMeet, and what the
    runs' colours say: difficulty, steepness, facing, my runs;
    `13-APP-MAP.md` section 3), app icon, units (device, metric or
    imperial; skis stay in cm and mm). There is no skin choice: a
    catalog ski shows its own topsheet, custom gear the PowderMeet ski; "match theme"
    sits beside the preview in the ski picker.
  - NOTIFICATIONS: one switch per kind for all eight kinds of `11-SETUP-RELEASE.md`
    section 5 (stored per account, `notification_prefs`), and the "sounds and voice"
    switch. PERMISSIONS: whether iOS allows notifications (TURN ON / SETTINGS) and
    location (always, while using, off), each with a link to Settings.
  - MAPS: one line, "3 maps on this phone · 1.2 GB", and CHECK FOR UPDATES; then
    every resort with its download or remove control (`13-APP-MAP.md` section 3).
  - ABOUT AND SUPPORT: version and build; SEND A BUG REPORT (flight recorder
    export); privacy policy and support links.
  - DEV, in test builds only (Debug and TestFlight): the one home of every developer
    control (`07-CLIENT.md` section 8). There is no demo or live backend switch.

**Kept.** Avatar with camera affordance; name; the four stats; the
ski-topsheet banners; POWDER FRIENDS; the rescan card; suggested and your-friends
lists; contacts matching on device with hashes, and the copy saying so.

## 5a. Asking first

Anything that removes, deletes, blocks, ends or leaves asks with the app's own card
(`ConfirmCard`, `.confirmCard`): glass, in the middle of the screen over a dimmed
map, a title, one line saying what happens, the way out on the left and the action on
the right (red when it destroys something). Never the system alert or action sheet,
which opens wherever it likes (owner, 22 Nov). Sign out keeps the system alert.

## 6. Resort picker

**Keep.** A "Select resort" title (no Done); search; grouping by region with tracked
section headers; rows with name, region · country and a pass pill (EPIC / IKON).

**Built.** A floating picker (`13-APP-MAP.md` section 3a) the list scrolls in. At the
top, on its own, how many mountains there are ("154 mountains"); only mountains with a
map are listed, since one without cannot be opened (owner, 22 Nov). Sections: last
used, nearest, then by country. Every row has one height and one layout: on the left
the name and under it a row of tags, always in this order: the country's flag, the
state or province, how far away it is (whenever this phone's place is known), and how
lift status is known (an hourglass for scheduled hours, a signal for live); on the
right a block of one fixed width with the passes and the map mark on top and under
them a pill with an update mark saying when the map was last published: "↻ Today", "Yesterday",
"This week", then its date ("↻ 22 Nov", with the year once it is from an earlier one);
VoiceOver says "map updated this week" (`ResortDirectory.freshness`). Rows are
glass cards; the selected one has the accent ring. The last row, under the list
(and under "No mountains found"), is "Request a resort": it opens the support page,
the same one as About → Support, to ask for a resort that is not listed. The foot holds the search field,
the current resort and the close button; while searching, the count of matches. Beside
the search field a sort button reorders the list by country (as above), nearest,
name or pass (`13-APP-MAP.md` section 3a).

**Still open.** A FRIENDS HERE tag per row; the request row recording demand in the app
itself rather than on the support page.

## 7. Onboarding and auth

**Keep.** The mountain mark, wordmark and contour texture; the continuous launch →
auth → onboarding visual system; the step-by-step profile setup.

**Improve.** Email (Log in / Sign up, confirmation, reset) and Sign in with Apple; six
steps (name, photo, gear and limits, location, notifications, contacts), the photo
optional and chosen, cropped and uploaded as Account's is; location asked
when-in-use first and always only when a meet starts; notifications asked before
contacts, with the kinds explained; no resort step, since the map opens on the last or
nearest resort (`13-APP-MAP.md` section 0).

## 8. Acceptance for the design

A screen is accepted when: every element listed under Keep is present; every Improve item is visible on its screen; Profile → Settings has every page
of `13-APP-MAP.md` section 3; all primary actions are in the bottom third at 56 pt or more;
status that is not live is said wherever a route or a resort's status is shown (the
resort bar's dot, a "Status unknown" note on the meet and Go-to cards); the glare
theme renders every screen with 4.5:1 text contrast; nothing uses emoji or stock
gradient washes; bars, chips and cards use the system glass material.

## Themes

The in-app theme and the Home Screen icon are separate choices: Profile → Settings →
Appearance has Theme, Map, Icon and Units as four tiles, each opening a floating
list (`FloatingPickers`, `13-APP-MAP.md` section 3a). The App Icon list has
12 icons, grouped: PowderMeet; Powder, Carbon and Whiteout; Retro Flame and Retro Ice; then the Auroras: Night, Dawn, Ember, Glow (painted by `apps/ios/Tools/make_app_icons.py` from the mark), Ice and Rose;
`AppIcon` in `Theme/AppIcon.swift`; the list stays open after a pick, like Theme). The Theme list is a search
field and one flat list of rows, each a swatch (`ThemeSwatch`) and a name: Create your
own, the user's own themes, PowderMeet (Classic), then every other palette
alphabetically. There are no family tabs and no preview cards: a theme applies when
tapped, so the screen is the preview.

**Roles.** A theme (`AppTheme`, `Theme/AppTheme.swift`) is a set of semantic roles:
background, header, input, card, border; four text tiers; accent; success, warning,
danger, info; route-you and route-friend. `HUDTheme` reads the selected theme, so views
keep using `HUDTheme.accent`, `.cardBackground`, `.textSecondary` and the rest
(`accentGreen/Amber/Red/Cyan` are the status roles). Trail difficulty colours, lift
gold and the meeting gold are not roles and never change. The selection is saved as
the theme's seed colours (`powdermeet.theme.selection`) and applies live.

**Classic** is the default: PowderMeet red on near-black. Layout, type and the matte-black character are the same in every theme. Glass
surfaces take the theme through their tint (see "Liquid Glass").

**Themes** (1,083), in list order:

| Source | Themes |
|---|---|
| PowderMeet | Classic only. |
| MacSpaces' own palettes | Noir, Midnight, Rose, Coral, Iris, Cocoa, Graphite, Moss, Cherry, Ember Glow, Lagoon, Mulberry, Ink |
| Editor favourites (MacSpaces' values) | Catppuccin, Tokyo Night, Rosé Pine, Nord, Solarized, Everforest, Gruvbox, Monokai, Ayu |
| Ghostty (iTerm2-Color-Schemes, MIT) | 650 |
| Base16 (Tinted Theming, MIT) | 154 |
| Gogh (MIT) | 256 |
| The user's own | accent, background and cards |

The Ghostty, Base16 and Gogh data are MacSpaces' two JSON files, copied unchanged into
`PowderMeet/Resources/Themes/` with the licence notices in `ACKNOWLEDGEMENTS.txt`
beside them. Refresh by copying the files again.

**Filling the roles from a palette** (`AppTheme(seed:)`). A palette gives a background,
a foreground, an accent and, for terminal palettes, sixteen ANSI colours. Surfaces are
Classic's ladder on the palette's background (or the palette's own card colour where
it names one). Primary text is the foreground, lightened if needed to 7:1 on the card;
the other tiers are mixed toward the card to Classic's ratios (4.6, 3.2, 2.0). Status
colours come from the ANSI green, yellow, red and cyan when those still have the right
hue and read at 4.5:1; otherwise Classic's are used. Route colours are Classic's in
every bundled theme, because they must match the map.

**Contrast rules, enforced in the derivation.** Light palettes are left out: the HUD is
a dark design and draws white labels on filled buttons. A palette is dropped when its
cards are too bright for an accent to read on them at 3:1 while white reads on the
accent at 3:1. An accent paler than that is deepened along its own hue (so Noir's
near-white accent is a mid grey here). `apps/ios/Tools/ThemeContrastCheck` compiles the same
model and checks every bundled theme on every surface; all 1,083 pass.

**The map's ground doesn't follow the theme.** Settings → Appearance → Map picks how
the ground is drawn: Satellite is the default; PowderMeet (once Holographic) draws its relief, contours
and tree dots in PowderMeet red in every theme; Whiteout, Blueprint and Satellite also
have fixed ground colours (`MapLook`, `MapStyle.applyLook`). Trails, lifts,
routes and markers keep their colours and meanings in every look, with two
exceptions for legibility on Whiteout's white ground: black runs draw near-black
(white on the dark looks), and the difficulty and lift colours are deepened along
their own hues (green `22B864`, blue `3B8CFF`, double black `FF4D6A`, park
`F26B12`, lifts `B8860B`), with dark labels on light halos. On Whiteout runs are also
drawn wider and nearly opaque with a dark edge; every drawn look scatters its
tree dots sparsely (four 1.8 pt dots in a 24 pt tile).

**Not done.** Light themes (including a glare theme) need the on-accent text role
(`HUDTheme.onAccent`, used by most components, but a constant white rather than a themed
value) and the removal of the forced dark colour scheme. A few white labels on accent
fills are still written as `.white` at the call sites.

## Liquid Glass (one screen)

One design language across the app, native glass, native type,
the theme's colours as tint and accent. The whole app is the map screen of
`13-APP-MAP.md`; this section is how it looks. The tokens are in
`Theme/LiquidGlass.swift` (`GlassLayout`, `HUDGlass`, `glassCard()`,
`glassCardControl()`, `glassBar()`, `glassChip()`, `glassCircleControl()`,
`glassField()`, the `isOnGlass` environment value), `Theme/TextRoles.swift` (the type)
and `Theme/SheetChrome.swift` (sheets and pages); the shared pieces in
`Views/Components` (`GlassSection`, `SectionHeader`, the rows, `Buttons.swift`,
`StatusChip`, `EmptyStateView`, and `PreMapBackdrop`, the red and black liquid
behind sign-in and onboarding). Use them; do not invent a radius,
a padding, a header, a font or a tint per screen.

**Type.** Apple's text styles (SF Pro, Dynamic Type) through one scale, `TextRole`:
display (title 2, bold), title (title 3, semibold), section (subheadline, semibold),
body, bodyEmph (body, semibold), label (footnote), caption, metric (headline, monospaced
digits). Sentence or title case ("Whistler Blackcomb", "Meet up", "Settings"); units in
lower case ("2.9 mi", "5 in"); standard weights; no monospaced lettering and no custom
tracking. `.monospacedDigit()` only where numbers tick (times, distances, ETAs). Map
labels drawn by the map style stay as they are. Two text tiers on glass: primary for
names and values, secondary for details, labels and units.

**One tint.** Every surface is the system's glass tinted from one place, `HUDGlass`:
the theme's card colour at `HUDGlass.strength` (0.62) for cards, bars, chips, rows and
controls (`surface`, `control`); a step denser for text fields (`field`); the theme's
background at a lighter strength for a sheet's backdrop (`backdrop`); an accent wash
under a 2 pt accent ring for a selected chip, row or button (`selectedSurface`). Change
the theme and every surface follows; raise `strength` and every surface gets denser at
once, which is the one knob for legibility (checked in Classic and Tokyo Night). There
is no opaque tier: lists (resorts, skis, logs, import reports, run details) are glass
cards too. Only the system's glass is used (`glassEffect`, inside a
`GlassEffectContainer` where shapes sit together); no hand-drawn blur.

**No glass on glass inside a card.** Inside a card (`isOnGlass`), a control's box is a
borderless well (`HUDGlass.well`), a secondary button is a well capsule, rules are
hairlines (`HUDGlass.hairline`). Cards and rows themselves may sit on a sheet's glass
backdrop.

**Shapes.** Card: 22 pt continuous corners, 16 pt padding. Bar: a 52 pt capsule. Row:
56 pt at least, 16 pt from the card's edges. Chip: a 44 pt capsule, its own glove
target, one height everywhere (the off-screen friend chips too). Round buttons: 44 pt
(icon) and 52 pt (the profile button beside the bar). A box inside a card
has 12 pt corners.

**Spacing.** Floating elements: 12 pt from the screen edge, 8 pt between them. Pages:
16 pt side margins, 24 pt between sections, 8 pt from a header to its card.

**Accent.** The one primary action (a filled capsule, white label), selection rings,
the glyph at the head of a row, badges, small marks. Status colours (success, warning,
danger, info), difficulty colours and route colours appear as text, glyphs, dots and
status chips, with their meanings unchanged. Body text is never accent-coloured.

**Sheets and pages.** One rule (`13-APP-MAP.md` section 3a): a sheet from the map has
the system grabber, a small centred title, the glass backdrop and no Done (swipe down or
VoiceOver escape closes it); what it opens is pushed with the system back button;
search is the system's, at the bottom.

**The status bar.** Where bright map runs under the status bar, a short black gradient
(45% to clear, 110 pt) sits behind it: the only drawn overlay. On Whiteout the
glyphs turn dark (`StatusBarDarkener`) and the fade is white (60% to clear); glass, its
text and the Mapbox logo stay as they are.

**Reduce transparency, increase contrast, reduce motion.** Left to the system: its glass
turns opaque and gains an outline. Cards appear and leave with a 0.2 s fade.

**Still open.** Light themes (including a glare theme) need the on-accent role to be a
themed value and the removal of the forced dark colour scheme.
