import { analyzeCommits as analyzeConventionalCommits } from "@semantic-release/commit-analyzer";

function releaseCommits(commits) {
  return commits.filter(({ message }) => !/\[skip release\]/i.test(message));
}

export async function analyzeCommits(_config, context) {
  const commits = releaseCommits(context.commits);
  if (!commits.length) return null;
  // Publish normal updates; explicitly skipped housekeeping stays out of releases.
  return await analyzeConventionalCommits({ preset: "conventionalcommits" }, { ...context, commits }) ?? "patch";
}

function plainText(value) {
  return value.trim().replace(/\s+/g, " ")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/([\\`*_{}\[\]()#+!|])/g, "\\$1")
    .replace(/@/g, "@\u200b");
}

export function generateNotes(_config, { commits }) {
  const notes = [];
  for (const { message } of releaseCommits(commits)) {
    const lines = message.replace(/\r\n/g, "\n").split("\n");
    // Optional curated bullets avoid exposing internal commit bodies or trailers.
    const marker = lines.findIndex(line => line.trim() === "Release-Notes:");
    const bullets = [];
    if (marker >= 0) {
      for (const line of lines.slice(marker + 1)) {
        if (!line.startsWith("- ")) break;
        if (line.slice(2).trim()) bullets.push(line.slice(2));
      }
    }
    const subject = lines[0].replace(/^[a-z]+(?:\([^\n)]+\))?!?:\s*/i, "");
    for (const item of bullets.length ? bullets : [subject]) {
      const text = plainText(item);
      if (text && !notes.includes(text)) notes.push(text);
    }
  }
  return notes.map(note => `- ${note}`).join("\n");
}
