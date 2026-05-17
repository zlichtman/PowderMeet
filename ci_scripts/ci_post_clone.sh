#!/bin/sh
#
# Xcode Cloud post-clone hook.
#
# One job: authenticate Mapbox SDK downloads. The Mapbox Maps SPM package
# pulls binary XCFrameworks from api.mapbox.com which requires HTTP basic
# auth against a DOWNLOADS:READ-scoped token. Without ~/.netrc on the
# runner, SPM resolution dies with a 401 before xcodebuild runs.
#
# Required env var (set as a Shared Environment Variable on Xcode Cloud):
#   MAPBOX_DOWNLOADS_TOKEN   sk.… DOWNLOADS:READ token
#
# The other former env vars (MAPBOX_ACCESS_TOKEN / SUPABASE_URL /
# SUPABASE_ANON_KEY) are no longer consumed here — Secrets.xcconfig is
# committed to the repo so xcconfig substitution into Info.plist works
# identically on local builds and CI. Those values are public-facing
# (anon JWT + pk Mapbox token; both designed to ship in the IPA), so
# committing them costs nothing and removes a class of CI-only bugs
# around shell quoting / xcconfig escape sequences / PlistBuddy edge
# cases that bit Builds 12–16.

set -eu

if [ -z "${MAPBOX_DOWNLOADS_TOKEN:-}" ]; then
    echo "[ci_post_clone] ERROR: MAPBOX_DOWNLOADS_TOKEN env var is not set" >&2
    echo "[ci_post_clone] Set it as a Shared Environment Variable on Xcode Cloud." >&2
    exit 1
fi

echo "[ci_post_clone] writing ~/.netrc for api.mapbox.com (token length: ${#MAPBOX_DOWNLOADS_TOKEN})"
{
    printf 'machine api.mapbox.com\n'
    printf '  login mapbox\n'
    printf '  password %s\n' "$MAPBOX_DOWNLOADS_TOKEN"
} > "$HOME/.netrc"
chmod 600 "$HOME/.netrc"

echo "[ci_post_clone] done"
