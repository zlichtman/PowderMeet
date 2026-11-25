#!/bin/zsh
# Website capture stages; re-run whenever the app changes
# (docs/DEMO-STORYBOARD.md). Debug build on a booted simulator; the app runs
# on its own preview stage (no account), Whistler Blackcomb, Satellite, the
# PowderMeet theme unless a stage says otherwise. Personal photos and the logs
# to import come in as environment variables, never from this file.
#
#   apps/ios/Tools/demo-shots.sh <stage> [<stage> ...]
#   stages: hero hero-whiteout options options-map options-video
#           profile profile-looks resorts all
#
# options-video records while someone swipes the options card left, one
# option every 1.5 to 2 s (simctl has no touch input): with the simulator
# tool, or by hand in Simulator. Everything else runs unattended.
#
# Environment:
#   PM_SIM           simulator UDID (default: the booted one)
#   PM_APP           the built PowderMeet.app (default: the newest Debug simulator build
#                    under ~/Library/Caches/PowderMeet)
#   PM_OUT           output folder (default: ./demo-out)
#   PM_PHOTO         PowderBoy's photo        PM_FRIEND_PHOTO  GlacierGlider's photo
#   PM_LOGS          folder of activity files, or paths separated by "|" (profile stages);
#                    copy them out of iCloud Drive first, or they fail to import
#   PM_VIDEO_SECONDS how long options-video records (default 35)
#   PM_PYTHON        a python with Pillow (default: uv run --with pillow python)
set -euo pipefail

TOOLS=${0:A:h}
SIM=${PM_SIM:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}
APP=${PM_APP:-$(ls -td ~/Library/Caches/PowderMeet/*/Build/Products/Debug-iphonesimulator/PowderMeet.app 2>/dev/null | head -1)}
OUT=${PM_OUT:-$PWD/demo-out}
mkdir -p "$OUT"
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

python_pillow() {
  if [[ -n ${PM_PYTHON:-} ]]; then "$PM_PYTHON" "$@"; else uv run -q --no-project --with pillow python -I "$@"; fi
}

# Website status bar: 9:41, full Wi-Fi, cellular and battery.
status_bar() {
  xcrun simctl status_bar "$SIM" override --time 9:41 \
    --dataNetwork wifi --wifiMode active --wifiBars 3 --cellularMode active --cellularBars 4 \
    --batteryState discharging --batteryLevel 100
}

# The app on the stage, with this shot's own arguments after the common ones.
# THEME, LOOK and SUN are set per stage (each launch argument once: the app
# reads only the first of a repeated one).
launch() {
  xcrun simctl terminate "$SIM" "$BID" 2>/dev/null || true
  xcrun simctl install "$SIM" "$APP"
  local cast=(-demoName "PowderBoy" -demoLevel expert -demoFriendName "GlacierGlider")
  [[ -n ${PM_PHOTO:-} ]] && cast+=(-demoPhoto "$PM_PHOTO")
  [[ -n ${PM_FRIEND_PHOTO:-} ]] && cast+=(-demoFriendPhoto "$PM_FRIEND_PHOTO")
  xcrun simctl launch --terminate-running-process "$SIM" "$BID" \
    -previewData YES -previewResort whistler-blackcomb -debugMapLook "$LOOK" -debugTheme "$THEME" \
    -previewWeather script -previewSunHour "$SUN" -previewLiftsOpen YES \
    -previewPlaceName "Raven's=Cross Roads" -demoCapture YES -demoCameraBearing 150 "${cast[@]}" "$@" >/dev/null
}

# A still: the status bar set, the screen with its mask (rounded corners and
# the Dynamic Island), with transparent corners and no drawn battery number.
still() {
  local name=$1 wait=$2
  sleep "$wait"
  status_bar
  sleep 1
  local raw="$OUT/.$name-raw.png"
  xcrun simctl io "$SIM" screenshot --mask=black "$raw" >/dev/null 2>&1
  # Transparent outside the rounded screen; the Dynamic Island stays black.
  python_pillow "$TOOLS/round_corners.py" "$raw" "$OUT/$name.png" >/dev/null
  rm -f "$raw"
  echo "$OUT/$name.png"
}

# The video: recorded while the options are swiped, then trimmed to the
# first and last movement (ffmpeg's freezedetect), H.264, no sound.
video() {
  local name=$1 seconds=${PM_VIDEO_SECONDS:-35}
  local raw="$OUT/.$name-raw.mp4" log="$OUT/.$name-freeze.log"
  rm -f "$raw"
  xcrun simctl io "$SIM" recordVideo --codec h264 --mask black --force "$raw" 2>"$OUT/.$name-rec.log" &
  local recorder=$!
  until grep -q "Recording started" "$OUT/.$name-rec.log" 2>/dev/null; do sleep 0.2; done
  echo "recording: swipe the options card left now, one option every 1.5-2 s" >&2
  sleep "$seconds"
  kill -INT $recorder
  wait $recorder || true
  ffmpeg -hide_banner -nostats -i "$raw" -vf "freezedetect=n=0.003:d=0.6" -map 0:v -f null - 2>"$log" || true
  local total first last
  total=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$raw")
  # Still at the start: from shortly before its end. Still at the end: until a
  # second into it.
  first=$(awk -F': ' '/freeze_start: 0(\.0*)?$/ {s=1} s && /freeze_end/ {print $2; exit}' "$log")
  last=$(awk -F': ' '/freeze_start/ {v=$2} END {print v}' "$log")
  [[ -z $first ]] && first=0.5
  [[ -z $last || $(echo "$last <= $first" | bc) == 1 ]] && last=$total
  local from to
  from=$(echo "if ($first > 0.5) $first - 0.5 else 0" | bc)
  to=$(echo "if ($last + 1.2 < $total) $last + 1.2 else $total" | bc)
  ffmpeg -hide_banner -loglevel error -y -ss "$from" -to "$to" -i "$raw" -an \
    -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -movflags +faststart "$OUT/$name.mp4"
  rm -f "$raw" "$log" "$OUT/.$name-rec.log"
  echo "$OUT/$name.mp4 ($from s to $to s of $total s)"
}

imports() {
  [[ -n ${PM_LOGS:-} ]] || { echo "PM_LOGS is not set" >&2; exit 1; }
  if [[ -d $PM_LOGS ]]; then
    local files=("$PM_LOGS"/*.slopes(N))
    (( ${#files} )) || { echo "No Slopes files in PM_LOGS" >&2; exit 1; }
    echo "${(j:|:)files}"
  else
    echo "$PM_LOGS"
  fi
}

# The meet: PowderBoy on Pika's Traverse (his card says so), GlacierGlider at the
# top of Garbanzo, meeting at Cross Roads.
hero_places=(-placeMe "coordinate:50.05626154659759,-122.94213761496634"
  -placeFriend "Garbanzo Express top")
meet_places=(-placeMe "Peak Express top" -placeFriend "Glacier Express top")
# The profile: PowderBoy on a run (the card says which), GlacierGlider a friend on
# the mountain, the camera on Blackcomb.
profile_args=(-meetState friend -placeMe "run:Pika's Traverse" -placeFriend "Glacier Creek"
  -lookAt "Jersey Cream Express top" -stage panel -profilePanel YES)

stages=("$@")
[[ ${stages[1]:-} == all ]] && stages=(hero hero-whiteout options options-map options-video profile profile-looks resorts)

for shot in "${stages[@]}"; do
  THEME=PowderMeet LOOK=satellite SUN=12.5
  case $shot in
    hero|hero-whiteout)
      # A meet under way, with the current instruction and run card open.
      [[ $shot == hero-whiteout ]] && LOOK=whiteout
      launch -meetState active "${hero_places[@]}" -meetAt "Cross Roads" -stage "run:Pika's Traverse"
      [[ $shot == hero ]] && still 01-hero 60 || still 01b-hero-whiteout 60 ;;
    options)
      launch -meetState options "${meet_places[@]}"
      still 02-options 50 ;;
    options-map)
      launch -meetState sent "${meet_places[@]}" -meetAt "Cross Roads"
      still 02b-options-map 55 ;;
    options-video)
      launch -meetState options "${meet_places[@]}"
      still 02v-options-poster 50
      video 02v-options ;;
    profile)
      # The darker look: the mountain at dusk.
      SUN=17.6
      launch "${profile_args[@]}" -debugImport "$(imports)" -debugImportDelay 1
      still 04-profile 200 ;;
    profile-looks)
      for variant in "PowderMeet whiteout" "PowderMeet holographic" "Tokyo Night satellite"; do
        THEME=${variant% *} LOOK=${variant##* } SUN=12.5
        [[ $LOOK == satellite ]] && SUN=17.6
        launch "${profile_args[@]}" -debugImport "$(imports)" -debugImportDelay 1
        still "04b-profile-${${THEME// /}:l}-$LOOK" 200
      done ;;
    resorts)
      launch -openSheet resorts
      still 05-resort-picker 40 ;;
    *)
      echo "unknown stage: $shot" >&2; exit 1 ;;
  esac
done
