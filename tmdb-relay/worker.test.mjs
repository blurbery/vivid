import {test} from 'node:test';
import assert from 'node:assert/strict';
import {handle, limits} from './worker.mjs';

const token = 'test-read-token';

function makeEnv({allow = true, upstream = () => new Response('{"id":7,"vote_average":7.5}', {status: 200}), withToken = true} = {}) {
  const env = {
    limited: [], calls: [], waits: [],
    RATE_LIMITER: {limit: async ({key}) => { env.limited.push(key); return {success: allow}; }},
  };
  if (withToken) env.TMDB_READ_TOKEN = token;
  const store = new Map();
  env.cache = {
    match: async request => store.get(request.url)?.clone(),
    put: async (request, response) => { store.set(request.url, response); },
    keys: () => [...store.keys()],
  };
  // Stands in for TMDb.
  env.fetcher = async (url, init) => { env.calls.push({url, init}); return upstream(url, init); };
  env.ctx = {waitUntil: promise => env.waits.push(promise)};
  return env;
}

async function run(path, env, init = {}) {
  const request = new Request(`https://tmdb.vividapp.co${path}`, {headers: {'CF-Connecting-IP': '203.0.113.9'}, ...init});
  const response = await handle(request, env, env.ctx, {fetcher: env.fetcher, cache: env.cache});
  await Promise.all(env.waits);
  return response;
}

const discover = 'sort_by=popularity.desc&include_adult=false&page=1';

test('an allowed lookup goes to TMDb with the relay token and is cached', async () => {
  const env = makeEnv();
  const response = await run('/3/movie/7', env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {id: 7, vote_average: 7.5});
  assert.equal(env.calls.length, 1);
  assert.equal(env.calls[0].url, 'https://api.themoviedb.org/3/movie/7');
  assert.equal(env.calls[0].init.headers.Authorization, `Bearer ${token}`);
  assert.equal(env.calls[0].init.redirect, 'manual');
  assert.deepEqual(env.limited, ['203.0.113.9']);

  const again = await run('/3/movie/7', env);
  assert.equal(again.status, 200);
  assert.deepEqual(await again.json(), {id: 7, vote_average: 7.5});
  assert.equal(env.calls.length, 1, 'the second request is served from the cache');
});

test('every path the app uses is accepted', async () => {
  for (const path of [
    '/3/movie/603', '/3/movie/603/videos', '/3/tv/1399', '/3/tv/1399/videos', '/3/tv/1399/season/8/videos',
    '/3/collection/10', '/3/company/420', '/3/network/213', '/3/find/tt0944947?external_source=imdb_id',
    `/3/discover/tv?${discover}&with_networks=213`,
    `/3/discover/movie?${discover}&with_companies=420|19551`,
    `/3/discover/movie?${discover}&with_watch_providers=8|9&watch_region=AU&with_watch_monetization_types=flatrate`,
    `/3/discover/tv?${discover}&with_networks=213&air_date.gte=2025-10-18&air_date.lte=2026-10-18`,
    `/3/discover/movie?${discover}&with_companies=420&primary_release_date.gte=2025-10-18&primary_release_date.lte=2026-10-18`,
    `/3/discover/tv?${discover}&first_air_date.gte=2026-10-23&first_air_date.lte=2026-12-22`,
    `/3/discover/movie?${discover}&primary_release_date.gte=2026-10-23&primary_release_date.lte=2026-12-22`,
    '/tvmaze/shows/82/episodes',
  ]) {
    const response = await run(path, makeEnv());
    assert.equal(response.status, 200, path);
  }
});

test('other TMDb paths are refused without reaching TMDb', async () => {
  const env = makeEnv();
  for (const path of ['/3/authentication', '/3/search/movie?query=x', '/3/account', '/3/movie/7/account_states',
    '/3/movie/0', '/3/movie/abc', '/3/tv/1/season/1', '/3/person/1', '/4/list/1', '/', '/3/movie/7/']) {
    assert.equal((await run(path, env)).status, 404, path);
  }
  assert.equal(env.calls.length, 0);
  assert.equal(env.limited.length, 0);
});

test('only GET is allowed', async () => {
  const env = makeEnv();
  const response = await run('/3/movie/7', env, {method: 'POST', body: '{}'});
  assert.equal(response.status, 405);
  assert.equal(response.headers.get('Allow'), 'GET');
  assert.equal(env.calls.length, 0);
});

test('queries are checked against what the app sends', async () => {
  const env = makeEnv();
  for (const path of [
    '/3/movie/7?api_key=abc', '/3/movie/7?language=en', '/3/find/tt0944947', '/3/find/tt0944947?external_source=tvdb_id',
    `/3/discover/movie?sort_by=popularity.desc&include_adult=true&page=1`,
    `/3/discover/movie?sort_by=vote_count.desc&include_adult=false&page=1`,
    '/3/discover/movie?sort_by=popularity.desc&include_adult=false',
    `/3/discover/movie?sort_by=popularity.desc&include_adult=false&page=0`,
    `/3/discover/movie?sort_by=popularity.desc&include_adult=false&page=${limits.maxPage + 1}`,
    `/3/discover/movie?${discover}&watch_region=AUS`,
    `/3/discover/movie?${discover}&with_watch_providers=8,9`,
    `/3/discover/movie?${discover}&with_companies=abc`,
    `/3/discover/movie?${discover}&with_networks=213&with_networks=49`,
    `/3/discover/movie?${discover}&with_genres=18`,
    `/3/discover/tv?${discover}&air_date.gte=18-10-2025`,
  ]) {
    assert.equal((await run(path, env)).status, 400, path);
  }
  assert.equal(env.calls.length, 0);
});

test('query order does not change the cache entry', async () => {
  const env = makeEnv({upstream: () => new Response('{"results":[]}', {status: 200})});
  await run(`/3/discover/tv?page=1&with_networks=213&include_adult=false&sort_by=popularity.desc`, env);
  await run(`/3/discover/tv?sort_by=popularity.desc&include_adult=false&with_networks=213&page=1`, env);
  assert.equal(env.calls.length, 1);
  assert.equal(env.calls[0].url, 'https://api.themoviedb.org/3/discover/tv?include_adult=false&page=1&sort_by=popularity.desc&with_networks=213');
  assert.deepEqual(env.cache.keys(), ['https://tmdb.vividapp.co/3/discover/tv?include_adult=false&page=1&sort_by=popularity.desc&with_networks=213']);
});

test('a rate-limited client never reaches TMDb', async () => {
  const env = makeEnv({allow: false});
  const response = await run('/3/movie/7', env);
  assert.equal(response.status, 429);
  assert.equal(response.headers.get('Retry-After'), '60');
  assert.equal(env.calls.length, 0);
});

test('nothing from the client request is forwarded, and the token never comes back', async () => {
  const env = makeEnv({upstream: () => new Response('{"id":7}', {status: 200, headers: {'Set-Cookie': 'a=b', 'X-Upstream': 'x'}})});
  const response = await run('/3/movie/7', env, {headers: {
    'CF-Connecting-IP': '203.0.113.9', 'X-Forwarded-For': '203.0.113.9', Authorization: 'Bearer someone-else', Cookie: 'c=d',
  }});
  assert.deepEqual(Object.keys(env.calls[0].init.headers).sort(), ['Accept', 'Authorization']);
  assert.equal(env.calls[0].init.headers.Authorization, `Bearer ${token}`);
  assert.equal(response.headers.get('Set-Cookie'), null);
  assert.equal(response.headers.get('X-Upstream'), null);
  const text = JSON.stringify([...response.headers]) + await response.text();
  assert.ok(!text.includes(token));
  for (const key of env.cache.keys()) assert.ok(!key.includes(token));
});

test('TMDb failures are reported without blaming a key, and are not cached', async () => {
  const cases = [
    [401, 503], [403, 503], [404, 404], [429, 429], [500, 502], [301, 502],
  ];
  for (const [upstreamStatus, expected] of cases) {
    const env = makeEnv({upstream: () => new Response('{"status_message":"nope"}', {status: upstreamStatus, headers: {'Retry-After': '5'}})});
    const response = await run('/3/movie/7', env);
    assert.equal(response.status, expected, String(upstreamStatus));
    assert.equal(env.cache.keys().length, 0);
    if (expected === 429) assert.equal(response.headers.get('Retry-After'), '5');
  }
});

test('an unreachable TMDb or a missing token is a temporary failure', async () => {
  const offline = makeEnv({upstream: () => { throw new TypeError('network'); }});
  assert.equal((await run('/3/movie/7', offline)).status, 502);
  const noToken = makeEnv({withToken: false});
  assert.equal((await run('/3/movie/7', noToken)).status, 503);
  assert.equal(noToken.calls.length, 0);
});

test('an oversized answer is refused', async () => {
  const env = makeEnv({upstream: () => new Response('{}', {status: 200, headers: {'Content-Length': String(limits.maxBytes + 1)}})});
  assert.equal((await run('/3/movie/7', env)).status, 502);
  assert.equal(env.cache.keys().length, 0);
});

test('TVmaze requests go to TVmaze without the TMDb token and are cached', async () => {
  const env = makeEnv({upstream: () => new Response('[{"id":4952,"airstamp":"2011-04-18T01:00:00+00:00"}]', {status: 200})});
  const response = await run('/tvmaze/shows/82/episodes', env);
  assert.equal(response.status, 200);
  assert.equal(env.calls[0].url, 'https://api.tvmaze.com/shows/82/episodes');
  assert.equal(env.calls[0].init.headers.Authorization, undefined);
  assert.equal(env.calls[0].init.redirect, 'manual');
  assert.match(response.headers.get('Cache-Control'), /max-age=21600/);
  await run('/tvmaze/shows/82/episodes', env);
  assert.equal(env.calls.length, 1, 'the second request is served from the cache');
});

test('a TVmaze lookup answers with the show ID from the redirect', async () => {
  const env = makeEnv({upstream: () => new Response(null, {status: 301, headers: {Location: 'https://api.tvmaze.com/shows/82'}})});
  for (const path of ['/tvmaze/lookup/shows?thetvdb=121361', '/tvmaze/lookup/shows?imdb=tt0944947']) {
    const response = await run(path, env);
    assert.equal(response.status, 200, path);
    assert.deepEqual(await response.json(), {id: 82});
  }
  assert.equal(env.calls[0].url, 'https://api.tvmaze.com/lookup/shows?thetvdb=121361');
  const elsewhere = makeEnv({upstream: () => new Response(null, {status: 301, headers: {Location: 'https://example.com/shows/82'}})});
  assert.equal((await run('/tvmaze/lookup/shows?thetvdb=121361', elsewhere)).status, 502);
  const missing = makeEnv({upstream: () => new Response('{}', {status: 404})});
  assert.equal((await run('/tvmaze/lookup/shows?imdb=tt0944947', missing)).status, 404);
});

test('other TVmaze paths and queries are refused without reaching TVmaze', async () => {
  const env = makeEnv();
  for (const path of ['/tvmaze/search/shows?q=x', '/tvmaze/shows/82', '/tvmaze/people/1', '/tvmaze/schedule', '/tvmaze/shows/0/episodes']) {
    assert.equal((await run(path, env)).status, 404, path);
  }
  for (const path of ['/tvmaze/lookup/shows', '/tvmaze/lookup/shows?thetvdb=1&imdb=tt0944947', '/tvmaze/lookup/shows?tvrage=1',
    '/tvmaze/lookup/shows?imdb=0944947', '/tvmaze/shows/82/episodes?specials=1']) {
    assert.equal((await run(path, env)).status, 400, path);
  }
  assert.equal(env.calls.length, 0);
});
