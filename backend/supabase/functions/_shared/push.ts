// Turns an outbox row into an APNs notification. The notification set is fixed
// (specs/11-SETUP-RELEASE.md section 5): the database refuses to queue any
// other kind, and this file refuses to render one.
//
// The text is built here from the row's payload only. Whatever is in the
// payload, the `aps` block is written last, so a payload can never override
// the alert, sound or interruption level.

export type PushKind =
  | "meet.proposed"
  | "meet.accepted"
  | "meet.declined"
  | "meet.partner_arrived"
  | "meet.ended"
  | "meet.expired"
  | "friend.requested"
  | "friend.accepted";

type Level = "time-sensitive" | "active" | "passive";

const PRESENTATION: Readonly<Record<PushKind, { level: Level; sound: boolean; ttlSeconds: number }>> = {
  "meet.proposed": { level: "time-sensitive", sound: true, ttlSeconds: 900 },
  "meet.accepted": { level: "time-sensitive", sound: true, ttlSeconds: 900 },
  "meet.declined": { level: "active", sound: false, ttlSeconds: 900 },
  "meet.partner_arrived": { level: "time-sensitive", sound: true, ttlSeconds: 600 },
  "meet.ended": { level: "time-sensitive", sound: true, ttlSeconds: 900 },
  "meet.expired": { level: "passive", sound: false, ttlSeconds: 3600 },
  "friend.requested": { level: "active", sound: false, ttlSeconds: 86_400 },
  "friend.accepted": { level: "active", sound: false, ttlSeconds: 86_400 },
};

export interface Notification {
  body: Record<string, unknown>;
  collapseId: string | null;
  priority: 5 | 10;
  expiresAt: number;
}

function text(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

// The database knows a rendezvous by id only; its display name lives in the
// bundle. `roundhouse-lodge` reads well enough as "Roundhouse Lodge".
export function placeName(rendezvousId: unknown): string {
  const id = text(rendezvousId);
  if (!id) return "the meeting point";
  return id.split("-").filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(" ");
}

function alert(kind: PushKind, payload: Record<string, unknown>): { title: string; body: string } {
  const name = text(payload.partner_name) ?? text(payload.display_name) ?? "A friend";
  const place = placeName(payload.rendezvous_id);
  switch (kind) {
    case "meet.proposed":
      return { title: "Meet request", body: `${name} wants to meet at ${place}.` };
    case "meet.accepted":
      return { title: "Meet accepted", body: `${name} is on the way. Meeting at ${place}.` };
    case "meet.declined":
      return {
        title: "Meet declined",
        body: payload.end_reason === "declined_cannot_route"
          ? `${name} can't make ${place}: no route under current closures.`
          : `${name} can't make ${place}.`,
      };
    case "meet.partner_arrived":
      return { title: "Arrived", body: `${name} is at ${place}.` };
    case "meet.ended":
      switch (payload.end_reason) {
        case "status_blocks_route":
          return { title: "Meet ended", body: "Meet ended: a closure blocks the route." };
        case "rendezvous_removed":
          return { title: "Meet ended", body: `Meet ended: ${place} is no longer available.` };
        case "partner_left":
          return { title: "Meet ended", body: `Meet ended: ${name} left.` };
        case "arrived":
          return { title: "You met up", body: `You and ${name} are both at ${place}.` };
        default:
          return { title: "Meet ended", body: `${name} cancelled the meet at ${place}.` };
      }
    case "meet.expired":
      return {
        title: "Meet expired",
        // responded_at is set once a proposal was accepted.
        body: payload.responded_at
          ? `Your meet with ${name} expired.`
          : `Your proposal to ${name} expired.`,
      };
    case "friend.requested":
      return { title: "Friend request", body: `${name} wants to be friends.` };
    case "friend.accepted":
      return { title: "Friend added", body: `${name} accepted your friend request.` };
  }
}

export function isPushKind(kind: string): kind is PushKind {
  return Object.hasOwn(PRESENTATION, kind);
}

export function renderNotification(
  kind: string,
  payload: Record<string, unknown>,
  now: Date,
): Notification {
  if (!isPushKind(kind)) throw new Error(`not a notification kind: ${kind}`);
  const presentation = PRESENTATION[kind];
  const meetId = text(payload.meet_id);
  const aps: Record<string, unknown> = {
    alert: alert(kind, payload),
    "interruption-level": presentation.level,
  };
  if (presentation.sound) aps.sound = "default";
  if (meetId) aps["thread-id"] = meetId;
  return {
    // `aps` and `kind` last: nothing in the payload can replace them.
    body: { ...payload, kind, aps },
    collapseId: meetId,
    priority: presentation.level === "passive" ? 5 : 10,
    expiresAt: Math.floor(now.getTime() / 1000) + presentation.ttlSeconds,
  };
}
