import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {handle, makeReference, describe, limits} from './worker.mjs';

const fixture = async name => readFile(new URL(`./fixtures/${name}.json`, import.meta.url), 'utf8');
const fixedNow = () => new Date('2026-10-04T10:30:00Z');

function makeEnv({allow = true, existing = 0, failStore = false, failEmail = false} = {}) {
  const env = {
    sent: [], stored: [], limited: [],
    RATE_LIMITER: {limit: async ({key}) => { env.limited.push(key); return {success: allow}; }},
    REPORTS: {
      list: async () => ({objects: Array.from({length: existing}, (_, i) => ({key: `x${i}`}))}),
      put: async (key, body, options) => { if (failStore) throw new Error('r2 down'); env.stored.push({key, body, options}); },
    },
    EMAIL: {send: async message => { if (failEmail) throw Object.assign(new Error('nope'), {code: 'E_X'}); env.sent.push(message); return {messageId: 'm1'}; }},
  };
  return env;
}

const post = (kind, body, headers = {}) => new Request(`https://diagnostics.vividapp.co/v1/reports/${kind}`, {
  method: 'POST', body, headers: {'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.9', ...headers},
});

test('a playback report is stored, emailed and gets a reference', async () => {
  const env = makeEnv();
  const body = await fixture('playback');
  const response = await handle(post('playback', body), env, {now: fixedNow, reference: () => 'VR-7K2M9Q'});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {reference: 'VR-7K2M9Q'});
  assert.equal(env.stored[0].key, 'reports/2026-10-04/VR-7K2M9Q-playback.json');
  assert.equal(new TextDecoder().decode(env.stored[0].body), body, 'the copy is exactly what was sent');
  const email = env.sent[0];
  assert.equal(email.to, 'diagnostics@vividapp.co');
  assert.equal(email.subject, 'Playback report VR-7K2M9Q · tvOS 26.0 · AppleTV14,1 · HDMI · 8 ch · 412 dropped frames');
  assert.equal(email.attachments[0].filename, 'Vivid-Playback-VR-7K2M9Q.json');
  assert.equal(new TextDecoder().decode(email.attachments[0].content), body);
});

test('problem reports are accepted and listed in the email', async () => {
  const env = makeEnv();
  const response = await handle(post('problems', await fixture('problems')), env, {now: fixedNow, reference: () => 'VR-AAAAAA'});
  assert.equal(response.status, 200);
  assert.equal(env.sent[0].subject, 'Problem report VR-AAAAAA · 1 report · iOS 26.0 · iPhone17,1 · Playback failed: source refused');
  assert.match(env.sent[0].text, /VD-3F9A2C {2}Playback failed: source refused/);
});

test('the client address is only used for rate limiting', async () => {
  const env = makeEnv();
  await handle(post('playback', await fixture('playback')), env, {now: fixedNow});
  assert.deepEqual(env.limited, ['203.0.113.9']);
  const everything = JSON.stringify(env.stored.map(s => s.options)) + JSON.stringify(env.sent.map(({attachments, ...rest}) => rest));
  assert.ok(!everything.includes('203.0.113.9'));
});

test('rejects anything that is not a Vivid report', async () => {
  const env = makeEnv();
  const playback = JSON.parse(await fixture('playback'));
  const cases = [
    ['playback', 'not json', 400],
    ['playback', JSON.stringify({hello: 'world'}), 400],
    ['playback', JSON.stringify({...playback, extra: 'field'}), 400],
    ['playback', JSON.stringify({...playback, format: 2}), 400],
    ['playback', JSON.stringify({...playback, app: {...playback.app, device: 'line\nbreak'}}), 400],
    ['playback', JSON.stringify({...playback, notMeasured: ['https://evil.example']}), 400],
    ['problems', JSON.stringify({format: 3, exportedAt: '2026-10-04T10:20:00Z', reports: []}), 400],
    ['problems', JSON.stringify({format: 3, exportedAt: '2026-10-04T10:20:00Z', reports: [{issueID: 'nope', title: 'x', report: {}}]}), 400],
  ];
  for (const [kind, body, status] of cases) {
    const response = await handle(post(kind, body), env, {now: fixedNow});
    assert.equal(response.status, status, body.slice(0, 60));
  }
  assert.equal(env.sent.length, 0);
  assert.equal(env.stored.length, 0);
});

test('wrong paths, methods and content types are refused', async () => {
  const env = makeEnv();
  assert.equal((await handle(new Request('https://diagnostics.vividapp.co/'), env)).status, 404);
  assert.equal((await handle(new Request('https://diagnostics.vividapp.co/v1/reports/other', {method: 'POST'}), env)).status, 404);
  assert.equal((await handle(new Request('https://diagnostics.vividapp.co/v1/reports/playback'), env)).status, 405);
  assert.equal((await handle(post('playback', '{}', {'Content-Type': 'text/plain'}), env)).status, 415);
});

test('oversized bodies are refused before parsing', async () => {
  const env = makeEnv();
  const big = 'x'.repeat(limits.playbackBytes + 1);
  assert.equal((await handle(post('playback', big), env)).status, 413);
});

test('rate limited and daily capped requests are refused', async () => {
  const body = await fixture('playback');
  const limited = await handle(post('playback', body), makeEnv({allow: false}), {now: fixedNow});
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  const capped = await handle(post('playback', body), makeEnv({existing: limits.perDay}), {now: fixedNow});
  assert.equal(capped.status, 503);
});

test('one working copy is enough; both failing asks the app to retry', async () => {
  const body = await fixture('playback');
  assert.equal((await handle(post('playback', body), makeEnv({failEmail: true}), {now: fixedNow})).status, 200);
  assert.equal((await handle(post('playback', body), makeEnv({failStore: true}), {now: fixedNow})).status, 200);
  assert.equal((await handle(post('playback', body), makeEnv({failStore: true, failEmail: true}), {now: fixedNow})).status, 503);
});

test('references are short, unambiguous and random', () => {
  assert.equal(makeReference(new Uint8Array([0, 1, 2, 3, 4, 5])), 'VR-234567');
  const seen = new Set(Array.from({length: 2000}, () => makeReference()));
  assert.ok(seen.size > 1990);
  for (const reference of seen) assert.match(reference, /^VR-[2-9A-HJKMNP-TV-Z]{6}$/);
});

test('subjects never contain line breaks or control characters', () => {
  const report = {reports: [{issueID: 'VD-000000', title: 'Bad\r\nBcc: someone', report: {app: {os: 'iOS 26', device: 'iPhone'}}}]};
  const subject = describe('problems', report, 'VR-222222');
  assert.ok(!/[\r\n]/.test(subject));
});
