import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

test('PostgreSQL lifecycle migration enforces RLS, account lock, rate budget and purge gate', async () => {
  const database = new PGlite();
  try {
    await database.exec(`
      create role anon;
      create role authenticated;
      create role service_role bypassrls;
      create schema auth;
      create table auth.users (id uuid primary key);
      insert into auth.users values ('00000000-0000-0000-0000-000000000001'), ('00000000-0000-0000-0000-000000000002');
    `);
    const directory = new URL('./supabase/migrations/', import.meta.url);
    for (const name of (await readdir(directory)).filter(value => value.endsWith('.sql')).sort()) {
      await database.exec(await readFile(new URL(name, directory), 'utf8'));
    }
    const id = '00000000-0000-0000-0000-000000000001';
    await database.exec(`set role service_role`);
    await database.query('select public.carry_account_enroll($1, $2, $3, $4)', [id, 'subject', 'app.nevestudio.carry', 'encrypted-only']);
    let data = await database.query('select status from carry_private.carry_apple_credentials');
    assert.deepEqual(data.rows, [{ status: 'active' }]);
    for (let i = 1; i <= 21; i++) {
      const result = await database.query('select public.carry_account_rate_limit($1) as allowed', [id]);
      assert.equal(result.rows[0].allowed, i <= 20);
    }
    await database.query('select public.carry_account_begin_delete($1, $2, $3, $4)', [id, 'subject', 'app.nevestudio.carry', 'encrypted-new']);
    await assert.rejects(database.query('select public.carry_account_enroll($1, $2, $3, $4)', [id, 'subject', 'app.nevestudio.carry', 'must-not-revive']), /account_deletion_pending/);
    data = await database.query('select status, encrypted_token from carry_private.carry_apple_credentials');
    assert.deepEqual(data.rows, [{ status: 'deleting', encrypted_token: 'encrypted-new' }]);
    await assert.rejects(database.query('select public.carry_account_purge_owned_data($1)', [id]), /account_data_purge_not_implemented/);
    await database.exec('reset role; set role authenticated');
    await assert.rejects(database.query('select * from carry_private.carry_apple_credentials'), /permission denied/);
    await assert.rejects(database.query('select public.carry_account_credentials($1)', [id]), /permission denied/);
    await assert.rejects(database.query('select public.carry_account_enroll($1, $2, $3, $4)', [id, 'subject', 'app.nevestudio.carry', 'forged']), /permission denied/);
    await database.exec('reset role; set role anon');
    await assert.rejects(database.query('select * from carry_private.carry_apple_credentials'), /permission denied/);
    await assert.rejects(database.query('select public.carry_account_begin_delete($1, $2, $3, $4)', [id, 'subject', 'app.nevestudio.carry', 'forged']), /permission denied/);
    await database.exec('reset role');
    assert.equal((await database.query('select count(*) as count from auth.users')).rows[0].count, 2);
  } finally { await database.close(); }
});
