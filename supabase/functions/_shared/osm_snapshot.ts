// Pure snapshot parsing: no network, storage writes, or Edge Function startup.
import type {
  ResortData,
  ResortDataConnection,
  ResortDataCoordinate,
  ResortDataLift,
  ResortDataTrail,
} from "./graph_builder.ts";

interface OverpassElement {
  type: "way" | "node" | "relation";
  id: number;
  lat?: number;
  lon?: number;
  nodes?: number[];
  tags?: Record<string, string>;
}
interface OverpassResponse {
  elements: OverpassElement[];
}

export class MountainSourceError extends Error {}

export function osmToResortData(
  osm: unknown,
  elevations: Record<string, number>,
): ResortData {
  const data = osm as OverpassResponse;
  if (!data || !Array.isArray(data.elements)) {
    throw new MountainSourceError(
      "Mountain snapshot must contain OSM elements",
    );
  }
  const nodeMap = new Map<number, ResortDataCoordinate>();
  let south = 90, west = 180, north = -90, east = -180;
  for (const el of data.elements) {
    if (
      el.type === "node" && el.lat != null && el.lon != null &&
      Number.isFinite(el.lat) && Number.isFinite(el.lon) &&
      Math.abs(el.lat) <= 90 && Math.abs(el.lon) <= 180
    ) {
      const key = `${el.lat.toFixed(6)},${el.lon.toFixed(6)}`;
      const ele = elevations[key];
      nodeMap.set(el.id, {
        lat: el.lat,
        lon: el.lon,
        ele: ele ?? null,
        sourceNodeID: String(el.id),
      });
      if (el.lat < south) south = el.lat;
      if (el.lat > north) north = el.lat;
      if (el.lon < west) west = el.lon;
      if (el.lon > east) east = el.lon;
    }
  }

  const trails: ResortDataTrail[] = [];
  const lifts: ResortDataLift[] = [];
  const connections: ResortDataConnection[] = [];

  for (const el of data.elements) {
    if (el.type !== "way" || !el.tags) continue;
    const tags = el.tags;
    // area=yes describes a piste footprint, not a route around its perimeter.
    // Keep outlines in the raw snapshot; only centerlines enter the ski graph.
    if (tags["area"] === "yes") continue;
    // Ski-specific access overrides general access; private/no routes cannot
    // later be reopened by an operational-status feed.
    if (["private", "no"].includes(tags["ski"] ?? tags["access"])) continue;
    // Match the preview parser: pistes take precedence, and station buildings
    // and ziplines are not passenger lift routes. Ignore them before geometry
    // validation so an unrelated outline cannot invalidate the ski network.
    const isPiste = ["downhill", "connection"].includes(tags["piste:type"]);
    const isLift = tags["piste:type"] == null && tags["aerialway"] != null &&
      !["station", "zip_line"].includes(tags["aerialway"]);
    if (!isPiste && !isLift) continue;
    if (!Array.isArray(el.nodes) || el.nodes.length < 2) {
      throw new MountainSourceError(
        `Mountain data is incomplete: way ${el.id} needs at least two map points`,
      );
    }
    // Dropping a missing reference would invent a traversable straight segment.
    const coords = el.nodes.map((ref) => {
      const c = nodeMap.get(ref);
      if (!c) {
        throw new MountainSourceError(
          `Mountain data is incomplete: way ${el.id} references missing or invalid map point ${ref}`,
        );
      }
      return c;
    });

    if (isLift) {
      lifts.push({
        id: String(el.id),
        name: tags["name"] ?? null,
        type: mapAerialwayType(tags["aerialway"]),
        capacity: tags["aerialway:capacity"]
          ? parseInt(tags["aerialway:capacity"], 10)
          : null,
        coordinates: coords,
        isOpen: tags["opening_hours"] !== "closed",
        isBidirectional: tags["oneway"] === "no",
      });
    } else if (tags["piste:type"] === "downhill") {
      trails.push({
        id: String(el.id),
        name: tags["name"] ?? tags["piste:name"] ?? null,
        displayName: tags["piste:name"] ?? tags["name"] ?? null,
        difficulty: mapPisteDifficulty(tags["piste:difficulty"]),
        coordinates: coords,
        lengthMeters: polyLen(coords),
        grooming: tags["piste:grooming"] ?? null,
        isOpen: tags["piste:status"] !== "closed",
      });
    } else if (tags["piste:type"] === "connection") {
      connections.push({
        id: String(el.id),
        name: tags["name"] ?? tags["piste:name"] ?? null,
        coordinates: coords,
        isOpen: tags["piste:status"] !== "closed",
      });
    }
  }

  // Diagonal in meters
  const dlat = (north - south) * Math.PI / 180;
  const dlon = (east - west) * Math.PI / 180;
  const meanLat = (north + south) / 2 * Math.PI / 180;
  const dx = 6371000 * dlon * Math.cos(meanLat);
  const dy = 6371000 * dlat;
  const diagonalMeters = Math.sqrt(dx * dx + dy * dy);

  return { trails, lifts, connections, bounds: { diagonalMeters } };
}

function polyLen(coords: Array<{ lat: number; lon: number }>): number {
  let total = 0;
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1], b = coords[i];
    const dLat = (b.lat - a.lat) * Math.PI / 180;
    const dLon = (b.lon - a.lon) * Math.PI / 180;
    const lat1 = a.lat * Math.PI / 180;
    const lat2 = b.lat * Math.PI / 180;
    const h = Math.sin(dLat / 2) ** 2 +
      Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
    total += 2 * 6371000 * Math.asin(Math.sqrt(h));
  }
  return total;
}

function mapAerialwayType(raw: string): ResortDataLift["type"] {
  switch (raw.toLowerCase()) {
    case "gondola":
      return "gondola";
    case "chair_lift":
    case "chairlift":
      return "chair_lift";
    case "funicular":
      return "funicular";
    case "t-bar":
      return "t-bar";
    case "j-bar":
      return "j-bar";
    case "drag_lift":
      return "drag_lift";
    case "platter":
      return "platter";
    case "magic_carpet":
      return "magic_carpet";
    case "rope_tow":
      return "rope_tow";
    case "cable_car":
      return "cable_car";
    default:
      return "unknown";
  }
}

function mapPisteDifficulty(
  raw: string | undefined,
): ResortDataTrail["difficulty"] {
  if (!raw) return null;
  const s = raw.toLowerCase();
  if (s === "novice" || s === "easy") return "green";
  if (s === "intermediate") return "blue";
  if (s === "advanced") return "black";
  if (s === "expert" || s === "freeride" || s === "extreme") {
    return "doubleBlack";
  }
  return null;
}
