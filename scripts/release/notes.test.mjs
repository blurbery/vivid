import assert from "node:assert/strict";
import test from "node:test";
import config from "../../release.config.mjs";
import { analyzeCommits, generateNotes } from "./notes.mjs";
const context = (...messages) => ({
  cwd: process.cwd(),
  commits: messages.map(message => ({ message, hash: "1234567" })),
  logger: { log() {} },
});

for (const [title, messages, expected] of [
  ["fixes", ["fix(tvos): restore focus"], "patch"],
  ["features", ["feat: add a server picker"], "minor"],
  ["breaking marker", ["feat!: change the connection contract"], "major"],
  ["breaking footer", ["fix: change login\n\nBREAKING CHANGE: require a new token"], "major"],
  ["documentation updates", ["docs: update the setup guide"], "patch"],
  ["ordinary messages", ["Update the readme"], "patch"],
  ["largest change wins", ["fix: focus", "feat: picker"], "minor"],
  ["no new commits", [], null],
]) {
  test(title, async () => assert.equal(await analyzeCommits({}, context(...messages)), expected));
}

test("notes contain only update bullets, with no hashes, authors, headings or trailers", () => {
  assert.equal(generateNotes({}, context("fix(tvos): retain focus\n\nCo-authored-by: Private Person <private@example.invalid>",
    "docs: update setup", "fix(tvos): retain focus")), "- retain focus\n- update setup");
});
test("curated release bullets replace the subject without leaking the rest of the body", () => {
  assert.equal(generateNotes({}, context("feat: introduce Vivid\n\nRelease-Notes:\n- Add theme-aware branding.\n- Add automatic releases.\n\nInternal details")),
    "- Add theme-aware branding.\n- Add automatic releases.");
});
test("commit text cannot inject markup or ping accounts", () => {
  const notes = generateNotes({}, context("fix: <script>alert</script> [click](https://example.invalid) @someone"));
  assert.ok(notes.startsWith("- &lt;script&gt;"));
  assert.ok(notes.includes("\\[click\\]\\("));
  assert.ok(!notes.includes("@someone"));
});
test("GitHub release title is the version alone and body is just generated notes", () => {
  const github = config.plugins.find(plugin => Array.isArray(plugin) && plugin[0] === "@semantic-release/github")[1];
  assert.equal(github.releaseNameTemplate, "<%= nextRelease.version %>");
  assert.equal(github.releaseBodyTemplate, "<%= nextRelease.notes %>");
  assert.equal(github.addReleases, false);
  assert.equal(github.successComment, false);
  assert.deepEqual(config.branches, ["main"]);
});

test("explicitly skipped cleanup does not create a release", async () => {
  assert.equal(await analyzeCommits({}, context("chore: remove obsolete files [skip release]")), null);
});
test("skipped changes cannot influence the next version or its notes", async () => {
  const input = context("feat!: internal cleanup [SKIP RELEASE]\n\nRelease-Notes:\n- Private housekeeping", "fix: correct playback");
  assert.equal(await analyzeCommits({}, input), "patch");
  assert.equal(generateNotes({}, input), "- correct playback");
});
