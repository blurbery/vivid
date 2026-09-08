export default {
  branches: ["main"],
  repositoryUrl: "https://github.com/blurbery/vivid.git",
  tagFormat: "v${version}",
  plugins: [
    "./scripts/release/notes.mjs",
    ["@semantic-release/github", {
      releaseNameTemplate: "<%= nextRelease.version %>",
      releaseBodyTemplate: "<%= nextRelease.notes %>",
      successComment: false,
      failComment: false,
      failTitle: false,
      releasedLabels: false,
      addReleases: false,
      discussionCategoryName: false,
    }],
  ],
};
