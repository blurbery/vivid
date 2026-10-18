<p align="center">
  <img src="branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">TMDb Relay</h1>
<p align="center">How Vivid shows TMDb trailers, ratings and Studios & Networks without a key of your own.</p>
<p align="center"><a href="../README.md">Home</a> · <a href="README.md">Documentation</a> · <a href="../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses TMDb for trailers, the TMDb rating, movie collection rows, Studios & Networks and IMDb-to-TMDb lookups on Emby and Jellyfin. A TMDb key can't be kept secret inside an app, so Vivid doesn't ship one. Instead, when someone hasn't added a key of their own, the app sends its TMDb requests to a small Cloudflare Worker at `tmdb.vividapp.co`. The Worker adds Vivid's TMDb read access token, forwards the request to `api.themoviedb.org` and caches the answer at the edge for a day. Someone who adds their own key in **Settings > Plugins > TMDb** goes straight to TMDb instead, exactly as before, and the relay sees none of their requests.

The source is in [`tmdb-relay/`](../tmdb-relay). It is separate from the website and the [diagnostics relay](diagnostics-relay.md).

## What it accepts

Only `GET /3/<path>` for the paths the app uses, each with only the query the app sends:

| Path | Query | Used for |
| --- | --- | --- |
| `movie/{id}`, `tv/{id}` | none | Ratings, collection membership, a series' seasons |
| `movie/{id}/videos`, `tv/{id}/videos`, `tv/{id}/season/{n}/videos` | none | Trailers |
| `collection/{id}` | none | Collection rows |
| `company/{id}`, `network/{id}` | none | Studios & Networks logos |
| `find/tt…` | `external_source=imdb_id` | TMDb IDs for Emby and Jellyfin titles that only have an IMDb ID |
| `discover/movie`, `discover/tv` | `sort_by=popularity.desc`, `include_adult=false`, `page` (1 to 10), and the studio, network, streaming provider, region and date filters Studios & Networks sends | Studios & Networks lists |

Anything else gets `404`, including TMDb's account and authentication endpoints, so the relay can't be used as a general TMDb gateway. An unknown or repeated query parameter, or a value in the wrong format, gets `400`. Other methods get `405`. The query is sorted before it's used, so the same lookup always shares one cache entry.

Nothing from the client's request reaches TMDb except the path and the checked query: no headers, cookies, `api_key` or address. Answers go back with only a content type and cache header, never TMDb's own headers, and the token is never part of an answer or a cache key.

| Response | Meaning | What the app does |
| --- | --- | --- |
| `200` | TMDb's answer, possibly from the cache | Uses it |
| `400`, `404`, `405` | Not a request the app makes, or no such title on TMDb | Treats it as unavailable |
| `429` | More than 1,200 requests a minute from one address, or TMDb's own rate limit | Treats it as unavailable; Studios & Networks retries once after a second |
| `502` | TMDb couldn't be reached, answered with an error or sent something too large | Treats it as unavailable |
| `503` | The token is missing or TMDb rejected it | Treats it as unavailable. It never reports a key problem, because the person didn't supply one |

Studios & Networks is the busiest caller: a full refresh reads up to five pages of four lists for each of 24 brands, about 500 requests, once a day per device and profile. The app keeps at most 12 TMDb requests in flight, and the per-address limit leaves room for two devices refreshing at once.

## Privacy

The client's address is used only as the rate-limit key. It isn't stored, logged or sent to TMDb. Workers observability is off, so request details aren't retained. Answers are cached by Cloudflare for up to a day, keyed only by the TMDb path and query. TMDb's terms allow caching for up to six months.

The relay sees which TMDb or IMDb IDs are looked up and which Studios & Networks lists are read. Libraries, watch history, account details and media-server addresses never reach it: Studios & Networks matches TMDb's lists with the library on the device. The in-app Privacy Policy and the [website privacy policy](../website/public/privacy.html) describe this for users.

> [!IMPORTANT]
> The relay must be deployed, with the token set, and the privacy policy must be live, before an app build that uses the relay ships. Without the relay, TMDb features in that build show nothing unless the person adds their own key.

## Setup

Run these from `tmdb-relay/` with Wrangler logged in to the account that holds vividapp.co.

1. Store Vivid's TMDb **API Read Access Token** (from the Vivid TMDb account's [API settings](https://www.themoviedb.org/settings/api)) as a secret. Wrangler asks for the value; paste it there, never into a file or chat:
   ```sh
   npx wrangler secret put TMDB_READ_TOKEN
   ```
2. Deploy. This also creates the `tmdb.vividapp.co` custom domain. The Cache API only works on a custom domain, so `workers_dev` stays off:
   ```sh
   npx wrangler deploy
   ```
3. Check a lookup, a cache hit and a refusal. The second request should be quicker, and none of the output should contain the token:
   ```sh
   curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://tmdb.vividapp.co/3/movie/603
   curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://tmdb.vividapp.co/3/movie/603
   curl -sS -o /dev/null -w '%{http_code}\n' https://tmdb.vividapp.co/3/search/movie?query=matrix
   ```
   Expect `200`, `200` and `404`.

To change the token, run `npx wrangler secret put TMDB_READ_TOKEN` again with the new value. The app needs no update.

### Plan limits

The Workers free plan allows 100,000 requests a day, resetting at midnight UTC. Past that, Cloudflare answers `1027` errors until the reset, and TMDb features show nothing for anyone without their own key. Each device's Studios & Networks refresh uses about 500 requests a day, plus a few for each movie or series page opened, so the free plan suits a few hundred active devices a day. Workers Paid includes 10 million requests a month.

## Tests

Run the tests from the repository root. They use Node's built-in test runner, so they need Node 24.10 or later but no installed packages:

```sh
npm run test:relay
```

That runs the diagnostics relay's tests too. The PR checks workflow runs them on every pull request that changes `tmdb-relay/`, and its Docs check fails one that changes the relay, apart from its tests, unless it also updates this guide (and, when `worker.mjs` changes, the privacy policy and the in-app privacy text that follows it), or blurbery adds the `docs-not-needed` label. No workflow deploys the relay, so run them by hand again before each `npx wrangler deploy`. They cover every accepted path, refused paths and methods, query checks (including the date filters and page limits), query order sharing one cache entry, rate limiting, that nothing from the client is forwarded and the token never comes back, TMDb's error answers, an unreachable TMDb, a missing token and oversized answers. `npx wrangler deploy --dry-run` checks the configuration without deploying.

The app side is covered by `TMDbRelayTests` in `iosApp/Tests/`: without a key, requests go to the relay with no credential; a key goes only to TMDb.
