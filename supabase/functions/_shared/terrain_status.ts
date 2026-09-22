import { epicTerrainURL, fetchEpicTerrainStatus } from "./live_status.ts";
import {
  fetchMtnPowderFeed,
  MTNPOWDER_TERRAIN_NAMES,
  parseMtnPowderStatus,
} from "./mtnpowder_status.ts";

// One shared feed download per refresh invocation, with no cross-invocation
// cache that could silently renew stale observations.
export function createTerrainStatusFetcher(fetcher: typeof fetch = fetch) {
  let mtnPowderFeed: Promise<unknown> | undefined;
  return async (resortID: string, now = new Date()) => {
    if (epicTerrainURL(resortID)) {
      return await fetchEpicTerrainStatus(resortID, fetcher, now);
    }
    if (!MTNPOWDER_TERRAIN_NAMES[resortID]) {
      throw new Error(`No terrain source for ${resortID}`);
    }
    mtnPowderFeed ??= fetchMtnPowderFeed(fetcher);
    return parseMtnPowderStatus(await mtnPowderFeed, resortID, now);
  };
}
