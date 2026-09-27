import { MountainSourceError, osmToResortData } from "./osm_snapshot.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const kinds: Record<string, string>[] = [{ "piste:type": "downhill" }, {
  "piste:type": "connection",
}, { aerialway: "chair_lift" }];

Deno.test("station outlines and ziplines never become ski lifts", () => {
  for (const aerialway of ["station", "zip_line"]) {
    for (const nodes of [[1, 2, 3], [999]]) {
      const data = osmToResortData(fixture({ aerialway }, nodes), {});
      assert(data.lifts.length === 0 && data.trails.length === 0,
        `${aerialway} must not become a route`);
    }
  }
});
Deno.test("piste classification takes precedence over aerialway tags", () => {
  for (const type of ["downhill", "connection", "nordic"]) {
    const data = osmToResortData(fixture({ "piste:type": type, aerialway: "chair_lift" }), {});
    assert(data.lifts.length === 0, "mixed tags must not create a lift");
    assert(data.trails.length === (type === "downhill" ? 1 : 0), "downhill only");
    assert((data.connections ?? []).length === (type === "connection" ? 1 : 0), "connections retained");
  }
});
Deno.test("explicit source closures survive parsing for all route kinds", () => {
  for (const tags of kinds) {
    for (const closed of [true, false]) {
      const data = osmToResortData(fixture({ ...tags,
        "piste:status": closed ? "closed" : "open",
        opening_hours: closed ? "closed" : "24/7" }), {});
      const routes = [...data.trails, ...data.lifts, ...(data.connections ?? [])];
      assert(routes.length === 1 && routes[0].isOpen === !closed, "source closure retained");
    }
  }
});
function fixture(tags: Record<string, string>, nodes: number[] = [1, 2, 3]) {
  return {
    elements: [
      { type: "node", id: 1, lat: 40.002, lon: -106 },
      { type: "node", id: 2, lat: 40.001, lon: -106 },
      { type: "node", id: 3, lat: 40, lon: -106 },
      { type: "way", id: 10, tags, nodes },
    ],
  };
}
function rejects(source: unknown, detail: string) {
  let error: unknown;
  try {
    osmToResortData(source, {});
  } catch (caught) {
    error = caught;
  }
  assert(
    error instanceof MountainSourceError && error.message.includes(detail),
    `Expected typed source rejection: ${detail}`,
  );
}

Deno.test("snapshot refuses missing interior or endpoint nodes for every routing way kind", () => {
  for (const tags of kinds) {
    for (const nodes of [[1, 99, 3], [99, 2, 3], [1, 2, 99]]) {
      rejects(fixture(tags, nodes), "10");
    }
  }
});
Deno.test("snapshot refuses malformed or underspecified routing geometry", () => {
  for (const tags of kinds) {
    for (const nodes of [[], [1]]) rejects(fixture(tags, nodes), "10");
  }
  for (const lat of [91, NaN, Infinity]) {
    const source = fixture(kinds[0]);
    source.elements[1].lat = lat;
    rejects(source, "2");
  }
});
Deno.test("complete snapshot preserves every source point and ignores unrelated incomplete ways", () => {
  for (const tags of kinds) {
    const source = fixture(tags);
    source.elements.push({
      type: "way",
      id: 20,
      tags: { highway: "service" },
      nodes: [999],
    });
    const data = osmToResortData(source, { "40.001000,-106.000000": 1049 });
    const routes = [...data.trails, ...data.lifts, ...(data.connections ?? [])];
    assert(routes.length === 1, "one complete route retained");
    assert(
      routes[0].coordinates.map((c) => c.sourceNodeID).join(",") === "1,2,3",
      "source identity and ordering retained",
    );
    assert(routes[0].coordinates[1].ele === 1049, "elevation retained");
  }
});

Deno.test("piste footprints never become perimeter routes or invalidate centerlines", () => {
  for (const type of ["downhill", "connection"]) {
    for (const refs of [[1, 2, 3, 1], [999]]) {
      const data = osmToResortData(fixture({ "piste:type": type, area: "yes" }, refs), {});
      assert(data.trails.length === 0 && (data.connections ?? []).length === 0,
        "an area boundary is not a route, even if its outline references are incomplete");
    }
    const line = osmToResortData(fixture({ "piste:type": type, area: "no" }), {});
    assert(line.trails.length + (line.connections ?? []).length === 1, "centerline retained");
  }
});

Deno.test("private routes are excluded even when operating, with ski-specific access precedence", () => {
  for (const tags of kinds) {
    for (const access of ["private", "no"]) {
      const data = osmToResortData(fixture({ ...tags, access, "piste:status": "open" }), {});
      assert(data.trails.length + data.lifts.length + (data.connections ?? []).length === 0, "private routes excluded");
    }
    const allowed = osmToResortData(fixture({ ...tags, access: "private", ski: "yes" }), {});
    assert(allowed.trails.length + allowed.lifts.length + (allowed.connections ?? []).length === 1, "explicit ski permission retained");
    const denied = osmToResortData(fixture({ ...tags, access: "yes", ski: "no" }), {});
    assert(denied.trails.length + denied.lifts.length + (denied.connections ?? []).length === 0, "ski restriction wins");
  }
});

Deno.test("only explicit two-way source permission enables return lift travel", () => {
  for (const oneway of [undefined, "yes", "-1", "no"]) {
    const tags: Record<string, string> = { aerialway: "gondola" };
    if (oneway != null) tags.oneway = oneway;
    const data = osmToResortData(fixture(tags), {});
    assert(data.lifts[0].isBidirectional === (oneway === "no"), "source permission preserved");
  }
});
