import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  buildDiscordReleasePayload,
  validateDiscordWebhookUrl,
} from "./discord-notify.mjs";

describe("Discord release notifications", () => {
  it("posts release bullets in a Vivid embed with a GitHub link", () => {
    const payload = buildDiscordReleasePayload({
      name: "0.22.2",
      tag_name: "v0.22.2",
      html_url: "https://github.com/blurbery/vivid/releases/tag/v0.22.2",
      body: "- Fixed playback startup.\n- Improved subtitle selection.",
      published_at: "2026-09-21T06:00:00Z",
    });

    assert.deepEqual(payload.allowed_mentions, { parse: [] });
    assert.equal(payload.embeds[0].color, 0xb1b0b0);
    assert.equal(payload.embeds[0].title, "0.22.2");
    assert.equal(
      payload.embeds[0].description,
      "• Fixed playback startup.\n• Improved subtitle selection.\n\n[View on GitHub](https://github.com/blurbery/vivid/releases/tag/v0.22.2)",
    );
  });

  it("falls back to the GitHub link when no bullets are present", () => {
    const payload = buildDiscordReleasePayload({
      name: "",
      tag_name: "v0.22.2",
      html_url: "https://github.com/blurbery/vivid/releases/tag/v0.22.2",
      body: "",
    });

    assert.equal(payload.embeds[0].title, "0.22.2");
    assert.equal(
      payload.embeds[0].description,
      "Release notes are available on GitHub.\n\n[View on GitHub](https://github.com/blurbery/vivid/releases/tag/v0.22.2)",
    );
  });

  it("rejects an invalid webhook value before a release is published", () => {
    assert.throws(
      () => validateDiscordWebhookUrl("-"),
      /must be a Discord webhook URL/,
    );
    assert.throws(
      () => validateDiscordWebhookUrl("https://example.com/api/webhooks/1/token"),
      /must be a Discord webhook URL/,
    );
  });
});
