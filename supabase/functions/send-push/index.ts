// send-push — APNs HTTP/2 fan-out for friend + meet events.
//
// Invoked by AFTER triggers on friendships / friend_requests /
// meet_requests via pg_net.http_post (see migration
// 20260502_device_tokens_and_push.sql). Receives:
//
//   { user_id: string, kind: string, payload: object }
//
// Looks up every device_tokens row for that user and POSTs to
// https://api.push.apple.com/3/device/{token}. Uses APNs provider-token
// auth (a JWT signed with an Apple-issued ES256 .p8 key) so we don't
// have to manage cert renewals.
//
// Required environment variables (set via `supabase secrets set`):
//
//   APNS_AUTH_KEY     — full PEM body of the .p8 file (multi-line is fine)
//   APNS_KEY_ID       — 10-character Key ID from the Apple Developer portal
//   APNS_TEAM_ID      — 10-character Team ID
//   APNS_BUNDLE_ID    — com.powdermeet.PowderMeet (matches Info.plist)
//   APNS_ENVIRONMENT  — "development" or "production"
//
// Plus the standard:
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY  — needed to read device_tokens (bypasses RLS)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

interface PushBody {
  user_id: string
  kind: 'friend_request' | 'friend_added' | 'meet_request' | 'meet_started'
  payload: Record<string, unknown>
}

interface DeviceTokenRow {
  token: string
  platform: string
}

const APNS_HOST = (Deno.env.get('APNS_ENVIRONMENT') ?? 'development') === 'production'
  ? 'https://api.push.apple.com'
  : 'https://api.sandbox.push.apple.com'

// ────────────────────────────────────────────────────────────────────
// JWT signing for APNs provider-token auth
// ────────────────────────────────────────────────────────────────────

let cachedToken: { jwt: string; exp: number } | null = null

async function apnsAuthToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  // Tokens are valid up to 60 minutes; refresh ~50 minutes in to leave
  // a safety margin without thrashing.
  if (cachedToken && cachedToken.exp > now + 600) {
    return cachedToken.jwt
  }

  const keyId   = Deno.env.get('APNS_KEY_ID')!
  const teamId  = Deno.env.get('APNS_TEAM_ID')!
  const pemBody = Deno.env.get('APNS_AUTH_KEY')!

  const header  = { alg: 'ES256', kid: keyId, typ: 'JWT' }
  const payload = { iss: teamId, iat: now }
  const jwt     = await signES256(header, payload, pemBody)
  cachedToken   = { jwt, exp: now + 50 * 60 }
  return jwt
}

function base64UrlEncode(bytes: Uint8Array): string {
  let b64 = btoa(String.fromCharCode(...bytes))
  return b64.replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '')
}

function base64UrlEncodeText(text: string): string {
  return base64UrlEncode(new TextEncoder().encode(text))
}

async function signES256(
  header: Record<string, unknown>,
  payload: Record<string, unknown>,
  pem: string
): Promise<string> {
  const headerB64  = base64UrlEncodeText(JSON.stringify(header))
  const payloadB64 = base64UrlEncodeText(JSON.stringify(payload))
  const signingInput = `${headerB64}.${payloadB64}`

  // Strip PEM armor and base64-decode the key body to a PKCS#8 binary
  // for crypto.subtle.importKey.
  const keyBody = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '')
  const keyBytes = Uint8Array.from(atob(keyBody), c => c.charCodeAt(0))

  const cryptoKey = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign']
  )

  const signatureBuf = await crypto.subtle.sign(
    { name: 'ECDSA', hash: { name: 'SHA-256' } },
    cryptoKey,
    new TextEncoder().encode(signingInput)
  )

  const signatureB64 = base64UrlEncode(new Uint8Array(signatureBuf))
  return `${signingInput}.${signatureB64}`
}

// ────────────────────────────────────────────────────────────────────
// APNs payload assembly
// ────────────────────────────────────────────────────────────────────

interface RenderedAlert { title: string; body: string }

async function renderAlert(
  body: PushBody,
  supabase: ReturnType<typeof createClient>
): Promise<RenderedAlert> {
  // Resolve the "other party" display name for richer copy. Falls back
  // to neutral phrasing if the lookup misses.
  async function nameOf(userId: string | unknown): Promise<string> {
    if (typeof userId !== 'string') return 'A friend'
    const { data } = await supabase
      .from('profiles')
      .select('display_name')
      .eq('id', userId)
      .maybeSingle()
    const name = (data as { display_name?: string } | null)?.display_name?.trim()
    return name && name.length > 0 ? name : 'A friend'
  }

  switch (body.kind) {
    case 'friend_request': {
      const requester = await nameOf(body.payload.requester_id)
      return { title: 'FRIEND REQUEST', body: `${requester} wants to be friends` }
    }
    case 'friend_added': {
      const addressee = await nameOf(body.payload.addressee_id)
      return { title: 'FRIEND ADDED', body: `${addressee} accepted your request` }
    }
    case 'meet_request': {
      const sender = await nameOf(body.payload.sender_id)
      return { title: 'MEET REQUEST', body: `${sender} wants to meet up` }
    }
    case 'meet_started': {
      const receiver = await nameOf(body.payload.receiver_id)
      return { title: 'MEET STARTED', body: `${receiver} accepted — meetup is live` }
    }
  }
}

// ────────────────────────────────────────────────────────────────────
// Main handler
// ────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('method not allowed', { status: 405 })
  }

  let body: PushBody
  try {
    body = await req.json()
  } catch {
    return new Response('invalid json', { status: 400 })
  }
  if (!body.user_id || !body.kind) {
    return new Response('missing fields', { status: 400 })
  }

  // Service-role client so we can read device_tokens regardless of RLS
  // (the trigger has no auth.uid context).
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  const { data: tokens, error } = await supabase
    .from('device_tokens')
    .select('token, platform')
    .eq('profile_id', body.user_id)
  if (error) {
    return new Response(`device_tokens lookup failed: ${error.message}`, { status: 500 })
  }

  const iosTokens = ((tokens ?? []) as DeviceTokenRow[]).filter(t => t.platform === 'ios')
  if (iosTokens.length === 0) {
    return new Response(JSON.stringify({ delivered: 0 }), {
      headers: { 'content-type': 'application/json' }
    })
  }

  const alert = await renderAlert(body, supabase)
  const apnsPayload = {
    aps: {
      alert,
      sound: 'default',
      'mutable-content': 1
    },
    kind: body.kind,
    ...body.payload
  }

  const jwt = await apnsAuthToken()
  const bundleId = Deno.env.get('APNS_BUNDLE_ID')!

  const results = await Promise.allSettled(
    iosTokens.map(async ({ token }) => {
      const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
        method: 'POST',
        headers: {
          'authorization': `bearer ${jwt}`,
          'apns-topic': bundleId,
          'apns-push-type': 'alert',
          'content-type': 'application/json'
        },
        body: JSON.stringify(apnsPayload)
      })
      if (res.status === 410) {
        // Token retired — clean up so we don't keep posting to a dead
        // device on every event.
        await supabase
          .from('device_tokens')
          .delete()
          .eq('profile_id', body.user_id)
          .eq('token', token)
      }
      if (!res.ok) {
        const text = await res.text()
        throw new Error(`apns ${res.status}: ${text}`)
      }
      return res.status
    })
  )

  const delivered = results.filter(r => r.status === 'fulfilled').length
  const failed    = results.length - delivered
  return new Response(JSON.stringify({ delivered, failed }), {
    headers: { 'content-type': 'application/json' }
  })
})
