import {
  bearerRole,
  manifestCountFailure,
  parseGraphBuildRequest,
} from "./graph_build_request.ts";

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

function jwtWith(claims: Record<string, unknown>): string {
  const encode = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/\+/g, "-").replace(/\//g, "_")
      .replace(/=+$/, "");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode(claims)}.signature`;
}

Deno.test("bearer role reads only the verified token's role claim", () => {
  const request = (authorization?: string) =>
    new Request("https://example.test", {
      method: "POST",
      headers: authorization ? { Authorization: authorization } : {},
    });
  assert(
    bearerRole(request(`Bearer ${jwtWith({ role: "service_role" })}`)) ===
      "service_role",
    "service role token should be recognised",
  );
  assert(
    bearerRole(request(`Bearer ${jwtWith({ role: "anon" })}`)) === "anon",
    "anon token must not read as service role",
  );
  assert(bearerRole(request()) === null, "missing header has no role");
  assert(bearerRole(request("Bearer not-a-jwt")) === null, "garbage has no role");
});

Deno.test("manifest counts must match and cannot be empty", () => {
  const manifest = { expected_trail_count: 3, expected_lift_count: 2 };
  assert(manifestCountFailure(manifest, 3, 2) === null, "exact counts pass");
  assert(manifestCountFailure(manifest, 0, 0) !== null, "a failed lookup never builds");
  assert(manifestCountFailure(manifest, 2, 2) !== null, "a short trail set fails");
  assert(manifestCountFailure(manifest, 3, 3) !== null, "an extra lift fails");
  assert(
    manifestCountFailure({ expected_trail_count: 0, expected_lift_count: 0 }, 0, 0) !==
      null,
    "a manifest with no identities is not canonical",
  );
});
