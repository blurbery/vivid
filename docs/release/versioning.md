<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Versioning &amp; Releases</h1>
<p align="center">Semantic versions. Clear release notes.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

Vivid uses `semantic-release` to publish a GitHub source release after updates reach `main`. The workflow uses a standard Ubuntu runner, has a five-minute limit, and runs the release-rule checks before publishing. Apple signing and distribution are not part of this workflow.

## Version policy

<table width="100%">
  <thead>
    <tr><th align="left">Change</th><th align="left" width="10000">Version increment</th></tr>
  </thead>
  <tbody>
    <tr><td><code>feat:</code></td><td>Minor</td></tr>
    <tr><td><code>fix:</code>, <code>perf:</code></td><td>Patch</td></tr>
    <tr><td><code>!</code> after the type/scope, or a <code>BREAKING CHANGE:</code> footer</td><td>Major</td></tr>
    <tr><td>Documentation, maintenance and other updates</td><td>Patch</td></tr>
    <tr><td>No new commits</td><td>No release</td></tr>
  </tbody>
</table>

The largest change since the previous version determines the increment. Tags use `v0.1.0`; the release title is `0.1.0` with no prefix, product name or extra wording.

Logo, branding, artwork, documentation and small visual polish updates are **patch changes**: increment the last number by one, for example `0.0.1` → `0.0.2`. Use `fix:`, `style:` or `docs:` as appropriate, not `feat:`. Reserve `feat:` for new functionality. Keep existing published versions; this policy applies to future releases.

Vivid’s source releases in this repository begin at `v0.6.0`.

## Version shown in the app

Settings → About displays the installed `CFBundleShortVersionString` and `CFBundleVersion` as version (build). Local development builds still use the `project.yml` marketing baseline of 0.6.0 and build 1; this is not a claim that they match the latest GitHub source release. Tagged distribution builds resolve `MARKETING_VERSION` from the release tag using `scripts/ci/resolve-marketing-version.sh`. Unsigned lanes accept `BUILD_NUMBER` as `CURRENT_PROJECT_VERSION`. A future TestFlight archive must use an explicit release version and an unused Apple build number; there is no TestFlight lane in this repository.

The app does not query private GitHub APIs at runtime. Local simulator builds use their own build number (currently 1); they must not claim to be an uploaded TestFlight build.

## Release notes

An owner-requested housekeeping commit may include `[skip release]`. Such commits neither trigger a release nor contribute to the version calculation or notes in a later release. Ordinary commits retain the normal versioning rules.

Keep this format for every release, including documentation-only updates. Write the bullets in plain language, in the same direct voice as the README.

> [!IMPORTANT]
> Release titles contain only the version number. Bodies contain only flat update bullets, with no headings, dates, author names, commit hashes, comparison links or automated footer.

The default bullet is the commit subject with its Conventional Commit prefix removed.

For an update with several user-visible changes, add curated bullets to the commit message:

```text
feat: add a new browsing feature

Release-Notes:
- Add the new browsing feature.
- Improve keyboard navigation in the picker.
```

Keep each bullet on one line, directly after `Release-Notes:`. A blank line ends the list. Write specific changes in plain language; do not describe planned integrations as delivered. Internal commit bodies and AI attribution trailers are not copied into release notes.

## Validation

```sh
npm ci --ignore-scripts --no-audit --no-fund
npm run test:release
```

The tests cover major/minor/patch rules, ordinary commit messages, empty ranges, curated bullets, duplicate notes, markup escaping and the version-only title. They validate release tooling, not the Apple app. App code changes still need the relevant builds, tests and device checks before they are pushed to `main`.

Dependencies are pinned in `package-lock.json`; the Node tools do not become app dependencies. The `VIVID_GIT_NOREPLY_EMAIL` repository variable must hold `blurbery`'s GitHub noreply address. The workflow uses its scoped `GITHUB_TOKEN` and does not publish an npm package or comment on issues/PRs.

Only Vivid's release workflow is enabled. The Apple build/sideload workflows remain disabled until they are configured and explicitly requested. Vivid’s Apple setup is tracked in [App Distribution](distribution.md); it is separate from source releases.

Repository visibility stays private. Its releases are visible only to people with repository access until the owner changes that visibility.
