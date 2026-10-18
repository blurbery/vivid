// Answers Vivid's TMDb lookups with Vivid's own TMDb read access token, so
// people don't need a TMDb key of their own. Only the requests the app makes
// are accepted, and answers are cached at the edge for a day.
//
// GET /3/<TMDb path>?<query>  the same path and query the app would send to TMDb
//
// The client IP is used only as a rate-limit key. It isn't stored, logged or
// sent to TMDb, and nothing from the client's request is forwarded except the
// path and the checked query.

const upstream = 'https://api.themoviedb.org/3/';

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

const id = '[1-9][0-9]{0,9}';
const idList = new RegExp(`^${id}(\\|${id}){0,19}$`);
const day = /^20[0-9]{2}-[01][0-9]-[0-3][0-9]$/;

// Every path the app requests, with the query each one may carry. Anything
// else, including TMDb's own account and authentication endpoints, is a 404.
const routes = [
  {path: new RegExp(`^movie/${id}(/videos)?$`), query: {}},
  {path: new RegExp(`^tv/${id}(/videos|/season/[0-9]{1,4}/videos)?$`), query: {}},
  {path: new RegExp(`^(collection|company|network)/${id}$`), query: {}},
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
    },
    required: ['sort_by', 'include_adult', 'page'],
  },
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
  if (names.has('page') && Number(params.get('page')) > limits.maxPage) return null;
  return entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
    .map(([name, value]) => `${encodeURIComponent(name)}=${encodeURIComponent(value)}`).join('&');
}

export async function handle(request, env, ctx, {fetcher = fetch, cache = globalThis.caches?.default} = {}) {
  const url = new URL(request.url);
  if (!url.pathname.startsWith('/3/')) return json(404, {error: 'not_found'});
  const path = url.pathname.slice(3);
  const route = routes.find(candidate => candidate.path.test(path));
  if (!route) return json(404, {error: 'not_found'});
  if (request.method !== 'GET') return json(405, {error: 'method_not_allowed'}, {Allow: 'GET'});
  const query = checkedQuery(route, url.searchParams);
  if (query === null) return json(400, {error: 'invalid_query'});

  // Keyed by client address only for this check; the address isn't kept.
  const client = request.headers.get('CF-Connecting-IP') ?? 'unknown';
  const {success} = await env.RATE_LIMITER.limit({key: client});
  if (!success) return json(429, {error: 'rate_limited'}, {'Retry-After': '60'});

  const target = upstream + path + (query ? `?${query}` : '');
  // Keyed on the relay's own normalised URL. The token is never part of the
  // key or the answer.
  const cacheKey = new Request(`${url.origin}/3/${path}${query ? `?${query}` : ''}`);
  const cached = await cache?.match(cacheKey);
  if (cached) return cached;

  if (!env.TMDB_READ_TOKEN) return json(503, {error: 'unavailable'}, {'Retry-After': '300'});
  let response;
  try {
    response = await fetcher(target, {
      headers: {Authorization: `Bearer ${env.TMDB_READ_TOKEN}`, Accept: 'application/json'},
      redirect: 'manual',
      signal: AbortSignal.timeout(limits.timeoutMs),
    });
  } catch {
    return json(502, {error: 'upstream_unavailable'}, {'Retry-After': '30'});
  }
  if (response.status === 404) return json(404, {error: 'not_found'});
  if (response.status === 429) {
    const retry = /^[0-9]{1,4}$/.test(response.headers.get('Retry-After') ?? '') ? response.headers.get('Retry-After') : '10';
    return json(429, {error: 'rate_limited'}, {'Retry-After': retry});
  }
  // A rejected token is the relay's problem, never the app's key.
  if (response.status === 401 || response.status === 403) {
    console.error('upstream_auth', response.status);
    return json(503, {error: 'unavailable'}, {'Retry-After': '300'});
  }
  if (response.status !== 200 || !response.body) return json(502, {error: 'upstream_error'}, {'Retry-After': '30'});
  const length = Number(response.headers.get('Content-Length'));
  if (length > limits.maxBytes) return json(502, {error: 'too_large'});

  // The body streams through unparsed, which keeps CPU time tiny.
  const answer = new Response(response.body, {
    status: 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': `public, max-age=${limits.cacheSeconds}`,
      'X-Content-Type-Options': 'nosniff',
    },
  });
  if (cache) ctx.waitUntil(cache.put(cacheKey, answer.clone()).catch(() => {}));
  return answer;
}

export default {fetch: (request, env, ctx) => handle(request, env, ctx)};
