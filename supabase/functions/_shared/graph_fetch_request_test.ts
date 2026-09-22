import { parseGraphFetchRequest } from "./graph_fetch_request.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("graph fetch request resolves current v11 defaults", () => {
  const parsed = parseGraphFetchRequest({ resort_id: "vail" }, "v11");
  assert(parsed.ok, "default request should parse");
  assert(parsed.value.resort_id === "vail", "resort ID should survive");
  assert(parsed.value.graph_version === "v11", "default version should apply");
  assert(parsed.value.manifest_version == null, "default request is current");
});

Deno.test("graph fetch request preserves complete exact identity", () => {
  const sha = "a".repeat(64);
  const parsed = parseGraphFetchRequest({
    resort_id: "whistler-blackcomb",
    manifest_version: 7,
    graph_version: "v11",
    content_sha256: sha,
  }, "v11");
  assert(parsed.ok, "exact request should parse");
  assert(parsed.value.manifest_version === 7, "manifest should survive");
  assert(parsed.value.graph_version === "v11", "graph version should survive");
  assert(parsed.value.content_sha256 === sha, "SHA should survive");
});

Deno.test("graph fetch request rejects malformed runtime types and identities", () => {
  const sha = "a".repeat(64);
  const invalid = [
    null,
    [],
    {},
    { resort_id: "../vail" },
    { resort_id: "vail", manifest_version: 0 },
    { resort_id: "vail", manifest_version: "7" },
    { resort_id: "vail", cached_content_sha256: "short" },
    { resort_id: "vail", manifest_version: 7, graph_version: "latest" },
    {
      resort_id: "vail",
      manifest_version: 7,
      graph_version: "v11",
      content_sha256: sha.toUpperCase(),
    },
  ];
  for (const candidate of invalid) {
    assert(
      !parseGraphFetchRequest(candidate, "v11").ok,
      "malformed request should fail",
    );
  }
});

Deno.test("exact graph selector cannot float across the current manifest", () => {
  assert(
    !parseGraphFetchRequest({
      resort_id: "vail",
      graph_version: "v10",
    }, "v11").ok,
    "graph version without manifest should fail",
  );
  assert(
    !parseGraphFetchRequest({
      resort_id: "vail",
      content_sha256: "a".repeat(64),
    }, "v11").ok,
    "content SHA without manifest should fail",
  );
});
