# `snapshot-resort` (Edge Function)

Prod flow: Overpass fetch → cache OSM + elevation in Supabase Storage → return signed URLs so every client builds the **same** graph.

## Contract

`POST /functions/v1/snapshot-resort`

**Request**
```json
{ "resort_id": "whistler", "south": 50.05, "west": -123.05, "north": 50.13, "east": -122.94 }
```

**Response**
```json
{
  "snapshot_date": "2026-04-25",
  "osm_url": "https://...signed...",
  "elevation_url": "https://...signed...",
  "cached": true
}
```

`osm_url` returns the raw Overpass JSON (`{ elements: [...] }`).
`elevation_url` returns `{ "lat,lon": elevationMeters }` keyed by `%.6f,%.6f`.

## One-time setup

1. **Storage bucket.** Create a *private* bucket named `resort-snapshots`:
   ```sql
   insert into storage.buckets (id, name, public) values ('resort-snapshots', 'resort-snapshots', false);
   ```

2. **Deploy.**
   ```bash
   supabase functions deploy snapshot-resort
   ```
   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by Supabase.

## Behaviour

- **Cache hit:** snapshot < 24h old in Storage → returns signed URLs to the existing blobs (`cached: true`).
- **Cache miss:** fetches Overpass `piste:type` + `aerialway` for the bbox, batches unique coordinates through Open-Meteo's elevation API (100 per request), uploads both as JSON to `resort-snapshots/{resort_id}/{osm,elev}-{YYYY-MM-DD}.json`, returns fresh signed URLs (`cached: false`).
- Signed URLs are valid for 1 hour — long enough for slow networks (chairlift) to download both blobs.

Until deployed, the app falls back to direct Overpass per device (graphs may differ subtly between devices because of Overpass result ordering and DEM rounding).

