import type { AlertEvent } from './alerts';
import { livePayload, type LiveMessage } from './live-activities.ts';
export interface PushRegistration { token: string; environment: 'sandbox' | 'production'; kinds: string[];
  liveActivities?: { enabled: boolean; pushToStartToken?: string } }
export type PushResult = 'accepted' | 'invalid-token' | 'retry' | 'not-configured' | 'configuration-error' | 'rejected';
const encode = (data: string | Uint8Array) => {
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
};
// Provider credentials are deployment configuration, never viewer/request data.
// Reuse the signature across sends; APNs rejects excessive token rotation.
let cachedProvider: { keyID: string; teamID: string; privateKey: string; issuedAt: number; token: Promise<string> } | undefined;
export async function providerToken(env: Env, now = Date.now()): Promise<string | undefined> {
  if (!env.APNS_PRIVATE_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return undefined;
  if (cachedProvider && cachedProvider.keyID === env.APNS_KEY_ID && cachedProvider.teamID === env.APNS_TEAM_ID
    && cachedProvider.privateKey === env.APNS_PRIVATE_KEY && now >= cachedProvider.issuedAt
    && now - cachedProvider.issuedAt < 50 * 60 * 1000) return cachedProvider.token;
  const entry = { keyID: env.APNS_KEY_ID, teamID: env.APNS_TEAM_ID, privateKey: env.APNS_PRIVATE_KEY,
    issuedAt: now, token: signProviderToken(env, now) };
  cachedProvider = entry;
  try { return await entry.token; }
  catch (error) { if (cachedProvider === entry) cachedProvider = undefined; throw error; }
}
async function signProviderToken(env: Env, now: number): Promise<string> {
  const body = `${encode(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID }))}.${encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) }))}`;
  const text = env.APNS_PRIVATE_KEY.replace(/-----[^-]+-----/g, '').replace(/\s/g, '');
  const bytes = Uint8Array.from(atob(text), c => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', bytes, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
  const signature = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(body)));
  return `${body}.${encode(signature)}`;
}
export async function sendPush(env: Env, device: PushRegistration, event: AlertEvent): Promise<PushResult> {
  const payload = notificationPayload(event);
  if (!payload) return 'rejected';
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(event.id)));
  const collapse = [...digest].map(b => b.toString(16).padStart(2, '0')).join('');
  return deliverAPNs(env, device, payload, { topic: env.APNS_BUNDLE_ID, type: 'alert', priority: '10', collapse, expires: event.at + 3600 });
}

export async function sendLivePush(env: Env, device: PushRegistration, message: LiveMessage, urgent: boolean): Promise<PushResult> {
  const payload = livePayload(message);
  if (new TextEncoder().encode(payload).length > 4096) return 'rejected';
  return deliverAPNs(env, device, payload, { topic: env.APNS_BUNDLE_ID + '.push-type.liveactivity', type: 'liveactivity',
    priority: urgent || message.event !== 'update' ? '10' : '5', collapse: 'live:' + message.macID,
    expires: message.timestamp + 90 });
}

async function deliverAPNs(env: Env, device: PushRegistration, payload: string,
  options: { topic: string; type: string; priority: string; collapse: string; expires: number }): Promise<PushResult> {
  const jwt = await providerToken(env);
  if (!jwt) return 'not-configured';
  const host = device.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
  const response = await fetch(`https://${host}/3/device/${device.token}`, {
    // Workers supports manual/follow, not redirect:error. Never forward the JWT.
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(15000),
    headers: { authorization: `bearer ${jwt}`, 'apns-topic': options.topic,
      'apns-push-type': options.type, 'apns-priority': options.priority, 'apns-collapse-id': options.collapse,
      'apns-expiration': String(Math.floor(options.expires)), 'content-type': 'application/json' },
    body: payload,
  });
  if (response.status === 200) { await response.body?.cancel(); return 'accepted'; }
  // Only retain Apple's error category, never the device token or notification.
  const reason = await responseReason(response);
  if (response.status === 410 || ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(reason)) return 'invalid-token';
  if (reason === 'ExpiredProviderToken') { cachedProvider = undefined; return 'retry'; }
  if (response.status === 403 || ['BadTopic', 'MissingTopic', 'TopicDisallowed'].includes(reason)) return 'configuration-error';
  if (response.status === 429 || response.status >= 500 || reason === 'IdleTimeout') return 'retry';
  return 'rejected';
}

// APNs limits the entire regular notification JSON payload to 4096 UTF-8 bytes.
// Preserve routing metadata and whole graphemes when an unusually long body or
// JSON-escaped text needs shortening. Normal notifications are unchanged.
export function notificationPayload(event: AlertEvent): string | undefined {
  const value = { aps: { alert: { title: event.title, body: event.body }, sound: 'default',
    'thread-id': event.taskID ? `task:${event.macID}:${event.taskID}` : 'allowances' },
    macID: event.macID, taskID: event.taskID };
  const encode = () => JSON.stringify(value);
  const fits = (text: string) => new TextEncoder().encode(text).byteLength <= 4096;
  let result = encode();
  if (fits(result)) return result;
  const segmenter = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
  for (const field of ['body', 'title'] as const) {
    const segments = [...segmenter.segment(value.aps.alert[field])].map(part => part.segment);
    value.aps.alert[field] = '';
    let low = 0, high = segments.length;
    while (low < high) {
      const count = Math.ceil((low + high) / 2);
      value.aps.alert[field] = segments.slice(0, count).join('') + '…';
      if (fits(encode())) low = count;
      else high = count - 1;
    }
    value.aps.alert[field] = low ? segments.slice(0, low).join('') + '…' : '';
    result = encode();
    if (fits(result)) return result;
  }
  return undefined;
}

async function responseReason(response: Response): Promise<string> {
  const reader = response.body?.getReader();
  if (!reader) return '';
  let text = '', size = 0;
  const decoder = new TextDecoder();
  try {
    while (true) {
      const chunk = await reader.read(); if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > 2048) return '';
      text += decoder.decode(chunk.value, { stream: true });
    }
    const parsed = JSON.parse(text + decoder.decode());
    return typeof parsed.reason === 'string' ? parsed.reason : '';
  } catch { return ''; }
  finally { await reader.cancel(); }
}
