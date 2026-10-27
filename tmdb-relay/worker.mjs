// Answers Vivid's TMDb lookups with Vivid's own TMDb read access token, so
// people don't need a TMDb key of their own, and the Calendar's TVmaze air
// times, so TVmaze never sees anyone's address. Only the requests the app
// makes are accepted, and answers are cached at the edge.
//
// GET /3/<TMDb path>?<query>         the same path and query the app would send to TMDb
// GET /tvmaze/<TVmaze path>?<query>  the same for TVmaze's public API, which needs no key
//
// The client IP is used only as a rate-limit key. It isn't stored, logged or
// sent upstream, and nothing from the client's request is forwarded except
// the path and the checked query.

const upstream = 'https://api.themoviedb.org/3/';
const tvmazeUpstream = 'https://api.tvmaze.com/';

export const limits = Object.freeze({
  // TMDb allows caching for up to six months. A day keeps ratings and
  // trailers fresh while serving most requests from the edge.
  cacheSeconds: 24 * 60 * 60,
  // The app refuses anything larger.
  maxBytes: 2_000_000,
  // Studios & Networks reads up to five pages of each list.
  maxPage: 10,
  timeoutMs: 10_000,
});

// This week's worldwide trending titles lead Studios & Networks' Popular rows.
// TMDb can't filter them by brand, so the app reads the whole list: 500 of
// TMDb's pages for each of movies and series. The relay reads 25 at a time and
// answers them as one block with only the fields the app matches on, so a
// device reads the list in 20 requests instead of 500. TMDb updates it daily.
export const trendingBlocks = Object.freeze({
  pages: 25,
  count: 20,
  cacheSeconds: 6 * 60 * 60,
  fields: ['id', 'title', 'name', 'release_date', 'first_air_date', 'genre_ids', 'original_language', 'origin_country'],
});

const id = '[1-9][0-9]{0,9}';
const idList = new RegExp(`^${id}(\\|${id}){0,19}$`);
const day = /^20[0-9]{2}-[01][0-9]-[0-3][0-9]$/;
// The app's language, for titles and overviews. Optional: older app versions
// don't send it.
const language = /^[a-z]{2}-[A-Z]{2}$/;

// Every path the app requests, with the query each one may carry. Anything
// else, including TMDb's own account and authentication endpoints, is a 404.
const routes = [
  {path: new RegExp(`^(movie|tv|collection)/${id}$`), query: {language}},
  {path: new RegExp(`^movie/${id}/videos$`), query: {}},
  // `external_ids` finds a series' TVDB or IMDb ID for its TVmaze air times.
  {path: new RegExp(`^tv/${id}(/videos|/season/[0-9]{1,4}/videos|/external_ids)$`), query: {}},
  {path: new RegExp(`^(company|network)/${id}$`), query: {}},
  {path: /^find\/tt[0-9]{7,10}$/, query: {external_source: /^imdb_id$/}, required: ['external_source']},
  {
    path: /^discover\/(movie|tv)$/,
    query: {
      sort_by: /^popularity\.desc$/,
      include_adult: /^false$/,
      page: /^[1-9][0-9]?$/,
      with_networks: new RegExp(`^${id}$`),
      with_companies: idList,
      with_watch_providers: idList,
      watch_region: /^[A-Z]{2}$/,
      with_watch_monetization_types: /^flatrate$/,
      // The "new in the past year" lists.
      'air_date.gte': day,
      'air_date.lte': day,
      'primary_release_date.gte': day,
      'primary_release_date.lte': day,
      // The Calendar's series coming soon.
      'first_air_date.gte': day,
      'first_air_date.lte': day,
      language,
    },
    required: ['sort_by', 'include_adult', 'page'],
  },
  // Answered in blocks of TMDb's pages, as `trendingBlocks` describes.
  {
    path: /^trending\/(movie|tv)\/week$/,
    query: {block: /^[1-9][0-9]?$/},
    required: ['block'],
    cacheSeconds: trendingBlocks.cacheSeconds,
    block: true,
  },
];

// TVmaze, for the Calendar's episode air times. A lookup matches a show by
// exactly one ID. The app reads a show's seasons, then the episodes of the
// seasons it needs, which carry UTC air times: a long daily show's whole
// episode list runs to several megabytes.
const tvmazeLookup = /^lookup\/shows$/;
const tvmazeRoutes = [
  {
    path: tvmazeLookup,
    query: {thetvdb: new RegExp(`^${id}$`), imdb: /^tt[0-9]{7,10}$/},
    oneOf: ['thetvdb', 'imdb'],
    // A show's TVmaze ID doesn't change.
    cacheSeconds: 7 * 24 * 60 * 60,
  },
  // TVmaze refreshes its own answers hourly, and air times can move.
  {path: new RegExp(`^(shows/${id}/seasons|seasons/${id}/episodes)$`), query: {}, cacheSeconds: 6 * 60 * 60},
];

const services = [
  {prefix: '/3/', upstream, routes, tmdb: true},
  {prefix: '/tvmaze/', upstream: tvmazeUpstream, routes: tvmazeRoutes, tmdb: false},
];

const json = (status, body, extra = {}) => new Response(JSON.stringify(body), {
  status,
  headers: {'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extra},
});

/// The checked, sorted query string, or null when any parameter isn't one
/// this path accepts.
export function checkedQuery(route, params) {
  const entries = [...params];
  const names = new Set();
  for (const [name, value] of entries) {
    const pattern = route.query[name];
    if (!pattern || names.has(name) || !pattern.test(value)) return null;
    names.add(name);
  }
  if ((route.required ?? []).some(name => !names.has(name))) return null;
  if (route.oneOf && route.oneOf.filter(name => names.has(name)).length !== 1) return null;
  if (names.has('page') && Number(params.get('page')) > limits.maxPage) return null;
  if (names.has('block') && Number(params.get('block')) > trendingBlocks.count) return null;
  return entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`).join('&');
}

const cacheable = (body, seconds) => new Response(body, {
  status: 200,
  headers: {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': `public, max-age=${seconds}`,
    'X-Content-Type-Options': 'nosniff',
  },
});

/// The answer to send for an upstream response the app can't use, or null
/// for a usable one.
function failure(response, tmdb) {
  if (response.status === 404) return json(404, {error: 'not_found'});
  if (response.status === 429) {
    const retry = /^[0-9]{1,4}$/.test(response.headers.get('Retry-After') ?? '') ? response.headers.get('Retry-After') : '10';
    return json(429, {error: 'rate_limited'}, {'Retry-After': retry});
  }
  // A rejected token is the relay's problem, never the app's key.
  if (tmdb && (response.status === 401 || response.status === 403)) {
    console.error('upstream_auth', response.status);
    return json(503, {error: 'unavailable'}, {'Retry-After': '300'});
  }
  if (response.status !== 200 || !response.body) return json(502, {error: 'upstream_error'}, {'Retry-After': '30'});
  if (Number(response.headers.get('Content-Length')) > limits.maxBytes) return json(502, {error: 'too_large'});
  return null;
}

/// One block of the weekly trending list: its TMDb pages read here, with each
/// title cut down to the fields the app matches on. Each page's body is read
/// as soon as it arrives, because a Worker keeps only six connections open at
/// once. A block with a failed page is never cached, and an empty page ends
/// the list.
async function trendingBlock(path, block, headers, {fetcher, cache, cacheKey, ctx}) {
  const first = (block - 1) * trendingBlocks.pages + 1;
  let pages;
  try {
    pages = await Promise.all(Array.from({length: trendingBlocks.pages}, async (_, offset) => {
      const response = await fetcher(`${upstream}${path}?page=${first + offset}`,
        {headers, redirect: 'manual', signal: AbortSignal.timeout(limits.timeoutMs)});
      const failed = failure(response, true);
      if (failed) {
        await response.body?.cancel();
        return {failed};
      }
      return {results: (await response.json()).results};
    }));
  } catch {
    return json(502, {error: 'upstream_unavailable'}, {'Retry-After': '30'});
  }
  const failed = pages.find(page => page.failed)?.failed;
  if (failed) return failed;
  const results = [];
  for (const page of pages) {
    if (!Array.isArray(page.results) || page.results.length === 0) break;
    for (const title of page.results) {
      results.push(Object.fromEntries(trendingBlocks.fields.filter(field => field in title).map(field => [field, title[field]])));
    }
  }
  const answer = cacheable(JSON.stringify({results}), trendingBlocks.cacheSeconds);
  if (cache) ctx.waitUntil(cache.put(cacheKey, answer.clone()).catch(() => {}));
  return answer;
}

export async function handle(request, env, ctx, {fetcher = fetch, cache = globalThis.caches?.default} = {}) {
  const url = new URL(request.url);
  const service = services.find(candidate => url.pathname.startsWith(candidate.prefix));
  if (!service) return json(404, {error: 'not_found'});
  const path = url.pathname.slice(service.prefix.length);
  const route = service.routes.find(candidate => candidate.path.test(path));
  if (!route) return json(404, {error: 'not_found'});
  if (request.method !== 'GET') return json(405, {error: 'method_not_allowed'}, {Allow: 'GET'});
  const query = checkedQuery(route, url.searchParams);
  if (query === null) return json(400, {error: 'invalid_query'});

  // Keyed by client address only for this check; the address isn't kept.
  const client = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const {success} = await env.RATE_LIMITER.limit({key: client});
  if (!success) return json(429, {error: 'rate_limited'}, {'Retry-After': '60'});

  const target = service.upstream + path + (query ? `?${query}` : '');
  // Keyed on the relay's own normalised URL. The token is never part of the
  // key or the answer.
  const cacheKey = new Request(`${url.origin}${service.prefix}${path}${query ? `?${query}` : ''}`);
  const cached = await cache?.match(cacheKey);
  if (cached) return cached;

  if (service.tmdb && !env.TMDB_READ_TOKEN) return json(503, {error: 'unavailable'}, {'Retry-After': '300'});
  const headers = service.tmdb
    ? {Authorization: `Bearer ${env.TMDB_READ_TOKEN}`, Accept: 'application/json'}
    : {Accept: 'application/json', 'User-Agent': 'Vivid relay (+https://vividapp.co)'};
  if (route.block) return trendingBlock(path, Number(url.searchParams.get('block')), headers, {fetcher, cache, cacheKey, ctx});
  let response;
  try {
    response = await fetcher(target, {headers, redirect: 'manual', signal: AbortSignal.timeout(limits.timeoutMs)});
  } catch {
    return json(502, {error: 'upstream_unavailable'}, {'Retry-After': '30'});
  }
  const seconds = route.cacheSeconds ?? limits.cacheSeconds;
  // TVmaze answers a lookup with a redirect to the show. The show's ID is all
  // the app needs, so the redirect is never followed.
  if (!service.tmdb && tvmazeLookup.test(path) && (response.status === 301 || response.status === 302)) {
    const match = /^https:\/\/api\.tvmaze\.com\/shows\/([1-9][0-9]{0,9})$/.exec(response.headers.get('Location') ?? '');
    if (!match) return json(502, {error: 'upstream_error'}, {'Retry-After': '30'});
    const answer = cacheable(JSON.stringify({id: Number(match[1])}), seconds);
    if (cache) ctx.waitUntil(cache.put(cacheKey, answer.clone()).catch(() => {}));
    return answer;
  }
  const failed = failure(response, service.tmdb);
  if (failed) return failed;

  // The body streams through unparsed, which keeps CPU time tiny.
  const answer = cacheable(response.body, seconds);
  if (cache) ctx.waitUntil(cache.put(cacheKey, answer.clone()).catch(() => {}));
  return answer;
}

export default {fetch: (request, env, ctx) => handle(request, env, ctx)};
