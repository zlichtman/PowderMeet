// APNs over HTTP/2 with provider-token (JWT) authentication. One key serves
// both environments; the host is chosen per device token from the
// `environment` it registered with.

import type { Deps } from "./worker.ts";
import type { Notification } from "./push.ts";

const HOSTS: Readonly<Record<string, string>> = {
  development: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

// Reasons that mean the token will never work again for this app. A topic
// mismatch is left out: it means APNS_BUNDLE_ID is wrong, and that must not
// delete every user's token.
const DEAD_REASONS = new Set(["BadDeviceToken", "Unregistered"]);

export type SendResult =
  | { outcome: "sent" }
  | { outcome: "dead" }
  | { outcome: "failed"; error: string };

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function base64UrlText(value: string): string {
  return base64Url(new TextEncoder().encode(value));
}

export async function signProviderToken(
  pem: string,
  keyId: string,
  teamId: string,
  issuedAt: number,
): Promise<string> {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const keyBytes = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    keyBytes,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const input = `${base64UrlText(JSON.stringify({ alg: "ES256", kid: keyId }))}.${
    base64UrlText(JSON.stringify({ iss: teamId, iat: issuedAt }))
  }`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input),
  );
  return `${input}.${base64Url(new Uint8Array(signature))}`;
}

export interface Apns {
  send(token: string, environment: string, notification: Notification): Promise<SendResult>;
}

// APNs accepts a provider token for up to an hour and rejects ones refreshed
// more than once every 20 minutes; reuse one for 40 minutes.
let cachedToken: { jwt: string; keyId: string; issuedAt: number } | null = null;

export function createApns(deps: Deps): Apns {
  const pem = deps.env("APNS_AUTH_KEY");
  const keyId = deps.env("APNS_KEY_ID");
  const teamId = deps.env("APNS_TEAM_ID");
  const bundleId = deps.env("APNS_BUNDLE_ID");
  if (!pem || !keyId || !teamId || !bundleId) {
    throw new Error("APNs is not configured (APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_BUNDLE_ID)");
  }

  async function providerToken(): Promise<string> {
    const nowSeconds = Math.floor(deps.now().getTime() / 1000);
    if (cachedToken && cachedToken.keyId === keyId && nowSeconds - cachedToken.issuedAt < 2400) {
      return cachedToken.jwt;
    }
    const jwt = await signProviderToken(pem!, keyId!, teamId!, nowSeconds);
    cachedToken = { jwt, keyId: keyId!, issuedAt: nowSeconds };
    return jwt;
  }

  return {
    async send(token, environment, notification) {
      const host = HOSTS[environment];
      if (!host) return { outcome: "failed", error: `unknown environment ${environment}` };
      try {
        const headers: Record<string, string> = {
          authorization: `bearer ${await providerToken()}`,
          "apns-topic": bundleId,
          "apns-push-type": "alert",
          "apns-priority": String(notification.priority),
          "apns-expiration": String(notification.expiresAt),
          "content-type": "application/json",
        };
        if (notification.collapseId) headers["apns-collapse-id"] = notification.collapseId;
        const response = await deps.fetch(`${host}/3/device/${token}`, {
          method: "POST",
          headers,
          body: JSON.stringify(notification.body),
          signal: AbortSignal.timeout(10_000),
        });
        if (response.ok) {
          await response.body?.cancel();
          return { outcome: "sent" };
        }
        const detail = await response.text();
        let reason = "";
        try {
          reason = String((JSON.parse(detail) as { reason?: unknown }).reason ?? "");
        } catch {
          // Not JSON: keep the status code alone.
        }
        if (response.status === 410 || (response.status === 400 && DEAD_REASONS.has(reason))) {
          return { outcome: "dead" };
        }
        return { outcome: "failed", error: `apns ${response.status} ${reason}`.trim() };
      } catch (error) {
        return { outcome: "failed", error: error instanceof Error ? error.message : String(error) };
      }
    },
  };
}
