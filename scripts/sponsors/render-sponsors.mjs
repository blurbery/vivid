#!/usr/bin/env node
// Renders the README sponsors image (sponsors.svg) from blurbery's GitHub Sponsors.
//
// Usage:
//   SPONSORS_TOKEN=<classic token with read:user> node scripts/sponsors/render-sponsors.mjs --out sponsors.svg
//   node scripts/sponsors/render-sponsors.mjs --fixture sponsors.json --out sponsors.svg
//
// Only public sponsorships are shown. Active sponsors on a monthly tier of $25 or more are
// Gold sponsors, shown with their name; other active sponsors, including one-time sponsors,
// are Silver sponsors with a smaller avatar, and sponsors whose sponsorship has ended are
// listed as past sponsors. Avatars are embedded as
// data URIs because GitHub won't load external images inside an SVG.

import { readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const MAINTAINER = process.env.SPONSORS_LOGIN || 'blurbery';
const GOLD_MIN_DOLLARS = Number(process.env.SPONSORS_GOLD_MIN || 25);

// Names to show instead of a sponsor's GitHub profile name (or login, when the profile has no name).
const DISPLAY_NAMES = {
  xrandallx1: 'Randall',
};

const WIDTH = 800;
const FONT = "Geist, -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif";

const TIERS = [
  { key: 'gold', title: 'Gold sponsors', avatar: 120, gap: 48, slot: 168, names: true, metal: 'gold' },
  { key: 'silver', title: 'Silver sponsors', avatar: 64, gap: 20, slot: 64, names: false, metal: 'silver' },
  { key: 'past', title: 'Past sponsors', avatar: 40, gap: 12, slot: 40, names: false, muted: true, metal: 'silver' },
];

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--out' || key === '--fixture') args[key.slice(2)] = argv[++i];
  }
  if (!args.out) throw new Error('Pass --out <file>.');
  return args;
}

const QUERY = `query($login: String!, $cursor: String) {
  user(login: $login) {
    sponsorshipsAsMaintainer(first: 100, after: $cursor, activeOnly: false, includePrivate: false) {
      pageInfo { hasNextPage endCursor }
      nodes {
        isActive
        isOneTimePayment
        privacyLevel
        createdAt
        tier { monthlyPriceInDollars isOneTime }
        sponsorEntity {
          __typename
          ... on User { login name avatarUrl(size: 240) }
          ... on Organization { login name avatarUrl(size: 240) }
        }
      }
    }
  }
}`;

async function fetchSponsorships(token) {
  const nodes = [];
  let cursor = null;
  do {
    const response = await fetch('https://api.github.com/graphql', {
      method: 'POST',
      headers: { authorization: `bearer ${token}`, 'content-type': 'application/json', 'user-agent': 'vivid-sponsors' },
      body: JSON.stringify({ query: QUERY, variables: { login: MAINTAINER, cursor } }),
    });
    const body = await response.json();
    if (!response.ok || body.errors) {
      throw new Error(`GitHub GraphQL request failed: ${JSON.stringify(body.errors || body.message || response.status)}`);
    }
    const page = body.data.user.sponsorshipsAsMaintainer;
    nodes.push(...page.nodes);
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (cursor);
  return nodes;
}

export function groupSponsors(nodes) {
  const groups = { gold: [], silver: [], past: [] };
  const seen = new Set();
  const usable = nodes.filter((n) => n.sponsorEntity && n.sponsorEntity.login && n.privacyLevel !== 'PRIVATE');
  // Longest-standing sponsors first.
  usable.sort((a, b) => String(a.createdAt).localeCompare(String(b.createdAt)));

  // A sponsor with more than one active sponsorship is placed by their highest monthly tier.
  // One-time payments count as Silver whatever their size.
  const monthlyDollars = (n) => (n.tier && !n.tier.isOneTime && !n.isOneTimePayment ? n.tier.monthlyPriceInDollars : 0);
  const best = new Map();
  for (const node of usable.filter((n) => n.isActive)) {
    const login = node.sponsorEntity.login.toLowerCase();
    const current = best.get(login);
    if (!current || monthlyDollars(node) > current.monthly) {
      best.set(login, { entity: node.sponsorEntity, monthly: monthlyDollars(node) });
    }
  }
  for (const [login, { entity, monthly }] of best) {
    seen.add(login);
    (monthly >= GOLD_MIN_DOLLARS ? groups.gold : groups.silver).push(entity);
  }
  for (const node of usable.filter((n) => !n.isActive)) {
    const login = node.sponsorEntity.login.toLowerCase();
    if (seen.has(login)) continue;
    seen.add(login);
    groups.past.push(node.sponsorEntity);
  }
  return groups;
}

async function embedAvatar(url) {
  const response = await fetch(url, { headers: { 'user-agent': 'vivid-sponsors' } });
  if (!response.ok) throw new Error(`Avatar download failed (${response.status}): ${url}`);
  const type = (response.headers.get('content-type') || 'image/png').split(';')[0];
  const data = Buffer.from(await response.arrayBuffer()).toString('base64');
  return `data:${type};base64,${data}`;
}

const escapeXml = (value) => String(value)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
  .replace(/"/g, '&quot;').replace(/'/g, '&apos;');

const displayName = (person) => DISPLAY_NAMES[person.login.toLowerCase()] || person.name || person.login;

const truncate = (value, max) => (value.length > max ? `${value.slice(0, max - 1)}…` : value);

function layoutRows(count, slot, gap) {
  const perRow = Math.max(1, Math.floor((WIDTH - 80 + gap) / (slot + gap)));
  const rows = [];
  for (let start = 0; start < count; start += perRow) rows.push(Math.min(perRow, count - start));
  return rows;
}

export function renderSvg(groups, avatars) {
  const parts = [];
  const defs = [];
  let y = 56;
  let clip = 0;
  const sections = TIERS.filter((tier) => groups[tier.key].length > 0);

  sections.forEach((tier, index) => {
    if (index > 0) y += 44;
    parts.push(`<text x="${WIDTH / 2}" y="${y}" text-anchor="middle" font-family="${FONT}" font-size="14" font-weight="600" letter-spacing="4.5" fill="url(#${tier.metal}Text)">${escapeXml(tier.title.toUpperCase())}</text>`);
    y += 30;

    const people = groups[tier.key];
    const rows = layoutRows(people.length, tier.slot, tier.gap);
    const rowHeight = tier.avatar + (tier.names ? 62 : 0);
    let i = 0;
    rows.forEach((inRow, rowIndex) => {
      const rowWidth = inRow * tier.slot + (inRow - 1) * tier.gap;
      let x = (WIDTH - rowWidth) / 2;
      const top = y + rowIndex * (rowHeight + tier.gap);
      for (let n = 0; n < inRow; n += 1, i += 1) {
        const person = people[i];
        const r = tier.avatar / 2;
        const cx = x + tier.slot / 2;
        const cy = top + r;
        const id = `a${clip++}`;
        defs.push(`<clipPath id="${id}"><circle cx="${cx}" cy="${cy}" r="${r}"/></clipPath>`);
        const label = displayName(person);
        parts.push(`<g${tier.muted ? ' opacity="0.72" filter="url(#muted)"' : ''}>`
          + `<title>${escapeXml(label)}</title>`
          + `<circle cx="${cx}" cy="${cy}" r="${r}" fill="#252525"/>`
          + `<image href="${avatars.get(person.login)}" x="${cx - r}" y="${cy - r}" width="${tier.avatar}" height="${tier.avatar}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${id})"/>`
          + `<circle cx="${cx}" cy="${cy}" r="${r + (tier.names ? 3 : 1.5)}" fill="none" stroke="url(#${tier.metal}Ring)" stroke-width="${tier.names ? 2.5 : 1.5}"/>`
          + '</g>');
        if (tier.names) {
          const name = truncate(displayName(person), 20);
          parts.push(`<text x="${cx}" y="${cy + r + 34}" text-anchor="middle" font-family="${FONT}" font-size="18" font-weight="600" fill="#f5f5f7">${escapeXml(name)}</text>`);
          parts.push(`<text x="${cx}" y="${cy + r + 55}" text-anchor="middle" font-family="${FONT}" font-size="13" fill="#a1a1a8">@${escapeXml(truncate(person.login, 22))}</text>`);
        }
        x += tier.slot + tier.gap;
      }
    });
    y += rows.length * rowHeight + (rows.length - 1) * tier.gap;
  });

  if (sections.length === 0) {
    parts.push(`<text x="${WIDTH / 2}" y="${y + 8}" text-anchor="middle" font-family="${FONT}" font-size="14" font-weight="600" letter-spacing="4.5" fill="url(#silverText)">SPONSORS</text>`);
    parts.push(`<text x="${WIDTH / 2}" y="${y + 44}" text-anchor="middle" font-family="${FONT}" font-size="16" fill="#a1a1a8">Be the first to sponsor Vivid.</text>`);
    y += 52;
  }

  const height = Math.round(y + 52);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${height}" viewBox="0 0 ${WIDTH} ${height}" role="img" aria-label="Vivid's sponsors">
<defs>
<linearGradient id="card" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#191919"/><stop offset="1" stop-color="#101010"/></linearGradient>
<radialGradient id="glow" cx="0.5" cy="0" r="0.75"><stop offset="0" stop-color="#ffffff" stop-opacity="0.07"/><stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>
<linearGradient id="silverText" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#e8e7e8"/><stop offset="1" stop-color="#9a9a9a"/></linearGradient>
<linearGradient id="goldText" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#f6e3a8"/><stop offset="1" stop-color="#c9a04e"/></linearGradient>
<linearGradient id="goldRing" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f6e3a8"/><stop offset="0.5" stop-color="#d4af5f"/><stop offset="1" stop-color="#8a6a2c"/></linearGradient>
<linearGradient id="silverRing" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e8e7e8"/><stop offset="0.5" stop-color="#9a9a9a"/><stop offset="1" stop-color="#6c6b6b"/></linearGradient>
<filter id="muted"><feColorMatrix type="saturate" values="0.25"/></filter>
${defs.join('\n')}
</defs>
<rect x="0.5" y="0.5" width="${WIDTH - 1}" height="${height - 1}" rx="20" fill="url(#card)" stroke="#ffffff" stroke-opacity="0.09"/>
<rect x="0.5" y="0.5" width="${WIDTH - 1}" height="${height - 1}" rx="20" fill="url(#glow)"/>
${parts.join('\n')}
</svg>
`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let nodes;
  if (args.fixture) {
    nodes = JSON.parse(await readFile(args.fixture, 'utf8'));
  } else {
    const token = process.env.SPONSORS_TOKEN;
    if (!token) throw new Error('Set SPONSORS_TOKEN to a classic GitHub token with the read:user scope.');
    nodes = await fetchSponsorships(token);
  }
  const groups = groupSponsors(nodes);
  const avatars = new Map();
  for (const person of [...groups.gold, ...groups.silver, ...groups.past]) {
    avatars.set(person.login, await embedAvatar(person.avatarUrl));
  }
  await writeFile(args.out, renderSvg(groups, avatars));
  console.log(`Wrote ${args.out}: ${groups.gold.length} gold, ${groups.silver.length} silver, ${groups.past.length} past.`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
