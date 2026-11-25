import { isPushKind, placeName, renderNotification } from "./push.ts";
import { assert, assertEquals, assertRejects } from "./testing.ts";

const now = new Date("2026-01-10T18:00:00Z");
const meet = {
  meet_id: "10000000-0000-4000-8000-000000000001",
  rendezvous_id: "roundhouse-lodge",
  partner_name: "Alex",
};

Deno.test("the notification set is exactly the eight kinds in the spec", async () => {
  const kinds = [
    "meet.proposed", "meet.accepted", "meet.declined", "meet.partner_arrived",
    "meet.ended", "meet.expired", "friend.requested", "friend.accepted",
  ];
  for (const kind of kinds) assert(isPushKind(kind), `${kind} is a notification`);
  for (const kind of ["presence", "meet.progress", "meet.updated", "marketing.digest", "friend.removed"]) {
    assert(!isPushKind(kind), `${kind} is not a notification`);
    await assertRejects(() => renderNotification(kind, {}, now), `${kind} is never rendered`);
  }
});

Deno.test("interruption level, sound and text follow the notification table", () => {
  const proposed = renderNotification("meet.proposed", meet, now);
  const aps = proposed.body.aps as Record<string, unknown>;
  assertEquals(aps.alert, { title: "Meet request", body: "Alex wants to meet at Roundhouse Lodge." }, "text");
  assert(aps["interruption-level"] === "time-sensitive" && aps.sound === "default", "time-sensitive with sound");
  assert(proposed.collapseId === meet.meet_id && proposed.priority === 10, "collapses per meet");
  assert(proposed.expiresAt === now.getTime() / 1000 + 900, "a meet push is not delivered late");

  const expired = renderNotification("meet.expired", meet, now);
  const expiredAps = expired.body.aps as Record<string, unknown>;
  assert(expiredAps["interruption-level"] === "passive" && !("sound" in expiredAps), "passive, silent");
  assert(expired.priority === 5, "passive pushes are low priority");
  assertEquals(
    (expiredAps.alert as { body: string }).body,
    "Your proposal to Alex expired.",
    "an unanswered proposal",
  );
  assertEquals(
    ((renderNotification("meet.expired", { ...meet, responded_at: "2026-01-10T17:00:00Z" }, now)
      .body.aps as Record<string, unknown>).alert as { body: string }).body,
    "Your meet with Alex expired.",
    "an accepted meet",
  );

  const declined = renderNotification("meet.declined", { ...meet, end_reason: "declined_cannot_route" }, now);
  assertEquals(
    ((declined.body.aps as Record<string, unknown>).alert as { body: string }).body,
    "Alex can't make Roundhouse Lodge: no route under current closures.",
    "the decline reason is shown",
  );

  const friend = renderNotification("friend.requested", { display_name: "Sam" }, now);
  assert(friend.collapseId === null, "friend pushes do not collapse");
  assert(placeName(undefined) === "the meeting point", "a missing rendezvous still reads");
});

Deno.test("a payload cannot override the alert, the sound or the kind", () => {
  const hostile = renderNotification("friend.accepted", {
    display_name: "Sam",
    kind: "meet.proposed",
    aps: { alert: "You won a prize", sound: "siren.caf", "interruption-level": "critical" },
  }, now);
  const aps = hostile.body.aps as Record<string, unknown>;
  assertEquals(aps.alert, { title: "Friend added", body: "Sam accepted your friend request." }, "alert");
  assert(aps["interruption-level"] === "active" && !("sound" in aps), "level and sound");
  assert(hostile.body.kind === "friend.accepted", "kind");
});
