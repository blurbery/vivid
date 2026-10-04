// Receives diagnostics that someone chose to send from Vivid, keeps a copy
// for 30 days and emails it to diagnostics@vividapp.co.
//
// POST /v1/reports/playback  the latest playback record
// POST /v1/reports/problems  problem reports (crashes, freezes, failures)
//
// The body is exactly the JSON the app showed as "what is sent". The client
// IP is used only as a rate-limit key and is never stored or emailed.

export const limits = Object.freeze({
  playbackBytes: 128 * 1024,
  // The app keeps at most 2 MB of problem reports; the email limit is 5 MiB
  // after base64, so this leaves room.
  problemsBytes: Math.floor(2.5 * 1024 * 1024),
  perDay: 300,
  maxProblemReports: 50,
  maxTimelineMinutes: 240,
});

const recipient = 'diagnostics@vividapp.co';
const sender = {email: 'reports@vividapp.co', name: 'Vivid Diagnostics'};

const problemKinds = new Set(['crash', 'hang', 'cpu_exception', 'disk_write_exception', 'slow_launch',
  'unexpected_exit', 'playback_failure', 'app_error']);

// No 0/O, 1/I/L or U, so a reference read aloud or typed back is unambiguous.
const referenceAlphabet = '23456789ABCDEFGHJKMNPQRSTVWXYZ';

export function makeReference(random = crypto.getRandomValues(new Uint8Array(6))) {
  let reference = 'VR-';
  for (const byte of random) reference += referenceAlphabet[byte % referenceAlphabet.length];
  return reference;
}

const json = (status, body, extra = {}) => new Response(JSON.stringify(body), {
  status,
  headers: {'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extra},
});

const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const isDate = value => typeof value === 'string' && value.length <= 40 && !Number.isNaN(Date.parse(value));
// Version, build, OS and model strings: short, printable, no line breaks.
const isShortText = (value, max = 64) => typeof value === 'string' && value.length > 0 && value.length <= max && /^[\x20-\x7E]+$/.test(value);
const isToken = value => typeof value === 'string' && /^[a-z0-9_-]{1,32}$/.test(value);

function validApp(app) {
  return isObject(app) && ['version', 'build', 'os', 'device'].every(key => isShortText(app[key]));
}

const playbackKeys = new Set(['format', 'startedAt', 'updatedAt', 'app', 'setup', 'media', 'totals', 'timeline', 'notMeasured']);

export function validatePlayback(report) {
  if (!isObject(report)) return 'not an object';
  if (Object.keys(report).some(key => !playbackKeys.has(key))) return 'unexpected field';
  if (report.format !== 1) return 'unsupported format';
  if (!isDate(report.startedAt) || !isDate(report.updatedAt)) return 'bad dates';
  if (!validApp(report.app)) return 'bad app';
  if (!isObject(report.setup) || !isObject(report.media) || !isObject(report.totals)) return 'bad sections';
  if (!Array.isArray(report.timeline) || report.timeline.length > limits.maxTimelineMinutes
      || !report.timeline.every(minute => isObject(minute) && Number.isInteger(minute.minute))) return 'bad timeline';
  if (!Array.isArray(report.notMeasured) || !report.notMeasured.every(isToken)) return 'bad notMeasured';
  return null;
}

export function validateProblems(report) {
  if (!isObject(report)) return 'not an object';
  if (!Number.isInteger(report.format) || report.format < 1 || report.format > 99) return 'unsupported format';
  if (!isDate(report.exportedAt)) return 'bad date';
  if (!Array.isArray(report.reports) || report.reports.length === 0 || report.reports.length > limits.maxProblemReports) return 'bad reports';
  for (const entry of report.reports) {
    if (!isObject(entry) || !/^VD-[0-9A-F]{6}$/.test(entry.issueID ?? '')) return 'bad issue ID';
    if (!isShortText(entry.title, 200)) return 'bad title';
    if (!isObject(entry.report) || !problemKinds.has(entry.report.kind) || !validApp(entry.report.app)) return 'bad report';
  }
  return null;
}

// Subject parts come from validated fields, but strip anything that could
// break the header anyway.
const clean = value => String(value).replace(/[^\x20-\x7E]/g, '').trim();

export function describe(kind, report, reference) {
  if (kind === 'playback') {
    const {app, setup, media, totals} = report;
    const parts = [`Playback report ${reference}`, `${app.os}`, app.device];
    if (isToken(setup.audioOutput)) parts.push(setup.audioOutput === 'hdmi' ? 'HDMI' : setup.audioOutput);
    if (Number.isInteger(media.audioOutputChannels)) parts.push(`${media.audioOutputChannels} ch`);
    if (Number.isInteger(totals.droppedFrames) && totals.droppedFrames > 0) parts.push(`${totals.droppedFrames} dropped frames`);
    if (Number.isInteger(totals.rebuffers) && totals.rebuffers > 0) parts.push(`${totals.rebuffers} rebuffers`);
    if (isToken(totals.endReason) && totals.endReason.startsWith('failed')) parts.push(totals.endReason);
    return parts.map(clean).filter(Boolean).join(' · ').slice(0, 200);
  }
  const first = report.reports[0];
  const count = report.reports.length;
  const parts = [`Problem report${count === 1 ? '' : 's'} ${reference}`, `${count} report${count === 1 ? '' : 's'}`,
    first.report.app.os, first.report.app.device, count === 1 ? first.title : null];
  return parts.filter(Boolean).map(clean).filter(Boolean).join(' · ').slice(0, 200);
}

function emailText(kind, report, reference, receivedAt) {
  const lines = [`Reference: ${reference}`, `Received: ${receivedAt}`, `Type: ${kind === 'playback' ? 'Latest playback' : 'Problem reports'}`];
  if (kind === 'problems') {
    for (const entry of report.reports) lines.push(`${entry.issueID}  ${clean(entry.title)}`);
  }
  lines.push('', 'The full report is attached as JSON.');
  return lines.join('\n');
}

async function readBody(request, maxBytes) {
  const declared = Number(request.headers.get('Content-Length'));
  if (Number.isFinite(declared) && declared > maxBytes) return {tooLarge: true};
  const reader = request.body?.getReader();
  if (!reader) return {bytes: new Uint8Array()};
  const chunks = [];
  let size = 0;
  for (;;) {
    const {done, value} = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > maxBytes) { await reader.cancel(); return {tooLarge: true}; }
    chunks.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return {bytes};
}

export async function handle(request, env, {now = () => new Date(), reference = makeReference} = {}) {
  const url = new URL(request.url);
  const match = /^\/v1\/reports\/(playback|problems)$/.exec(url.pathname);
  if (!match) return json(404, {error: 'not_found'});
  if (request.method !== 'POST') return json(405, {error: 'method_not_allowed'}, {Allow: 'POST'});
  const kind = match[1];
  if (!(request.headers.get('Content-Type') ?? '').toLowerCase().startsWith('application/json')) {
    return json(415, {error: 'unsupported_media_type'});
  }

  // Keyed by client address only for this check; the address isn't kept.
  const client = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const {success} = await env.RATE_LIMITER.limit({key: client});
  if (!success) return json(429, {error: 'rate_limited'}, {'Retry-After': '60'});

  const {bytes, tooLarge} = await readBody(request, kind === 'playback' ? limits.playbackBytes : limits.problemsBytes);
  if (tooLarge) return json(413, {error: 'too_large'});
  let report;
  try { report = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes)); } catch { return json(400, {error: 'invalid_json'}); }
  const problem = kind === 'playback' ? validatePlayback(report) : validateProblems(report);
  if (problem) return json(400, {error: 'invalid_report', detail: problem});

  const received = now();
  const day = received.toISOString().slice(0, 10);
  const listed = await env.REPORTS.list({prefix: `reports/${day}/`, limit: limits.perDay});
  if (listed.objects.length >= limits.perDay) return json(503, {error: 'daily_limit'}, {'Retry-After': '3600'});

  const ref = reference();
  const receivedAt = received.toISOString();
  const key = `reports/${day}/${ref}-${kind}.json`;
  let stored = false;
  try {
    await env.REPORTS.put(key, bytes, {httpMetadata: {contentType: 'application/json'}, customMetadata: {kind, reference: ref, receivedAt}});
    stored = true;
  } catch (error) {
    console.error('store_failed', ref, error?.message);
  }

  let emailed = false;
  try {
    await env.EMAIL.send({
      to: recipient,
      from: sender,
      subject: describe(kind, report, ref),
      text: emailText(kind, report, ref, receivedAt),
      attachments: [{content: bytes, filename: `Vivid-${kind === 'playback' ? 'Playback' : 'Diagnostics'}-${ref}.json`, type: 'application/json', disposition: 'attachment'}],
    });
    emailed = true;
  } catch (error) {
    console.error('email_failed', ref, error?.code ?? error?.message);
  }

  // Either copy is enough for the report to be found by its reference.
  if (!stored && !emailed) return json(503, {error: 'unavailable'}, {'Retry-After': '60'});
  return json(200, {reference: ref});
}

export default {fetch: (request, env) => handle(request, env)};
