import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createAccountHandler, AccountRequestError } from './lifecycle.mjs';

const body = { action: 'enroll', idToken: 'synthetic-apple-token', authorizationCode: 'synthetic-code', nonce: 'a'.repeat(43) };
function setup(overrides = {}) {
  const calls = [];
  const identity = { subject: 'apple-subject', audience: 'app.nevestudio.carry' };
  return { calls, handler: createAccountHandler({
    authenticate: async () => ({ id: 'internal-account', appleSubjects: ['apple-subject'] }),
    verifyApple: async () => identity,
    exchangeCode: async () => ({ idToken: 'exchanged-apple-token', refreshToken: 'synthetic-refresh' }),
    enroll: async (...args) => calls.push(['enroll', ...args]),
    status: async () => true,
    requestDeletion: async (...args) => { calls.push(['delete', ...args]); return {status:'deleting'}; },
    rateLimit: async () => true,
    ...overrides,
  }) };
}
function request(value = body, headers = {}) {
  return new Request('https://synthetic.invalid/functions/v1/carry-account', {
    method: 'POST', headers: { authorization: 'Bearer synthetic-session', 'content-type': 'application/json', ...headers },
    body: JSON.stringify(value),
  });
}
test('enrollment uses authenticated internal account and never returns tokens', async () => {
  const { calls, handler } = setup();
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { status: 'enrolled' });
  assert.equal(calls[0][1], 'internal-account');
  assert.equal(response.headers.get('cache-control'), 'no-store');
});
test('authentication failure cannot reach Apple or storage', async () => {
  let contacted = false;
  const { handler } = setup({ authenticate: async () => { throw new AccountRequestError(401, 'unauthorized'); },
    verifyApple: async () => { contacted = true; } });
  assert.equal((await handler(request())).status, 401);
  assert.equal(contacted, false);
  assert.equal((await handler(request(body, { authorization: '' }))).status, 401);
});
test('wrong Apple subject cannot enroll or delete another identity', async () => {
  const { calls, handler } = setup({ verifyApple: async () => ({ subject: 'other-user', audience: 'app.nevestudio.carry' }) });
  assert.equal((await handler(request())).status, 403);
  assert.equal((await handler(request({ ...body, action: 'delete',deletionReceipt:'a'.repeat(64) }))).status, 403);
  assert.equal(calls.length, 0);
});
test('forged owner, unknown action, bad nonce and malformed body are rejected', async () => {
  const { calls, handler } = setup();
  for (const data of [{ ...body, accountId: 'victim' }, { ...body, action: 'purge' }, { ...body, nonce: 'short' }, null, []]) {
    assert.equal((await handler(request(data))).status, 400);
  }
  assert.equal(calls.length, 0);
});
test('code exchange must match the fresh native identity and nonce', async () => {
  const { calls, handler } = setup({ verifyApple: async token => ({
    subject: token === body.idToken ? 'apple-subject' : 'different', audience: 'app.nevestudio.carry' }),
  });
  assert.equal((await handler(request())).status, 403);
  assert.equal(calls.length, 0);
});
test('failed or replayed Apple code never reports successful enrollment', async () => {
  const { calls, handler } = setup({ exchangeCode: async () => { throw new AccountRequestError(401, 'invalid_apple_code'); } });
  assert.equal((await handler(request())).status, 401);
  assert.equal(calls.length, 0);
});
test('deletion failure returns no success and leaks no dependency error details', async () => {
  const { handler } = setup({ requestDeletion: async () => { throw new Error('sensitive-token'); } });
  const response = await handler(request({ ...body, action: 'delete',deletionReceipt:'a'.repeat(64) }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'service_unavailable' });
});
test('deletion acceptance never claims a completed purge', async () => {
  const { calls, handler } = setup();
  const response = await handler(request({ ...body, action: 'delete',deletionReceipt:'a'.repeat(64) }));
  assert.equal(response.status,202);
  assert.deepEqual(await response.json(), { status: 'deleting' });
  assert.equal(calls[0][0], 'delete');
  assert.equal(calls[0][1].id, 'internal-account');
});
test('GET status requires authentication and does not expose profile details', async () => {
  const { handler } = setup({ status: async () => false });
  const response = await handler(new Request('https://synthetic.invalid', { headers: { authorization: 'Bearer synthetic' } }));
  assert.deepEqual(await response.json(), { status: 'not_enrolled' });
  assert.equal((await handler(new Request('https://synthetic.invalid'))).status, 401);
});
test('rate limit prevents expensive code exchange', async () => {
  let contacted = false;
  const { handler } = setup({ rateLimit: async () => false, exchangeCode: async () => { contacted = true; } });
  assert.equal((await handler(request())).status, 429);
  assert.equal(contacted, false);
});
test('oversized streamed payload is bounded without content-length', async () => {
  const { handler } = setup();
  assert.equal((await handler(request({ ...body, idToken: 'x'.repeat(25000) }))).status, 413);
});
test('unsafe methods and content types are rejected', async () => {
  const { handler } = setup();
  assert.equal((await handler(new Request('https://synthetic.invalid', { method: 'PUT' }))).status, 405);
  assert.equal((await handler(request(body, { 'content-type': 'text/plain' }))).status, 415);
});
