import { createServerClient } from '@supabase/ssr';
import { strings, language } from './strings.mjs';
import { WebFailure, randomToken, sha256, cookieMap, setCookie, flowCodec,
  boundedBytes, formValues, safeContinuation, htmlEscape } from './security.mjs';

const FORM = '__Host-carry-form';
const FLOW = '__Host-carry-apple-flow';
const SESSION = '__Host-carry-session';
const ttl = 10 * 60_000;
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

function settings(env) {
  const origin = new URL(env.ACCOUNT_ORIGIN);
  const project = new URL(env.SUPABASE_URL);
  if (origin.protocol !== 'https:' || origin.href !== origin.origin + '/' ||
      project.protocol !== 'https:' || project.href !== project.origin + '/' ||
      !env.SUPABASE_PUBLISHABLE_KEY?.startsWith('sb_publishable_') ||
      env.APPLE_WEB_CLIENT_ID !== 'app.nevestudio.carry.web') throw new Error('invalid_web_configuration');
  return { origin: origin.origin, project: project.origin,
    callback: origin.origin + '/auth/apple/callback', clientID: env.APPLE_WEB_CLIENT_ID };
}

function baseHeaders() {
  return new Headers({ 'Cache-Control': 'private, no-store, max-age=0', Pragma: 'no-cache', Expires: '0',
    'Content-Security-Policy': "default-src 'none'; style-src 'self'; img-src https://appleid.cdn-apple.com; form-action 'self' https://appleid.apple.com; frame-ancestors 'none'; base-uri 'none'",
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
    'Strict-Transport-Security': 'max-age=31536000', Vary: 'Cookie, Accept-Language' });
}
function redirect(path, headers, status = 303) {
  headers.set('Location', path);
  return new Response(null, { status, headers });
}
function htmlPage(text, title, content, headers, status = 200) {
  headers.set('Content-Type', 'text/html; charset=utf-8');
  return new Response(`<!doctype html><html lang="${text.lang}"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${htmlEscape(title)}</title><link rel="stylesheet" href="/account.css"></head><body><main><p>Carry</p><h1>${htmlEscape(title)}</h1>${content}<p><a href="https://legal.nevestudio.app/privacy/">${htmlEscape(text.privacy)}</a></p></main></body></html>`, { status, headers });
}
function message(code, headers, status, text, wantsHTML) {
  if (wantsHTML) return htmlPage(text, text.signIn,
    `<p role="alert">${htmlEscape(text.unavailable)}</p><a href="/login">${htmlEscape(text.retry)}</a>`, headers, status);
  headers.set('Content-Type', 'application/json');
  return new Response(JSON.stringify({ error: code }), { status, headers });
}
function appleButton(text) {
  const url = color => `https://appleid.cdn-apple.com/appleid/button?type=sign-in&amp;color=${color}&amp;height=44&amp;width=220&amp;border_radius=8&amp;locale=${text.apple}`;
  return `<picture><source media="(prefers-color-scheme: dark)" srcset="${url('white')}&amp;scale=2 2x, ${url('white')}&amp;scale=3 3x"><img src="${url('black')}&amp;scale=1" srcset="${url('black')}&amp;scale=2 2x, ${url('black')}&amp;scale=3 3x" alt="${htmlEscape(text.appleLabel)}" width="220" height="44"></picture>`;
}
function sameOrigin(request, origin) {
  if (request.headers.get('Origin') !== origin || request.headers.get('Sec-Fetch-Site') === 'cross-site') {
    throw new WebFailure(403, 'origin_mismatch');
  }
}
async function upstream(fetcher, url, options) {
  const response = await fetcher(url, { ...options, redirect: 'error', signal: AbortSignal.timeout(15000) });
  const bytes = await boundedBytes(response.body, 128 * 1024);
  return new Response([204, 205, 304].includes(response.status) ? null : bytes, {
    status: response.status, statusText: response.statusText, headers: response.headers });
}

// Supabase owns identity, refresh-token rotation and OAuth. This worker only
// bridges first-party browser cookies and the shared lifecycle service; it never
// receives an Apple signing key, database service key or any travel data.
export function createWebHandler({ makeClient = createServerClient, fetcher = fetch, now = Date.now } = {}) {
  return async (request, env) => {
    const headers = baseHeaders();
    const text = strings[language(request.headers.get('Accept-Language'))];
    let authCookies = new Map();
    const finish = response => {
      for (const { name, value, options } of authCookies.values()) setCookie(response.headers, name, value, options);
      return response;
    };
    let client;
    try {
      const config = settings(env), url = new URL(request.url);
      if (url.origin !== config.origin) throw new WebFailure(400, 'host_mismatch');
      if (env.ACCOUNT_WEB_ENABLED !== 'true') throw new WebFailure(503, 'account_not_available');
      const cookies = cookieMap(request.headers.get('Cookie') ?? '');
      const cookie = name => cookies.find(value => value.name === name)?.value;
      const codec = await flowCodec(env.WEB_FLOW_ENCRYPTION_KEY, config.origin);
      client = makeClient(config.project, env.SUPABASE_PUBLISHABLE_KEY, {
        cookieOptions: { name: SESSION, path: '/', secure: true, httpOnly: true, sameSite: 'lax' },
        cookies: {
          getAll: () => cookies,
          setAll: (values, cacheHeaders) => {
            for (const value of values) authCookies.set(value.name, value);
            for (const [key, value] of Object.entries(cacheHeaders ?? {})) headers.set(key, value);
          },
        },
        global: { fetch: (url, options) => upstream(fetcher, url, options) },
      });
      const lifecycle = async (session, body) => {
        const response = await upstream(fetcher, config.project + '/functions/v1/carry-account', {
          method: body ? 'POST' : 'GET', headers: { apikey: env.SUPABASE_PUBLISHABLE_KEY,
            Authorization: `Bearer ${session.access_token}`, 'Content-Type': 'application/json' },
          body: body ? JSON.stringify(body) : undefined,
        });
        const data = await response.json();
        if (!response.ok || data.status !== 'enrolled') throw new WebFailure(503, 'account_unavailable');
      };
      const checkedSession = async () => {
        const { data: { user }, error } = await client.auth.getUser();
        if (error) {
          // A network/provider outage is not evidence that the browser signed
          // out. Do not start an unbound sign-in flow on a transient failure.
          if (!(error.status >= 400 && error.status < 500)) throw new WebFailure(503, 'identity_unavailable');
          return null;
        }
        if (!user) return null;
        const { data: { session }, error: sessionError } = await client.auth.getSession();
        if (sessionError || !session || session.user.id !== user.id || !uuid(user.id)) {
          throw new WebFailure(401, 'session_expired');
        }
        await lifecycle(session);
        return { user, session };
      };
      const formToken = async () => {
        const value = randomToken();
        setCookie(headers, FORM, await codec.seal('form', { value, expires: now() + ttl }),
          { sameSite: 'strict', maxAge: ttl / 1000 });
        return value;
      };
      const checkForm = async form => {
        sameOrigin(request, config.origin);
        const expected = await codec.open('form', cookie(FORM), now());
        if (form.get('csrf') !== expected.value) throw new WebFailure(403, 'invalid_form');
      };
      if (request.method === 'POST' && url.pathname === '/auth/apple/start') {
        const form = await formValues(request, ['csrf', 'continue']);
        await checkForm(form);
        const previous = await checkedSession();
        const state = randomToken(), nonce = randomToken();
        const next = safeContinuation(form.get('continue'));
        setCookie(headers, FLOW, await codec.seal('apple', { state, nonce, next, accountID: previous?.user.id ?? null, expires: now() + ttl }),
          { sameSite: 'none', maxAge: ttl / 1000 });
        const authorize = new URL('https://appleid.apple.com/auth/authorize');
        authorize.search = new URLSearchParams({ client_id: config.clientID, redirect_uri: config.callback,
          response_type: 'code id_token', response_mode: 'form_post', scope: 'name email',
          state, nonce: await sha256(nonce) }).toString();
        return finish(redirect(authorize.href, headers));
      }
      if (request.method === 'POST' && url.pathname === '/auth/apple/callback') {
        // Apple's cross-site form_post cannot carry a SameSite=Lax flow cookie.
        // This short-lived encrypted cookie alone uses SameSite=None. Sessions
        // retain Lax; an exact, unpredictable state binds the cross-site POST.
        setCookie(headers, FLOW, '', { sameSite: 'none', maxAge: 0 });
        const form = await formValues(request, ['state', 'code', 'id_token', 'user', 'error']);
        const flow = await codec.open('apple', cookie(FLOW), now());
        if (form.get('state') !== flow.state || !(flow.accountID === null || uuid(flow.accountID))) {
          throw new WebFailure(403, 'invalid_flow');
        }
        if (form.get('error') === 'user_cancelled_authorize') return finish(redirect('/login?cancelled=1', headers));
        const token = form.get('id_token'), code = form.get('code');
        if (!token || token.length < 16 || token.length > 16000 || !code || code.length < 8 || code.length > 4096) {
          throw new WebFailure(400, 'invalid_apple_response');
        }
        const previous = await client.auth.getUser();
        const previousCookies = new Map(authCookies);
        let signedInSession;
        try {
          const { data, error } = await client.auth.signInWithIdToken({ provider: 'apple', token, nonce: flow.nonce });
          signedInSession = data?.session;
          if (error || !data?.user || !data?.session || !uuid(data.user.id) || data.session.user.id !== data.user.id) {
            throw new WebFailure(401, 'invalid_apple_identity');
          }
          // Lax session cookies are deliberately absent on Apple's cross-site
          // POST. Bind the verified initiating account in the encrypted flow;
          // a callback-only getUser() check would silently miss account swaps.
          if ((flow.accountID && flow.accountID !== data.user.id) ||
              (previous.data.user && previous.data.user.id !== data.user.id)) {
            throw new WebFailure(409, 'account_mismatch');
          }
          // Save Apple's once-only name after verified identity, before the
          // one-use code exchange. This is display metadata, never authority.
          if (form.has('user')) {
            let profile;
            try { profile = JSON.parse(form.get('user')); } catch { throw new WebFailure(400, 'invalid_apple_response'); }
            const name = [profile?.name?.firstName, profile?.name?.lastName]
              .filter(value => typeof value === 'string').join(' ').trim();
            if (name && name.length <= 200) {
              const update = await client.auth.updateUser({ data: { full_name: name } });
              if (update.error) throw new WebFailure(503, 'profile_unavailable');
            }
          }
          await lifecycle(data.session, { action: 'enroll', idToken: token,
            authorizationCode: code, nonce: flow.nonce });
        } catch (failure) {
          // Revoke the newly issued session, never publish its cookies after a
          // failed enrollment. Existing browser cookies remain unchanged.
          try {
            const changedCookies = [...authCookies].some(([name, value]) =>
              value.value !== previousCookies.get(name)?.value);
            if (signedInSession || changedCookies) await client.auth.signOut({ scope: 'local' });
          } finally { authCookies = previousCookies; }
          throw failure;
        }
        return finish(redirect(safeContinuation(flow.next), headers));
      }
      if (request.method === 'POST' && url.pathname === '/logout') {
        const form = await formValues(request, ['csrf']);
        await checkForm(form);
        const current = await checkedSession();
        if (current) {
          const { error } = await client.auth.signOut({ scope: 'local' });
          if (error) throw new WebFailure(503, 'logout_unavailable');
        }
        return finish(redirect('/login', headers));
      }
      if (request.method === 'GET' && ['/', '/login'].includes(url.pathname)) {
        const current = await checkedSession();
        const csrf = await formToken();
        const next = safeContinuation(url.searchParams.get('continue'));
        const title = current ? text.account : text.signIn;
        const content = current
          ? `<p>${htmlEscape(current.user.user_metadata?.full_name ?? current.user.email ?? 'Carry')}</p><form method="post" action="/logout"><input type="hidden" name="csrf" value="${csrf}"><button class="text-button">${htmlEscape(text.signOut)}</button></form>`
          : `<p>${htmlEscape(text.intro)}</p>${url.searchParams.has('cancelled') ? `<p role="status">${htmlEscape(text.cancelled)}</p>` : ''}<form method="post" action="/auth/apple/start"><input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="continue" value="${htmlEscape(next)}"><button aria-label="${htmlEscape(text.appleLabel)}">${appleButton(text)}</button></form>`;
        return finish(htmlPage(text, title, content, headers));
      }
      if (request.method === 'GET' && url.pathname === '/account.css') {
        headers.set('Content-Type', 'text/css; charset=utf-8');
        return new Response('html{color-scheme:light dark;font:17px -apple-system,BlinkMacSystemFont,system-ui,sans-serif}body{margin:0;background:Canvas;color:CanvasText}main{max-width:30rem;margin:12vh auto;padding:24px}h1{font-size:2rem;letter-spacing:-.04em}p{line-height:1.5;text-wrap:pretty}button{font:inherit;min-height:44px;cursor:pointer;border-radius:8px;padding:0;border:0;background:transparent}a{color:LinkText}.text-button{color:LinkText;padding:8px 12px;border:1px solid ButtonBorder}img{display:block;max-width:100%}button:focus-visible,a:focus-visible{outline:3px solid Highlight;outline-offset:4px}', { headers });
      }
      throw new WebFailure(404, 'not_found');
    } catch (failure) {
      return finish(message(failure instanceof WebFailure ? failure.code : 'service_unavailable', headers,
        failure instanceof WebFailure ? failure.status : 503, text,
        request.headers.get('Accept')?.includes('text/html')));
    }
  };
}
export default { fetch: createWebHandler() };
