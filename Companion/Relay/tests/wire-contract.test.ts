import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile } from 'node:fs/promises';
import { snapshotSchema } from '../src/protocol.ts';

test('Swift-encoded Unicode fixtures satisfy the relay wire schema', { skip: !process.env.COMPANION_WIRE_FIXTURE_PATH }, async () => {
  const fixtures: unknown[] = JSON.parse(await readFile(process.env.COMPANION_WIRE_FIXTURE_PATH!, 'utf8'));
  assert.equal(fixtures.length, 2);
  for (const fixture of fixtures) assert.equal(snapshotSchema.safeParse(fixture).success, true);
});


test('account identities and bounded older history are additive and strict', () => {
  const account = { id: 'fixture-account', plan: 'Pro', observedAt: 1000, windows: [], dailyTokens: [],
    email: 'fixture@example.com', accountType: 'chatgpt', historyObservedAt: 900, historyTruncated: true };
  const snapshot = { schemaVersion: 1, id: '11111111-1111-4111-8111-111111111111', name: 'Fixture', observedAt: 1000, account, tasks: [] };
  assert.equal(snapshotSchema.safeParse(snapshot).success, true);
  const days = Array.from({ length: 2000 }, (_, index) => ({ id: new Date(Date.UTC(2020, 0, 1 + index)).toISOString().slice(0, 10), tokens: index }));
  assert.equal(snapshotSchema.safeParse({ ...snapshot, account: { ...account, dailyTokens: days } }).success, true);
  assert.equal(snapshotSchema.safeParse({ ...snapshot, account: { ...account, dailyTokens: [...days, days[0]] } }).success, false);
  assert.equal(snapshotSchema.safeParse({ ...snapshot, account: { ...account, credential: 'must-not-be-accepted' } }).success, false);
  assert.equal(snapshotSchema.safeParse({ ...snapshot, account: { ...account, dailyTokens: [{ id: 'not-a-date', tokens: 1 }] } }).success, false);
});
