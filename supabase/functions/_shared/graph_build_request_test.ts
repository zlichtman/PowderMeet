import { parseGraphBuildRequest } from "./graph_build_request.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("graph build request accepts an exact staged manifest tuple", () => {
  const parsed = parseGraphBuildRequest({
    resort_id: "vail",
    manifest_version: 4,
    snapshot_date: "2026-08-09",
    graph_version: "v11",
  }, "v11");
  assert(parsed.ok, "complete build request should parse");
  assert(parsed.value.manifest_version === 4, "manifest should survive");
  assert(parsed.value.snapshot_date === "2026-08-09", "date should survive");
  assert(parsed.value.graph_version === "v11", "version should survive");
});

Deno.test("graph build request supplies the current builder version", () => {
  const parsed = parseGraphBuildRequest({ resort_id: "vail" }, "v11");
  assert(parsed.ok, "minimal operator request should parse");
  assert(parsed.value.graph_version === "v11", "default version should apply");
});

Deno.test("graph build request rejects malformed runtime input", () => {
  const invalid = [
    null,
    [],
    {},
    { resort_id: "../vail" },
    { resort_id: "vail", manifest_version: true },
    { resort_id: "vail", manifest_version: "4" },
    { resort_id: "vail", manifest_version: 0 },
    { resort_id: "vail", snapshot_date: "2026-02-30" },
    { resort_id: "vail", graph_version: "v10" },
  ];
  for (const candidate of invalid) {
    assert(
      !parseGraphBuildRequest(candidate, "v11").ok,
      "malformed build input must fail closed",
    );
  }
});
