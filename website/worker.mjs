import assets from './assets.mjs';

const security = Object.freeze({
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; media-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'",
  'Strict-Transport-Security': 'max-age=31536000',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
});

// Pages served at their path without the .html extension.
const pages = Object.freeze(['/privacy', '/brand', '/support', '/licences', '/source']);

// /source?commit=<40 hex digits> offers the source downloads for the build
// made from that commit, which Settings > About links to. Only a full commit
// hash is put into a link; anything else gets the page that points to the
// releases instead.
const commitPattern = /^[0-9a-f]{40}$/i;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
function sourcePage(asset, params) {
  const value = params.get('commit');
  const commit = value && commitPattern.test(value) ? value.toLowerCase() : null;
  const unused = commit ? /[ \t]*<!--source:none-->[\s\S]*?<!--\/source:none-->\n?/ : /[ \t]*<!--source:commit-->[\s\S]*?<!--\/source:commit-->\n?/;
  const html = decoder.decode(asset.body)
    .replace(unused, '')
    .replace(/[ \t]*<!--\/?source:(?:commit|none)-->\n?/g, '')
    .replaceAll('{{commit}}', commit ?? '');
  return {type: asset.type, etag: `"${asset.etag.slice(1, 17)}-${commit ?? 'none'}"`, body: encoder.encode(html)};
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const headers = new Headers(security);
    if (url.hostname === 'www.vividapp.co' || url.protocol === 'http:') {
      url.protocol = 'https:';
      if (url.hostname === 'www.vividapp.co') url.hostname = 'vividapp.co';
      headers.set('Location', url.href);
      return new Response(null, {status:308, headers});
    }
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      headers.set('Allow', 'GET, HEAD');
      headers.set('Content-Type', 'text/plain; charset=utf-8');
      return new Response('Method not allowed', {status:405, headers});
    }
    // Screenshots and recordings come from Workers static assets. Safari only
    // plays video that answers range requests, so if the assets layer returns
    // the whole file for one, the Worker slices out the requested bytes.
    if (url.pathname.startsWith('/media/')) {
      const media = await env.ASSETS.fetch(request);
      const range = request.method === 'GET' && media.status === 200 ? /^bytes=(\d*)-(\d*)$/.exec(request.headers.get('Range')?.trim() ?? '') : null;
      let response;
      if (!range || !(range[1] || range[2])) {
        response = new Response(media.body, media);
      } else {
        const body = new Uint8Array(await media.arrayBuffer());
        const start = range[1] ? Number(range[1]) : Math.max(0, body.length - Number(range[2]));
        const end = range[1] && range[2] ? Math.min(Number(range[2]), body.length - 1) : body.length - 1;
        if (start > end) {
          response = new Response(null, {status:416, headers:{'Content-Range':`bytes */${body.length}`}});
        } else {
          response = new Response(body.slice(start, end + 1), {status:206, headers:media.headers});
          response.headers.set('Content-Range', `bytes ${start}-${end}/${body.length}`);
          response.headers.set('Content-Length', String(end - start + 1));
        }
      }
      response.headers.set('Accept-Ranges', 'bytes');
      for (const [name, value] of Object.entries(security)) response.headers.set(name, value);
      // A 304 keeps the policy of the file it revalidates; only errors skip the cache.
      if ([200, 206, 304].includes(response.status)) response.headers.set('Cache-Control', url.searchParams.has('v') ? 'public, max-age=31536000, immutable' : 'public, max-age=3600');
      else response.headers.set('Cache-Control', 'no-store');
      return response;
    }
    if (url.pathname === '/index.html') {
      headers.set('Location', '/');
      return new Response(null, {status:308, headers});
    }
    const page = url.pathname.replace(/(\.html|\/)$/, '');
    if (page !== url.pathname && pages.includes(page)) {
      headers.set('Location', page + url.search);
      return new Response(null, {status:308, headers});
    }
    const path = url.pathname === '/' ? '/index.html' : pages.includes(url.pathname) ? `${url.pathname}.html` : url.pathname;
    const stored = Object.hasOwn(assets, path) ? assets[path] : undefined;
    const asset = stored && path === '/source.html' ? sourcePage(stored, url.searchParams) : stored;
    if (!asset) {
      headers.set('Content-Type', 'text/html; charset=utf-8');
      headers.set('Cache-Control', 'no-store');
      const html = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Page not found · Vivid</title><link rel="stylesheet" href="/styles.css"><main class="prose"><h1>Page not found.</h1><p>This page is not here. <a href="/">Back to Vivid</a>.</p></main></html>';
      return new Response(request.method === 'HEAD' ? null : html, {status:404, headers});
    }
    headers.set('Content-Type', asset.type);
    headers.set('Cache-Control', asset.type.startsWith('text/html') ? 'public, max-age=0, must-revalidate' : 'public, max-age=3600');
    headers.set('ETag', asset.etag);
    if (request.headers.get('If-None-Match')?.split(',').some(tag => tag.trim().replace(/^W\//, '') === asset.etag || tag.trim() === '*')) {
      return new Response(null, {status:304, headers});
    }
    return new Response(request.method === 'HEAD' ? null : asset.body, {headers});
  }
};
