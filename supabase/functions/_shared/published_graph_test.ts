import { parsePublishedGraphIdentity } from "./published_graph.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

const activeFields = {
  manifestVersion: "manifest_version",
  graphVersion: "published_graph_version",
  snapshotDate: "published_snapshot_date",
  contentSHA256: "published_content_sha256",
};

Deno.test("published graph identity accepts one complete exact tuple", () => {
  const result = parsePublishedGraphIdentity({
    manifest_version: 7,
    published_graph_version: "v11",
    published_snapshot_date: "2026-02-03",
    published_content_sha256: "a".repeat(64),
  }, activeFields);
  assert(result.ok, "complete publication should parse");
  assert(result.value.manifestVersion === 7, "manifest should survive");
  assert(result.value.graphVersion === "v11", "graph should survive");
  assert(result.value.snapshotDate === "2026-02-03", "date should survive");
});

Deno.test("published graph identity rejects staged or malformed rows", () => {
  const invalid = [
    null,
    {},
    {
      manifest_version: 0, published_graph_version: "v11",
      published_snapshot_date: "2026-02-03",
      published_content_sha256: "a".repeat(64),
    },
    {
      manifest_version: 1, published_graph_version: "latest",
      published_snapshot_date: "2026-02-03",
      published_content_sha256: "a".repeat(64),
    },
    {
      manifest_version: 1, published_graph_version: "v11",
      published_snapshot_date: "02/03/2026",
      published_content_sha256: "a".repeat(64),
    },
    {
      manifest_version: 1, published_graph_version: "v11",
      published_snapshot_date: "2026-02-30",
      published_content_sha256: "a".repeat(64),
    },
    {
      manifest_version: 1, published_graph_version: "v11",
      published_snapshot_date: "2026-02-03",
      published_content_sha256: "A".repeat(64),
    },
  ];
  for (const row of invalid) {
    assert(
      !parsePublishedGraphIdentity(row, activeFields).ok,
      "incomplete/malformed publication must fail closed",
    );
  }
});
