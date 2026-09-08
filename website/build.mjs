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
// Give saved-icon caches a new path when artwork changes; retain root fallbacks.
for (const name of ['favicon.png', 'apple-touch-icon.png']) {
  const asset = assets[`/${name}`];
  const version = asset.etag.slice(1, 11);
  assets[`/${name.replace('.png', `-${version}.png`)}`] = asset;
}
await mkdir(output,{recursive:true});
// Immutable site bytes shared across requests; no request data is retained.
const module = `const encoded=${JSON.stringify(assets)};\nexport default Object.freeze(Object.fromEntries(Object.entries(encoded).map(([path,a])=>[path,Object.freeze({type:a.type,etag:a.etag,body:Uint8Array.from(atob(a.base64),c=>c.charCodeAt(0))})])));\n`;
await writeFile(join(output,'assets.mjs'),module);
await writeFile(join(output,'worker.mjs'),await readFile(join(root,'worker.mjs')));
console.log(`Built ${Object.keys(assets).length} public assets. Apple app files are excluded.`);
