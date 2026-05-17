#!/bin/bash
# Deploy build-resort-graph (real implementation) to Supabase.
#
# Prereq: SUPABASE_ACCESS_TOKEN env var set (get from
#   https://supabase.com/dashboard/account/tokens, or run `supabase login`).

set -euo pipefail

# Move to repo root regardless of where the script was invoked from
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR/.."

# Stage shared files alongside index.ts so Deno can resolve relative imports
rm -rf supabase/functions/build-resort-graph/_shared 2>/dev/null || true
mkdir -p supabase/functions/build-resort-graph/_shared
cp supabase/functions/_shared/*.ts supabase/functions/build-resort-graph/_shared/

# Update imports in index.ts to point at the colocated _shared dir
sed -i.bak 's|"./graph_builder.ts"|"./_shared/graph_builder.ts"|g' supabase/functions/build-resort-graph/index.ts
sed -i.bak 's|"./curated_overlay.ts"|"./_shared/curated_overlay.ts"|g' supabase/functions/build-resort-graph/index.ts
sed -i.bak 's|"./graph_types.ts"|"./_shared/graph_types.ts"|g' supabase/functions/build-resort-graph/index.ts
rm supabase/functions/build-resort-graph/index.ts.bak

if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "ERROR: SUPABASE_ACCESS_TOKEN not set. Get one at:"
  echo "  https://supabase.com/dashboard/account/tokens"
  echo "Then: export SUPABASE_ACCESS_TOKEN=sbp_..."
  # Restore canonical layout before exiting
  sed -i.bak 's|"./_shared/graph_builder.ts"|"./graph_builder.ts"|g' supabase/functions/build-resort-graph/index.ts
  sed -i.bak 's|"./_shared/curated_overlay.ts"|"./curated_overlay.ts"|g' supabase/functions/build-resort-graph/index.ts
  sed -i.bak 's|"./_shared/graph_types.ts"|"./graph_types.ts"|g' supabase/functions/build-resort-graph/index.ts
  rm supabase/functions/build-resort-graph/index.ts.bak
  rm -rf supabase/functions/build-resort-graph/_shared
  exit 1
fi

supabase functions deploy build-resort-graph --project-ref qtzjxquzyrwavhvqarvg

# Restore canonical layout
sed -i.bak 's|"./_shared/graph_builder.ts"|"./graph_builder.ts"|g' supabase/functions/build-resort-graph/index.ts
sed -i.bak 's|"./_shared/curated_overlay.ts"|"./curated_overlay.ts"|g' supabase/functions/build-resort-graph/index.ts
sed -i.bak 's|"./_shared/graph_types.ts"|"./graph_types.ts"|g' supabase/functions/build-resort-graph/index.ts
rm supabase/functions/build-resort-graph/index.ts.bak
rm -rf supabase/functions/build-resort-graph/_shared

echo ""
echo "Done. Test with:"
echo "  curl -X POST https://qtzjxquzyrwavhvqarvg.supabase.co/functions/v1/build-resort-graph \\"
echo "    -H 'Authorization: Bearer <anon key>' -H 'Content-Type: application/json' \\"
echo "    -d '{\"resort_id\": \"vail\"}'"
