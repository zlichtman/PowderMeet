#!/bin/bash
# Deploy build-resort-graph (real implementation) to Supabase.
#
# Prereq: SUPABASE_ACCESS_TOKEN env var set (get from
#   https://supabase.com/dashboard/account/tokens, or run `supabase login`).

set -euo pipefail

# Move to repo root regardless of where the script was invoked from
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN not set. Get one at:"
  echo "  https://supabase.com/dashboard/account/tokens"
  echo "Then: export SUPABASE_ACCESS_TOKEN=sbp_..."
  exit 1
fi

supabase functions deploy build-resort-graph --project-ref qtzjxquzyrwavhvqarvg --use-api

echo ""
echo "Done. Test with:"
echo "  curl -X POST https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/build-resort-graph \\"
echo "    -H 'Authorization: Bearer <anon key>' -H 'Content-Type: application/json' \\"
echo "    -d '{\"resort_id\": \"vail\"}'"
