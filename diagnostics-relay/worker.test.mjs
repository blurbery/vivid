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
      get: async key => (key.startsWith('count/') && existing ? String(existing) : null),
      put: async (key, body, options) => {
        if (failStore) throw new Error('kv down');
        if (!key.startsWith('count/')) env.stored.push({key, body, options});
      },
    },
    RESEND_API_KEY: 're_test',
    calls: [],
  };
  // Stands in for Resend's API.
  env.fetcher = async (url, init) => {
    env.calls.push({url, init});
    if (failEmail) return new Response('{"message":"nope"}', {status: 500});
    env.sent.push(JSON.parse(init.body));
    return new Response('{"id":"m1"}', {status: 200});
  };
  return env;
}

const run = (request, env, options = {}) => handle(request, env, {fetcher: env.fetcher, ...options});

const post = (kind, body, headers = {}) => new Request(`https://diagnostics.vividapp.co/v1/reports/${kind}`, {
  method: 'POST', body, headers: {'Content-Type': 'application/json', 'CF-Connecting-IP': '203.0.113.9', ...headers},
});

test('a playback report is stored, emailed and gets a reference', async () => {
  const env = makeEnv();
  const body = await fixture('playback');
  const response = await run(post('playback', body), env, {now: fixedNow, reference: () => 'VR-7K2M9Q'});
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {reference: 'VR-7K2M9Q'});
  assert.equal(env.stored[0].key, 'reports/2026-10-04/VR-7K2M9Q-playback.json');
  assert.equal(env.stored[0].options.expirationTtl, 30 * 24 * 60 * 60, 'copies expire after 30 days');
  assert.equal(new TextDecoder().decode(env.stored[0].body), body, 'the copy is exactly what was sent');
  const email = env.sent[0];
  assert.deepEqual(email.to, ['diagnostics@vividapp.co']);
  assert.equal(email.from, 'Vivid Diagnostics <reports@diagnostics.vividapp.co>');
  assert.equal(env.calls[0].url, 'https://api.resend.com/emails');
  assert.equal(env.calls[0].init.headers.Authorization, 'Bearer re_test');
  assert.equal(email.subject, 'Playback report VR-7K2M9Q · tvOS 26.0 · AppleTV14,1 · HDMI · 8 ch · 412 dropped frames');
  assert.equal(email.attachments[0].filename, 'Vivid-Playback-VR-7K2M9Q.json');
  assert.equal(Buffer.from(email.attachments[0].content, 'base64').toString('utf8'), body);
});

test('problem reports are accepted and listed in the email', async () => {
  const env = makeEnv();
  const response = await run(post('problems', await fixture('problems')), env, {now: fixedNow, reference: () => 'VR-AAAAAA'});
  assert.equal(response.status, 200);
  assert.equal(env.sent[0].subject, 'Problem report VR-AAAAAA · 1 report · iOS 26.0 · iPhone17,1 · Playback failed: source refused');
  assert.match(env.sent[0].text, /VD-3F9A2C {2}Playback failed: source refused/);
});

test('download failures are accepted and other unknown kinds are not', async () => {
  const problems = JSON.parse(await fixture('problems'));
  const withKind = kind => JSON.stringify({...problems, reports: [{...problems.reports[0], title: "Couldn't start a download",
    report: {...problems.reports[0].report, kind}}]});
  const env = makeEnv();
  const accepted = await run(post('problems', withKind('download_failure')), env, {now: fixedNow, reference: () => 'VR-BBBBBB'});
  assert.equal(accepted.status, 200);
  assert.match(env.sent[0].subject, /Couldn't start a download$/);
  const rejected = await run(post('problems', withKind('download_failures')), env, {now: fixedNow});
  assert.equal(rejected.status, 400);
  assert.equal(env.sent.length, 1);
});

test('the client address is only used for rate limiting', async () => {
  const env = makeEnv();
  await run(post('playback', await fixture('playback')), env, {now: fixedNow});
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
    const response = await run(post(kind, body), env, {now: fixedNow});
    assert.equal(response.status, status, body.slice(0, 60));
  }
  assert.equal(env.sent.length, 0);
  assert.equal(env.stored.length, 0);
});

test('wrong paths, methods and content types are refused', async () => {
  const env = makeEnv();
  assert.equal((await run(new Request('https://diagnostics.vividapp.co/'), env)).status, 404);
  assert.equal((await run(new Request('https://diagnostics.vividapp.co/v1/reports/other', {method: 'POST'}), env)).status, 404);
  assert.equal((await run(new Request('https://diagnostics.vividapp.co/v1/reports/playback'), env)).status, 405);
  assert.equal((await run(post('playback', '{}', {'Content-Type': 'text/plain'}), env)).status, 415);
});

test('oversized bodies are refused before parsing', async () => {
  const env = makeEnv();
  const big = 'x'.repeat(limits.playbackBytes + 1);
  assert.equal((await run(post('playback', big), env)).status, 413);
});

test('rate limited and daily capped requests are refused', async () => {
  const body = await fixture('playback');
  const limited = await run(post('playback', body), makeEnv({allow: false}), {now: fixedNow});
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('Retry-After'), '60');
  const capped = await run(post('playback', body), makeEnv({existing: limits.perDay}), {now: fixedNow});
  assert.equal(capped.status, 503);
});

test('one working copy is enough; both failing asks the app to retry', async () => {
  const body = await fixture('playback');
  assert.equal((await run(post('playback', body), makeEnv({failEmail: true}), {now: fixedNow})).status, 200);
  assert.equal((await run(post('playback', body), makeEnv({failStore: true}), {now: fixedNow})).status, 200);
  assert.equal((await run(post('playback', body), makeEnv({failStore: true, failEmail: true}), {now: fixedNow})).status, 503);
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

test('titles with typographic characters are accepted and kept in the subject', async () => {
  const env = makeEnv();
  const report = JSON.parse(await fixture('problems'));
  report.reports[0].title = 'Server rejected a settings change · HTTP 422 · Vivid’s queue…';
  const response = await run(post('problems', JSON.stringify(report)), env, {now: fixedNow, reference: () => 'VR-BBBBBB'});
  assert.equal(response.status, 200);
  assert.match(env.sent[0].subject, /Vivid’s queue…$/);
});

test('a missing API key still keeps the stored copy', async () => {
  const env = makeEnv();
  delete env.RESEND_API_KEY;
  const response = await run(post('playback', await fixture('playback')), env, {now: fixedNow});
  assert.equal(response.status, 200);
  assert.equal(env.calls.length, 0);
  assert.equal(env.stored.length, 1);
});

test('stalls appear in the playback subject', async () => {
  const env = makeEnv();
  const report = JSON.parse(await fixture('playback'));
  report.totals.stalls = 2;
  await run(post('playback', JSON.stringify(report)), env, {now: fixedNow, reference: () => 'VR-CCCCCC'});
  assert.match(env.sent[0].subject, /412 dropped frames · 2 stalls$/);
});

test('a note is emailed in the body, kept in the copy and never put in the subject', async () => {
  const env = makeEnv();
  const report = JSON.parse(await fixture('playback'));
  report.note = 'It froze after I skipped ahead.\r\nBcc: someone@example.com\n\nThen it never came back.';
  report.totals.pausedSeconds = 0;
  report.totals.waitSeconds = 20.4;
  report.totals.longestWaitSeconds = 20.4;
  const body = JSON.stringify(report);
  const response = await run(post('playback', body), env, {now: fixedNow, reference: () => 'VR-DDDDDD'});
  assert.equal(response.status, 200);
  const email = env.sent[0];
  assert.equal(email.subject, 'Playback report VR-DDDDDD · tvOS 26.0 · AppleTV14,1 · HDMI · 8 ch · 412 dropped frames · waited 20 s to load');
  assert.ok(!/froze|Bcc/.test(email.subject));
  assert.match(email.text, /\nType: Latest playback\n\nWhat happened:\n {2}It froze after I skipped ahead\.\n {2}Bcc: someone@example\.com\n {2}\n {2}Then it never came back\.\n/);
  assert.ok(!/^Bcc:/m.test(email.text), 'note lines are indented');
  assert.equal(new TextDecoder().decode(env.stored[0].body), body);
});

test('problem reports can carry a note too', async () => {
  const env = makeEnv();
  const report = JSON.parse(await fixture('problems'));
  report.note = 'Happens every time on my TV.';
  const response = await run(post('problems', JSON.stringify(report)), env, {now: fixedNow, reference: () => 'VR-EEEEEE'});
  assert.equal(response.status, 200);
  assert.match(env.sent[0].text, /What happened:\n {2}Happens every time on my TV\.\n\nVD-/);
  assert.ok(!/my TV/.test(env.sent[0].subject));
});

test('reports without a note, or with an empty one, read as before', async () => {
  const env = makeEnv();
  const report = JSON.parse(await fixture('playback'));
  report.note = '';
  await run(post('playback', JSON.stringify(report)), env, {now: fixedNow, reference: () => 'VR-FFFFFF'});
  await run(post('playback', await fixture('playback')), env, {now: fixedNow, reference: () => 'VR-FFFFF2'});
  assert.equal(env.sent.length, 2);
  for (const email of env.sent) assert.ok(!email.text.includes('What happened'));
});

test('rejects notes that are too long, not text or contain control characters', async () => {
  const env = makeEnv();
  const playback = JSON.parse(await fixture('playback'));
  const problems = JSON.parse(await fixture('problems'));
  const longest = '😀'.repeat(limits.noteCodePoints);
  for (const [kind, base] of [['playback', playback], ['problems', problems]]) {
    const accepted = await run(post(kind, JSON.stringify({...base, note: longest})), env, {now: fixedNow});
    assert.equal(accepted.status, 200, `${kind}: ${limits.noteCodePoints} code points fit`);
    for (const note of [longest + 'x', 42, ['list'], 'bell\u0007', 'escape\u001b[2J', 'flip‮text']) {
      const response = await run(post(kind, JSON.stringify({...base, note})), env, {now: fixedNow});
      assert.equal(response.status, 400, `${kind}: ${JSON.stringify(note).slice(0, 40)}`);
    }
  }
});
