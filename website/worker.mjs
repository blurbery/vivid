import assets from './assets.mjs';

const security = Object.freeze({
  'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'",
  'Strict-Transport-Security': 'max-age=31536000',
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=(), payment=(), usb=()',
});

export default {
  fetch(request) {
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
    if (url.pathname === '/index.html' || url.pathname === '/privacy.html' || url.pathname === '/privacy/' || url.pathname === '/brand.html' || url.pathname === '/brand/') {
      headers.set('Location', url.pathname === '/index.html' ? '/' : url.pathname.startsWith('/brand') ? '/brand' : '/privacy');
      return new Response(null, {status:308, headers});
    }
    const path = url.pathname === '/' ? '/index.html' : url.pathname === '/privacy' ? '/privacy.html' : url.pathname === '/brand' ? '/brand.html' : url.pathname;
    const asset = Object.hasOwn(assets, path) ? assets[path] : undefined;
    if (!asset) {
      headers.set('Content-Type', 'text/html; charset=utf-8');
      headers.set('Cache-Control', 'no-store');
      const html = '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Page not found — Vivid</title><link rel="stylesheet" href="/styles.css"><main class="prose"><h1>Page not found.</h1><p>This page is not here. <a href="/">Back to Vivid</a>.</p></main></html>';
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
