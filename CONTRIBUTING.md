# Contributing

Vivid is an independent Apple media client developed in this repository. Open issues and pull requests against `blurbery/vivid`.

## Development

Use the local setup below and read [the docs](docs/README.md) and [AGENTS.md](AGENTS.md) for code guidance. Generate the Xcode project from `iosApp/project.yml`. The current Xcode scheme names are listed below.

Preserve the working browsing, focus and playback behaviour. Validate changes with focused tests, relevant Apple builds and simulator, emulator or physical-device checks appropriate to the change. State exactly what was tested and disclose any gaps; never treat an earlier device benchmark as a measurement of a new revision.

## Local setup

Install Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen), then generate the project:

```sh
cd iosApp
xcodegen generate
open Vivid.xcodeproj
```

VividKit is a local Swift package included with this checkout. Its FFmpeg dependency is pinned in `VividKit/Package.swift`; the subtitle and font frameworks are in `VividKit/Vendor`. Keep their notices and binary slices together when building. The app’s Swift package resolution is tracked; do not substitute a different playback engine.

Use the `Vivid` scheme for iPhone/iPad and `VividTV` for Apple TV. These are the current build identifiers. Choose an installed simulator in Xcode, or build the TV target without signing:

```sh
xcodebuild build -project Vivid.xcodeproj -scheme VividTV \
  -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO
```

For physical devices, use the ignored `iosApp/Signing/Local.xcconfig` override described in [the signing sample](iosApp/Signing/Local.xcconfig.sample). Keep credentials and personal signing details out of Git. Use a running Silo server for its integration checks, or an Emby server for its iPhone and Apple TV integration. Generated media fixtures cover focused engine checks without a server.

## Pull requests and repository control

Contributors are welcome to open pull requests from branches in their own forks.

> [!IMPORTANT]
> **Only blurbery controls merges, direct updates to `main`, and branch creation in `blurbery/vivid`.** A contribution or review does not grant permission to perform those actions. Owner approval for design and documentation changes is still required before implementation.

## Commits and reviews

Use Conventional Commits and follow the [release notes format](docs/release/versioning.md). Each update pushed to `main` can publish a source release, so review and validate it first. Keep release bullets factual and user-facing.

Give reviewers enough detail to reproduce the problem and assess the change without a private conversation:

- Explain the symptoms, reproduction steps, expected behaviour and root cause when known.
- Describe what changed, why you chose that approach, affected providers/platforms and compatibility or recovery risks.
- Include regression coverage where appropriate, exact test commands or CI links, the tested revision, results and any failed, skipped or untested cases.
- Support performance claims with measured results and the workload/environment. If no benchmark was run, say so.
- Keep the explanation focused, but do not leave out information needed to review the work. Update it when follow-up changes alter the scope.

Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Credit AI assistance accurately and distinguish your direction, review and physical testing from generated work or someone else’s checks.

## Testing status

Ask whether the change has been tested if that is not already confirmed in the conversation. Accept testing on physical devices, simulators or emulators; physical Apple hardware is not mandatory. Do not ask again when blurbery has already confirmed testing.

Record the test environment, checks and results that are known. Clearly distinguish builds, automated tests, simulator/emulator checks and physical-device feedback. State failures or untested behaviour honestly, without inventing details or claiming another person’s testing as your own.

Testing status is informational, not a draft or review gate. Missing, failed or simulator-only testing does not require a draft PR and must not prevent opening or marking a PR ready for review. Report failures and limitations so blurbery can decide whether to merge; do not automatically block or merge based on this rule. Update the recorded results after relevant follow-up changes.

Documentation-only changes may state “Not applicable, documentation-only change”.

## Design ownership

> [!IMPORTANT]
> **Vivid’s design is controlled exclusively by blurbery. No design changes without blurbery’s prior, explicit approval.** Contributors, reviewers and AI tools cannot approve design changes on the owner’s behalf.

This covers layout, navigation and interaction design, focus behaviour, colours, typography, spacing, icons, artwork, branding, animations and transitions across every Apple platform. Documentation branding and the README’s visual layout are also controlled by blurbery.

- Discuss the proposed change and obtain approval from blurbery before implementing it. Approval for one change does not authorize a broader redesign.
- Include a link or reference to that approval in the PR and keep the implementation within the approved scope.
- Bug fixes and refactors must preserve the approved design. If a fix would alter it, request approval first; do not introduce a redesign under the label of cleanup, accessibility, performance or consistency work.
- PRs containing unapproved design changes are not ready for review and must not be merged, even if tests pass or another reviewer approves.

## Documentation ownership

> [!IMPORTANT]
> **Vivid’s documentation is controlled exclusively by blurbery. No documentation changes without blurbery’s prior, explicit approval.** Contributors, reviewers and AI tools cannot approve documentation changes on the owner’s behalf.

This covers the README, guides, branding text and assets, notices, contribution rules, agent instructions, PR templates and documentation comments or references in source and build files.

- Obtain approval before editing, adding, renaming or deleting documentation. Approval to change app code does not automatically authorize documentation changes.
- Keep wording, formatting and scope within the owner’s approval. Typo fixes, link repairs, automated updates, cleanup and AI rewrites still require approval.
- Include a link or reference to blurbery’s approval in the PR. If a code change needs a documentation update, identify it and obtain approval before making that update.
- PRs containing unapproved documentation changes are not ready for review and must not be merged, even if another reviewer approves.
- Preserve applicable copyright and licence notices. Approval to restyle a document does not authorize changing its legal terms.

## AI-assisted contributions

AI tools are welcome. You remain responsible for understanding, reviewing and validating everything you submit, including generated code, tests and documentation. No particular tool is required; agents must follow [AGENTS.md](AGENTS.md).

> [!IMPORTANT]
> **AI disclosure is required in every pull request.** Complete the PR template’s **AI disclosure** section. A PR without a completed disclosure is not ready for review and must not be merged.

- If AI was used, name every tool or assistant, include the model when known, and explain what it helped with: code, tests, documentation, review or other work.
- Describe the contributor’s direction, review and validation. Do not present AI-generated work or unperformed testing as manual work.
- If no AI was used, explicitly state **“No AI assistance was used for this pull request.”** Leaving the section blank is not a disclosure.
- If a model label is unavailable, say so; do not guess. Update the disclosure when further AI-assisted changes are added to the PR.
- Disclose substantial AI assistance in issues and review reports as well. Authorized direct commits without a PR must include the disclosure in the commit body. Generated documentation can be disclosed in its accompanying contribution rather than repeating a notice on every page.

Review the changes you submit and explain what you tested. Keep credentials and private data out of prompts, commits and reports. AI output needs the same code review and validation as any other contribution.

## Licensing of contributions

Vivid’s own source code is licensed under [Apache-2.0](LICENSE).

Unless you explicitly state otherwise, a contribution intentionally submitted
for inclusion in Vivid is licensed under Apache-2.0. Third-party code must
retain its applicable licence and attribution; identify any such code in the
contribution so its terms can be reviewed.

You retain copyright in your contribution; no assignment is requested.

## Notices

Retain existing copyright, licence and dependency notices. Update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) when dependencies change. Read [Apple TV focus guidance](docs/apple-tv-focus.md) before changing TV navigation.
