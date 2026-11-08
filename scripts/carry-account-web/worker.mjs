import { createAccountWebAIBridge } from '../carry-account-ai/account-web-bridge.mjs';
import { accountAIPage } from '../carry-account-ai/web-pages.mjs';
import { accountStyle } from './account-style.mjs';
import { experienceStrings } from '../carry-account-ai/experience-strings.mjs';
import { aiWebStrings } from '../carry-account-ai/web-strings.mjs';
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
    // Native HTML form POST uses navigate mode: no-referrer turns its Origin
    // into "null", breaking our exact-origin CSRF gate. same-origin preserves
    // that origin locally while still suppressing referrers to Apple/clients.
    'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'same-origin',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
    'Strict-Transport-Security': 'max-age=31536000', Vary: 'Cookie, Accept-Language' });
}
function redirect(path, headers, status = 303) {
  headers.set('Location', path);
  return new Response(null, { status, headers });
}
function htmlPage(text, title, content, headers, status = 200, layout = "standard") {
  headers.set('Content-Type', 'text/html; charset=utf-8');
  return new Response(`<!doctype html><html lang="${text.lang}"><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${htmlEscape(title)}</title><link rel="stylesheet" href="/account.css"></head><body><header class="site-header"><div class="site-width"><a class="brand" href="/">Carry</a></div></header><main class="page--${layout === 'focus' ? 'focus' : 'standard'}"><h1>${htmlEscape(title)}</h1><div class="page-content">${content}</div></main><footer class="site-footer"><div class="site-width"><span>Carry</span><a href="https://legal.nevestudio.app/carry/privacy/">${htmlEscape(text.privacy)}</a></div></footer></body></html>`, { status, headers });
}
function message(code, headers, status, text, request) {
  headers.set('X-Carry-Error-Code', code);
  if (request.headers.get('Accept')?.includes('text/html')) {
    const ux = experienceStrings[text.lang] ?? experienceStrings.en;
    const url = new URL(request.url);
    let next = '/';
    try {
      // Never replay a write. OAuth search parameters are not part of the
      // continuation contract and downloads return to the review screen.
      if (url.pathname === '/oauth/consent') {
        next = safeContinuation('/oauth/consent?' + new URLSearchParams({
          authorization_id: url.searchParams.get('authorization_id') ?? '',
        }));
      } else {
        next = safeContinuation(url.pathname.replace(/\/download$/, ''));
      }
    } catch { /* Unknown paths return to the account home. */ }
    const ai = next !== '/';
    const restart = ai && ['authorization_expired', 'preview_expired', 'preview_changed',
      'invalid_preview', 'export_not_found', 'export_changed', 'invalid_token',
      'invalid_scope', 'insufficient_scope'].includes(code);
    const login = code === 'session_expired' || code === 'invalid_apple_identity';
    const title = restart ? ux.restartTitle : ux.errorTitle;
    const detail = restart ? ux.restart : login ? text.intro : ux.errorDetail;
    const href = restart ? '/ai/guide' : login ? '/login?continue=' + encodeURIComponent(next)
      : ai ? next : '/login';
    const action = restart ? ux.guide : login ? text.signIn : ux.retry;
    return htmlPage(text, title,
      `<p class="notice" role="alert">${htmlEscape(detail)}</p>
      <a class="button primary" href="${htmlEscape(href)}">${htmlEscape(action)}</a>
      <details><summary>${htmlEscape(ux.diagnostics)}</summary><code>${htmlEscape(code)}</code></details>`, headers, status, "focus");
  }
  headers.set('Content-Type', 'application/json');
  return new Response(JSON.stringify({ error: code }), { status, headers });
}
function appleButton(text) {
  const url = color => `https://appleid.cdn-apple.com/appleid/button?type=sign-in&amp;color=${color}&amp;height=48&amp;width=240&amp;border_radius=8&amp;locale=${text.apple}`;
  return `<picture><source media="(prefers-color-scheme: dark)" srcset="${url('white')}&amp;scale=2 2x, ${url('white')}&amp;scale=3 3x"><img src="${url('black')}&amp;scale=1" srcset="${url('black')}&amp;scale=2 2x, ${url('black')}&amp;scale=3 3x" alt="${htmlEscape(text.appleLabel)}" width="240" height="48"></picture>`;
}
function sameOrigin(request, origin) {
  if (request.headers.get('Origin') !== origin || request.headers.get('Sec-Fetch-Site') === 'cross-site') {
    throw new WebFailure(403, 'origin_mismatch');
  }
}
function rejectTemporaryIdentityFailure(error) {
  if (!error) return;
  // Invalid credentials can end a session, but throttling, request timeouts
  // and upstream failures cannot prove that an existing identity disappeared.
  // Never issue an unbound flow or replace browser cookies on those failures.
  const status = error.status;
  const invalidSession = status === 401 || status === 403 ||
    (status >= 400 && status < 500 && (
      error.name === 'AuthSessionMissingError' ||
      ['bad_jwt', 'session_not_found', 'refresh_token_not_found', 'refresh_token_already_used'].includes(error.code)));
  if (!invalidSession) throw new WebFailure(503, 'identity_unavailable');
}
function appleIdentityFailurePhase(error) {
  // Provider messages can contain claims/identity values. Classify in memory;
  // never include their contents, arbitrary codes or exception objects in logs.
  const detail = typeof error?.message === 'string' ? error.message.toLowerCase() : '';
  if (detail.includes('api key')) return 'apple_identity_api_key';
  if (error?.name === 'AuthRetryableFetchError' || error?.name === 'AuthUnknownError') return 'apple_identity_transport';
  if (detail.includes('bad id token')) return 'apple_identity_token_invalid';
  if (error?.code === 'unexpected_audience' || detail.includes('audience')) return 'apple_identity_audience';
  if (detail.includes('nonce')) return 'apple_identity_nonce';
  if (detail.includes('expired')) return 'apple_identity_expired';
  if (error?.code === 'provider_disabled') return 'apple_identity_provider_disabled';
  if (error?.status === 429) return 'apple_identity_rate_limited';
  if (error?.status >= 500) return 'apple_identity_provider_unavailable';
  return error ? 'apple_identity_provider_rejected' : 'apple_identity_session_missing';
}
async function upstream(fetcher, url, options) {
  // Workers rejects redirect:error before sending any request. Inspect manual
  // responses instead, retaining the rule that credentials never follow a 3xx.
  const response = await fetcher(url, { ...options, redirect: 'manual', signal: AbortSignal.timeout(15000) });
  if (response.status >= 300 && response.status < 400) {
    await response.body?.cancel().catch(() => {});
    throw new WebFailure(503, 'upstream_redirect');
  }
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
    let phase = 'configuration';
    try {
      const config = settings(env), url = new URL(request.url);
      if (url.origin !== config.origin) throw new WebFailure(400, 'host_mismatch');
      if (env.ACCOUNT_WEB_ENABLED !== 'true') throw new WebFailure(503, 'account_not_available');
      const ux = experienceStrings[text.lang] ?? experienceStrings.en;
      const ai = aiWebStrings[text.lang] ?? aiWebStrings.en;
      if (request.method === 'GET' && url.pathname === '/account.css') {
        headers.set('Content-Type', 'text/css; charset=utf-8');
        return new Response(accountStyle, { headers });
      }
      if (request.method === 'GET' && url.pathname === '/ai/guide' && env.ACCOUNT_AI_ENABLED === 'true') {
        return htmlPage(text, ux.hero, `
          <p class="lead">${htmlEscape(ux.intro)}</p>
          <ol class="stack">
            <li class="panel"><h2>1. ${htmlEscape(ux.setup)}</h2>
              <p>${htmlEscape(ux['setup.detail'])}</p><code>https://connect.nevestudio.app/mcp</code></li>
            <li class="panel"><h2>2. ${htmlEscape(ux.authorize)}</h2><p>${htmlEscape(ux['authorize.detail'])}</p></li>
            <li class="panel"><h2>3. ${htmlEscape(ux.try)}</h2><p>${htmlEscape(ux['try.detail'])}</p></li>
          </ol>
          <a class="button text-button" href="/connections">${htmlEscape(ai.connections)}</a>`, headers);
      }
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
          rejectTemporaryIdentityFailure(error);
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
      const formToken = async (accountID = null) => {
        const value = randomToken();
        setCookie(headers, FORM, await codec.seal('form', { value, accountID, expires: now() + ttl }),
          { sameSite: 'strict', maxAge: ttl / 1000 });
        return value;
      };
      const checkForm = async (form, accountID = null) => {
        sameOrigin(request, config.origin);
        const expected = await codec.open('form', cookie(FORM), now());
        if (form.get('csrf') !== expected.value || (accountID !== null && expected.accountID !== accountID)) throw new WebFailure(403, 'invalid_form');
      };
      if (url.pathname === '/oauth/consent' || url.pathname.startsWith('/ai/plans/') || url.pathname.startsWith('/ai/exports/') || url.pathname === '/connections' || url.pathname.startsWith('/connections/')) {
        if (env.ACCOUNT_AI_ENABLED !== 'true') throw new WebFailure(503, 'ai_not_available');
        const bridge = createAccountWebAIBridge({ origin: env.CARRY_AI_ORIGIN, accountOrigin: config.origin,
          secret: env.CARRY_OWNER_BRIDGE_SECRET, fetcher, now });
        const result = await accountAIPage({ request, checkedSession, formToken, checkForm, bridge, headers, text, htmlPage, finish, now });
        if (result) return result;
      }
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
        phase = 'apple_callback_form';
        // Apple's cross-site form_post cannot carry a SameSite=Lax flow cookie.
        // This short-lived encrypted cookie alone uses SameSite=None. Sessions
        // retain Lax; an exact, unpredictable state binds the cross-site POST.
        setCookie(headers, FLOW, '', { sameSite: 'none', maxAge: 0 });
        const form = await formValues(request, ['state', 'code', 'id_token', 'user', 'error']);
        const flow = await codec.open('apple', cookie(FLOW), now());
        if (form.get('state') !== flow.state || !(flow.accountID === null || uuid(flow.accountID))) {
          throw new WebFailure(403, 'invalid_flow');
        }
        if (form.get('error') === 'user_cancelled_authorize') {
          const next = safeContinuation(flow.next);
          const query = new URLSearchParams({ cancelled: '1' });
          if (next !== '/') query.set('continue', next);
          return finish(redirect('/login?' + query, headers));
        }
        const token = form.get('id_token'), code = form.get('code');
        if (!token || token.length < 16 || token.length > 16000 || !code || code.length < 8 || code.length > 4096) {
          throw new WebFailure(400, 'invalid_apple_response');
        }
        const previous = await client.auth.getUser();
        rejectTemporaryIdentityFailure(previous.error);
        const previousCookies = new Map(authCookies);
        let signedInSession;
        try {
          phase = 'apple_identity';
          const { data, error } = await client.auth.signInWithIdToken({ provider: 'apple', token, nonce: flow.nonce });
          signedInSession = data?.session;
          if (error || !data?.user || !data?.session || !uuid(data.user.id) || data.session.user.id !== data.user.id) {
            phase = appleIdentityFailurePhase(error);
            const temporary = ['apple_identity_transport', 'apple_identity_provider_unavailable',
              'apple_identity_provider_disabled', 'apple_identity_api_key'].includes(phase);
            throw new WebFailure(temporary ? 503 : error?.status === 429 ? 429 : 401,
              temporary ? 'identity_unavailable' : error?.status === 429 ? 'identity_rate_limited' : 'invalid_apple_identity');
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
            phase = 'apple_profile';
            let profile;
            try { profile = JSON.parse(form.get('user')); } catch { throw new WebFailure(400, 'invalid_apple_response'); }
            const name = [profile?.name?.firstName, profile?.name?.lastName]
              .filter(value => typeof value === 'string').join(' ').trim();
            if (name && name.length <= 200) {
              const update = await client.auth.updateUser({ data: { full_name: name } });
              if (update.error) throw new WebFailure(503, 'profile_unavailable');
            }
          }
          phase = 'account_enrollment';
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
        if (current && next !== '/') return finish(redirect(next, headers));
        const detail = next.startsWith('/oauth/consent') ? ux.connectIntro
          : next.startsWith('/ai/plans/') ? ux.planIntro
          : next.startsWith('/ai/exports/') ? ux.exportIntro
          : next === '/connections' ? ux.manageIntro : text.intro;
        const content = current
          ? `<p class="account-id">${htmlEscape(current.user.user_metadata?.full_name ?? current.user.email ?? 'Carry')}</p>
            <div class="actions">
              ${env.ACCOUNT_AI_ENABLED === 'true' ? `<a class="button primary" href="/connections">${htmlEscape(ai.connections)}</a>` : ''}
              <form method="post" action="/logout"><input type="hidden" name="csrf" value="${csrf}">
                <button class="button text-button">${htmlEscape(text.signOut)}</button></form>
            </div>`
          : `<p class="lead">${htmlEscape(detail)}</p>
            ${url.searchParams.has('cancelled') ? `<p class="notice" role="status">${htmlEscape(text.cancelled)}</p>` : ''}
            <form method="post" action="/auth/apple/start">
              <input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="continue" value="${htmlEscape(next)}">
              <button aria-label="${htmlEscape(text.appleLabel)}">${appleButton(text)}</button>
            </form>`;
        return finish(htmlPage(text, current ? text.account : text.signIn, content, headers, 200, current ? "standard" : "focus"));
      }
      throw new WebFailure(404, 'not_found');
    } catch (failure) {
      // No request URL/body, cookies, identity, provider message or exception
      // object: only our fixed stage/code/status are safe for hosted diagnosis.
      if (!(failure instanceof WebFailure && failure.code === 'not_found')) console.warn(JSON.stringify({ event: 'carry_web_failure', phase,
        code: failure instanceof WebFailure ? failure.code : 'service_unavailable',
        status: failure instanceof WebFailure ? failure.status : 503 }));
      return finish(message(failure instanceof WebFailure ? failure.code : 'service_unavailable', headers,
        failure instanceof WebFailure ? failure.status : 503, text,
        request));
    }
  };
}
export default { fetch: createWebHandler() };
