import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const VIVID_SILVER = 0xb1b0b0;
const MAX_NOTES_LENGTH = 3_800;

function releaseBullets(body) {
  return body
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map(line => line.match(/^\s*[-*•]\s+(.+?)\s*$/)?.[1])
    .filter(Boolean);
}

function bulletDescription(body) {
  const bullets = releaseBullets(body);
  if (!bullets.length) return "Release notes are available on GitHub.";

  const included = [];
  for (const bullet of bullets) {
    const candidate = [...included, `- ${bullet}`].join("\n");
    if (candidate.length > MAX_NOTES_LENGTH) break;
    included.push(`- ${bullet}`);
  }
  if (included.length < bullets.length) included.push("- More details on GitHub…");
  return included.join("\n");
}

export function buildDiscordReleasePayload(release) {
  if (!release?.html_url || !release?.tag_name) {
    throw new Error("GitHub release data is missing its URL or tag");
  }

  const version = release.name?.trim() || release.tag_name.replace(/^v/, "");
  const notes = bulletDescription(release.body || "");
  return {
    allowed_mentions: { parse: [] },
    embeds: [
      {
        color: VIVID_SILVER,
        title: `Release - ${version}`,
        description: `${notes}\n\n[View on GitHub](${release.html_url})`,
        footer: { text: "Vivid · GitHub release" },
        ...(release.published_at ? { timestamp: release.published_at } : {}),
      },
    ],
  };
}

export function validateDiscordWebhookUrl(webhookValue) {
  let webhook;
  try {
    webhook = new URL(webhookValue);
  } catch {
    throw new Error("DISCORD_RELEASE_WEBHOOK_URL must be a Discord webhook URL");
  }
  if (webhook.protocol !== "https:" || webhook.hostname !== "discord.com" ||
      !webhook.pathname.startsWith("/api/webhooks/")) {
    throw new Error("DISCORD_RELEASE_WEBHOOK_URL must be a Discord webhook URL");
  }
  return webhook;
}

export async function postDiscordRelease(release, webhookValue) {
  const webhook = validateDiscordWebhookUrl(webhookValue);
  webhook.searchParams.set("wait", "true");

  const response = await fetch(webhook, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(buildDiscordReleasePayload(release)),
  });
  if (!response.ok) {
    throw new Error(`Discord rejected the release notification with HTTP ${response.status}`);
  }
}

async function main() {
  const releasePath = process.argv[2];
  const webhook = process.env.DISCORD_RELEASE_WEBHOOK_URL;
  if (!webhook) {
    throw new Error("Release JSON path and DISCORD_RELEASE_WEBHOOK_URL are required");
  }
  if (releasePath === "--check-webhook") {
    validateDiscordWebhookUrl(webhook);
    return;
  }
  if (!releasePath) {
    throw new Error("Release JSON path and DISCORD_RELEASE_WEBHOOK_URL are required");
  }
  const release = JSON.parse(await readFile(releasePath, "utf8"));
  await postDiscordRelease(release, webhook);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
