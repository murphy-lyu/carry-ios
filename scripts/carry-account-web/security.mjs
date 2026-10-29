import { parseCookieHeader, serializeCookieHeader } from '@supabase/ssr';

export class WebFailure extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
}
export const randomToken = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
};
const encode = value => new TextEncoder().encode(value);
const base64 = bytes => btoa(String.fromCharCode(...new Uint8Array(bytes))).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
function unbase64(value) {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new WebFailure(400, 'invalid_flow');
  return Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0));
}
export async function sha256(value) {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', encode(value)))].map(x => x.toString(16).padStart(2, '0')).join('');
}
export function cookieMap(header) {
  if (header.length > 16384) throw new WebFailure(431, 'cookies_too_large');
  // The SDK parser keeps the first duplicate. Reject ambiguity before parsing
  // rather than checking an already de-duplicated map.
  const names = new Set();
  for (const part of header.split(';')) {
    const equal = part.indexOf('=');
    if (equal < 0) continue;
    const name = part.slice(0, equal).trim();
    if (names.has(name)) throw new WebFailure(400, 'ambiguous_cookie');
    names.add(name);
  }
  return parseCookieHeader(header);
}
export function setCookie(headers, name, value, options = {}) {
  headers.append('Set-Cookie', serializeCookieHeader(name, value, {
    ...options, path: '/', secure: true, httpOnly: true, domain: undefined,
  }));
}
export async function flowCodec(secret, origin) {
  let raw;
  try { raw = unbase64(secret); } catch { throw new Error('invalid_web_configuration'); }
  if (raw.length !== 32) throw new Error('invalid_web_configuration');
  const key = await crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']);
  return {
    async seal(purpose, value) {
      const iv = crypto.getRandomValues(new Uint8Array(12));
      const cipher = await crypto.subtle.encrypt({ name: 'AES-GCM', iv,
        additionalData: encode(`${origin}:${purpose}`) }, key, encode(JSON.stringify(value)));
      return `${base64(iv)}.${base64(cipher)}`;
    },
    async open(purpose, value, now = Date.now()) {
      try {
        if (!value || value.length > 4096 || value.split('.').length !== 2) throw new Error();
        const [iv, cipher] = value.split('.').map(unbase64);
        const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv,
          additionalData: encode(`${origin}:${purpose}`) }, key, cipher);
        const result = JSON.parse(new TextDecoder().decode(plain));
        if (!result || typeof result.expires !== 'number' || result.expires <= now ||
            result.expires > now + 10 * 60_000) throw new Error();
        return result;
      } catch { throw new WebFailure(400, 'invalid_flow'); }
    },
  };
}
export async function boundedBytes(stream, limit) {
  if (!stream) return new Uint8Array();
  const reader = stream.getReader();
  const chunks = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new WebFailure(413, 'body_too_large');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  const result = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}
export async function formValues(request, allowed) {
  if (!request.headers.get('Content-Type')?.startsWith('application/x-www-form-urlencoded')) {
    throw new WebFailure(415, 'form_required');
  }
  const form = new URLSearchParams(new TextDecoder().decode(await boundedBytes(request.body, 24000)));
  const seen = new Set();
  for (const [key] of form) {
    if (!allowed.includes(key) || seen.has(key)) throw new WebFailure(400, 'invalid_form');
    seen.add(key);
  }
  return form;
}
export function safeContinuation(raw) {
  if (!raw || raw === '/') return '/';
  const match = /^\/oauth\/consent\?authorization_id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i.exec(raw);
  if (!match) throw new WebFailure(400, 'invalid_continuation');
  return `/oauth/consent?authorization_id=${match[1]}`;
}
export function htmlEscape(value) {
  return String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}
