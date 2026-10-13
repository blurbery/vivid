import {readFile, readdir, mkdir, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {join, extname} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = fileURLToPath(new URL('.', import.meta.url));
const publicDir = join(root, 'public');
const output = join(root, '.build');
const types = {'.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.ico':'image/x-icon','.png':'image/png','.svg':'image/svg+xml','.ttf':'font/ttf','.txt':'text/plain; charset=utf-8','.xml':'application/xml; charset=utf-8'};
const assets = {};
async function visit(directory, prefix = '') {
  for (const entry of await readdir(directory, {withFileTypes:true})) {
    const path = join(directory,entry.name);
    if (entry.isDirectory()) await visit(path,`${prefix}/${entry.name}`);
    else if (entry.isFile()) {
      const body = await readFile(path);
      const type = types[extname(entry.name)];
      if (!type) throw new Error(`Unsupported public asset: ${entry.name}`);
      assets[`${prefix}/${entry.name}`] = {type,etag:`"${createHash('sha256').update(body).digest('hex')}"`,base64:body.toString('base64')};
    }
  }
}
await visit(publicDir);
// /licences is generated from the app's bundled licence files, so the site
// shows exactly what Settings → About → Open Source Licences shows.
const licencesDir = join(root, '..', 'iosApp', 'Resources', 'OpenSourceLicenses');
const manifest = JSON.parse(await readFile(join(licencesDir, 'licences.json'), 'utf8'));
const escape = text => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const licenceFile = async name => (await readFile(join(licencesDir, name), 'utf8')).replace(/\r\n/g, '\n').replace(/^\n+|\s+$/g, '');
const texts = new Map(manifest.texts.map(text => [text.id, text]));
const markerLink = text => `<a href="#text-${text.id}">${escape(manifest.marker.replace('{title}', text.title))}</a>`;
let body = '<h1>Open Source Licences</h1>\n    <p>Vivid is built with the open source software below. These are the same notices and licence texts the app shows in Settings → About → Open Source Licences. Each build records the source commit it was made from in Settings → About, and Vivid’s complete source, build instructions and third-party notices are on <a href="https://github.com/blurbery/vivid" target="_blank" rel="noopener noreferrer">GitHub</a>.</p>\n';
const label = entry => escape([[entry.name, entry.version].filter(Boolean).join(' '), entry.licence].filter(Boolean).join(' · '));
body += `    <p>${manifest.entries.map(entry => `<a href="#${entry.id}">${label(entry)}</a>`).join('<br>')}<br>${manifest.texts.map(text => `<a href="#text-${text.id}">${escape(text.title)}</a>`).join('<br>')}</p>\n`;
for (const entry of manifest.entries) {
  const shared = entry.text ? texts.get(entry.text) : undefined;
  if (entry.text && !shared) throw new Error(`Unknown licence text: ${entry.text}`);
  body += `    <h2 id="${entry.id}">${escape(entry.name)}</h2>`;
  const detail = [entry.version, entry.licence].filter(Boolean).join(' · ');
  if (detail) body += `<p class="updated">${escape(detail)}</p>`;
  if (entry.notice) {
    let notice = escape(await licenceFile(entry.notice));
    if (shared) notice = notice.replace(escape(manifest.marker.replace('{title}', shared.title)), markerLink(shared));
    body += `<pre>${notice}</pre>`;
  } else if (shared) {
    body += `<p>${markerLink(shared)}</p>`;
  }
  body += '\n';
}
for (const text of manifest.texts) {
  body += `    <h2 id="text-${text.id}">${escape(text.title)}</h2><pre>${escape(await licenceFile(text.file))}</pre>\n`;
}
const template = await readFile(join(publicDir, 'support.html'), 'utf8');
const licencesPage = template
  .replace(/<title>[^<]*<\/title>/, '<title>Open Source Licences · Vivid</title>')
  .replace(/<meta name="description" content="[^"]*">/, '<meta name="description" content="The open source software in Vivid and its licences.">')
  .replace(/<link rel="canonical" href="[^"]*">/, '<link rel="canonical" href="https://vividapp.co/licences">')
  .replace(/<main class="prose">[\s\S]*<\/main>/, () => `<main class="prose">${body}  </main>`);
if (!licencesPage.includes('https://vividapp.co/licences') || !licencesPage.includes('Open Source Licences · Vivid')) throw new Error('The licences page template did not match support.html.');
const licencesBytes = Buffer.from(licencesPage);
assets['/licences.html'] = {type:types['.html'],etag:`"${createHash('sha256').update(licencesBytes).digest('hex')}"`,base64:licencesBytes.toString('base64')};
// Give saved-icon caches a new path when artwork changes; retain root fallbacks.
for (const name of ['favicon.png', 'favicon.svg', 'apple-touch-icon.png']) {
  const asset = assets[`/${name}`];
  const version = asset.etag.slice(1, 11);
  const extension = extname(name);
  assets[`/${name.slice(0, -extension.length)}-${version}${extension}`] = asset;
}
await mkdir(output,{recursive:true});
// Immutable site bytes shared across requests; no request data is retained.
const module = `const encoded=${JSON.stringify(assets)};\nexport default Object.freeze(Object.fromEntries(Object.entries(encoded).map(([path,a])=>[path,Object.freeze({type:a.type,etag:a.etag,body:Uint8Array.from(atob(a.base64),c=>c.charCodeAt(0))})])));\n`;
await writeFile(join(output,'assets.mjs'),module);
await writeFile(join(output,'worker.mjs'),await readFile(join(root,'worker.mjs')));
console.log(`Built ${Object.keys(assets).length} public assets. Apple app files are excluded.`);
