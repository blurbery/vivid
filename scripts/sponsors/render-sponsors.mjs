#!/usr/bin/env node
// Renders the README sponsors image (sponsors.svg) from blurbery's GitHub Sponsors.
//
// Usage:
//   SPONSORS_TOKEN=<classic token with read:user> node scripts/sponsors/render-sponsors.mjs --out sponsors.svg
//   node scripts/sponsors/render-sponsors.mjs --fixture sponsors.json --out sponsors.svg
//
// Only public sponsorships are shown. Active sponsors on a monthly tier of $25 or more are
// Gold sponsors, with a large avatar and their name; other active sponsors, including one-time
// sponsors, are Silver sponsors, with a smaller avatar and their name; and sponsors whose
// sponsorship has ended are listed as past sponsors, avatar only. Avatars are embedded as
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
const FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif";
const PROFILE = 'https://github.com/';

// Laid out like sponsorkit's images: a transparent background and mid-grey text, so it reads
// on GitHub's light and dark themes, with a centred title and a row of round avatars per tier.
const TIERS = [
  { key: 'gold', title: 'Gold Sponsors', avatar: 90, slot: 120, gap: 10, names: true, nameMax: 16, ring: 'gold' },
  { key: 'silver', title: 'Silver Sponsors', avatar: 60, slot: 90, gap: 10, names: true, nameMax: 13, ring: 'silver' },
  { key: 'past', title: 'Past Sponsors', avatar: 35, slot: 35, gap: 3, names: false, muted: true },
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

// Fine-grained tokens can't read tiers at all, so SPONSORS_TOKEN must be a classic token.
// isActive, createdAt and privacyLevel need the read:user scope, so the script asks for active
// and all sponsorships separately and relies on includePrivate: false and the CREATED_AT order
// instead. isOneTimePayment needs read:user too, but it's the only way to tell a one-time payment
// made against a monthly tier, so the script asks for it and only drops it when the token lacks
// read:user (then such a payment can't be told apart and counts by its tier).
const query = (withPayment) => `query($login: String!, $cursor: String, $activeOnly: Boolean!) {
  user(login: $login) {
    sponsorshipsAsMaintainer(first: 100, after: $cursor, activeOnly: $activeOnly, includePrivate: false,
      orderBy: { field: CREATED_AT, direction: ASC }) {
      pageInfo { hasNextPage endCursor }
      nodes {
        ${withPayment ? 'isOneTimePayment' : ''}
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

class MissingScopeError extends Error {}

async function fetchBoth(token, withPayment) {
  const active = await fetchPage(token, true, withPayment);
  const all = await fetchPage(token, false, withPayment);
  return { active, all };
}

async function fetchSponsorships(token) {
  let result;
  try {
    result = await fetchBoth(token, true);
  } catch (error) {
    if (!(error instanceof MissingScopeError)) throw error;
    console.warn('::warning::SPONSORS_TOKEN has no read:user scope, so one-time payments made against a monthly tier count by their tier.');
    result = await fetchBoth(token, false);
  }
  const { active, all } = result;
  const activeLogins = new Set(active.map((n) => n.sponsorEntity?.login?.toLowerCase()));
  return [
    ...active.map((n) => ({ ...n, isActive: true })),
    ...all
      .filter((n) => !activeLogins.has(n.sponsorEntity?.login?.toLowerCase()))
      .map((n) => ({ ...n, isActive: false })),
  ];
}

async function fetchPage(token, activeOnly, withPayment) {
  const nodes = [];
  let cursor = null;
  do {
    const response = await fetch('https://api.github.com/graphql', {
      method: 'POST',
      headers: { authorization: `bearer ${token}`, 'content-type': 'application/json', 'user-agent': 'vivid-sponsors' },
      body: JSON.stringify({ query: query(withPayment), variables: { login: MAINTAINER, cursor, activeOnly } }),
    });
    const body = await response.json();
    if (!response.ok || body.errors) {
      const detail = JSON.stringify(body.errors || body.message || response.status);
      if (withPayment && body.errors?.length && body.errors.every((e) => e.type === 'INSUFFICIENT_SCOPES')) {
        throw new MissingScopeError(detail);
      }
      const hint = detail.includes('Resource not accessible by personal access token')
        ? " SPONSORS_TOKEN looks like a fine-grained token, which can't read sponsor tiers. Use a classic token."
        : '';
      throw new Error(`GitHub GraphQL request failed: ${detail}${hint}`);
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
  // Longest-standing sponsors first. Live data already comes in that order; fixtures may set createdAt.
  usable.sort((a, b) => String(a.createdAt ?? '').localeCompare(String(b.createdAt ?? '')));

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
  let y = 0;
  let clip = 0;
  const sections = TIERS.filter((tier) => groups[tier.key].length > 0);

  sections.forEach((tier) => {
    y += 40;
    parts.push(`<text x="${WIDTH / 2}" y="${y}" text-anchor="middle" class="tier-title">${escapeXml(tier.title)}</text>`);
    y += 25;

    const people = groups[tier.key];
    const rows = layoutRows(people.length, tier.slot, tier.gap);
    const rowHeight = tier.avatar + (tier.names ? 28 : 0);
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
        const id = `c${clip++}`;
        const label = displayName(person);
        defs.push(`<clipPath id="${id}"><circle cx="${cx}" cy="${cy}" r="${r}"/></clipPath>`);
        let item = `<a href="${PROFILE}${encodeURIComponent(person.login)}" class="sponsor-link" target="_blank">`
          + `<title>${escapeXml(label)}</title>`
          + `<g${tier.muted ? ' opacity="0.6" filter="url(#muted)"' : ''}>`
          + `<image x="${cx - r}" y="${cy - r}" width="${tier.avatar}" height="${tier.avatar}" href="${avatars.get(person.login)}" preserveAspectRatio="xMidYMid slice" clip-path="url(#${id})"/>`
          + (tier.ring ? `<circle cx="${cx}" cy="${cy}" r="${r + 1.5}" fill="none" stroke="url(#${tier.ring}Ring)" stroke-width="2"/>` : '')
          + '</g>';
        if (tier.names) {
          item += `<text x="${cx}" y="${cy + r + 20}" text-anchor="middle" class="sponsor-name">${escapeXml(truncate(label, tier.nameMax))}</text>`;
        }
        parts.push(`${item}</a>`);
        x += tier.slot + tier.gap;
      }
    });
    y += rows.length * rowHeight + (rows.length - 1) * tier.gap;
  });

  if (sections.length === 0) {
    y += 40;
    parts.push(`<text x="${WIDTH / 2}" y="${y}" text-anchor="middle" class="tier-title">Sponsors</text>`);
    y += 35;
    parts.push(`<text x="${WIDTH / 2}" y="${y}" text-anchor="middle">Be the first to sponsor Vivid.</text>`);
  }

  const height = Math.round(y + 25);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${WIDTH}" height="${height}" viewBox="0 0 ${WIDTH} ${height}">
<title>Vivid's sponsors</title>
<!-- Generated by scripts/sponsors/render-sponsors.mjs in blurbery/vivid -->
<style>
text { font-family: ${FONT}; font-size: 14px; font-weight: 300; fill: #777777; }
.tier-title { font-size: 20px; font-weight: 500; }
.sponsor-link { cursor: pointer; }
</style>
<defs>
<linearGradient id="goldRing" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#f6e3a8"/><stop offset="0.5" stop-color="#d4af5f"/><stop offset="1" stop-color="#8a6a2c"/></linearGradient>
<linearGradient id="silverRing" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e8e7e8"/><stop offset="0.5" stop-color="#9a9a9a"/><stop offset="1" stop-color="#6c6b6b"/></linearGradient>
<filter id="muted"><feColorMatrix type="saturate" values="0.2"/></filter>
${defs.join('\n')}
</defs>
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
