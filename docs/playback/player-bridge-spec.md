<p align="center">
  <img src="../branding/vivid-mark-silver.png" width="96" height="96" alt="Vivid silver logo">
</p>
<p align="center"><strong>Vivid</strong></p>
<h1 align="center">Player Bridge Specification</h1>
<p align="center">Behaviour contract for the Vivid-written Lucid Engine bridge.</p>
<p align="center"><a href="../../README.md">Home</a> · <a href="../README.md">Documentation</a> · <a href="../../CONTRIBUTING.md">Contributing</a> · <a href="https://github.com/blurbery/vivid/releases">Releases</a></p>

---

This guide specifies, by behaviour, the Swift bridge that sits between Vivid's Lucid Engine adapter and libmpv on iPhone, iPad and Apple TV. It is written for a clean-room reimplementation and is the implementer's only description of how the current bridge behaves.

Contents:

1. [Purpose and status](#1-purpose-and-status)
2. [Clean-room rules for readers](#2-clean-room-rules-for-readers)
3. [Build context and platform conditions](#3-build-context-and-platform-conditions)
4. [Caller contract](#4-caller-contract)
5. [Threading, isolation and locking](#5-threading-isolation-and-locking)
6. [mpv lifecycle](#6-mpv-lifecycle)
7. [Video surface and the video-output contract](#7-video-surface-and-the-video-output-contract)
8. [Match Content and HDR](#8-match-content-and-hdr)
9. [External displays, Picture in Picture, background and AirPlay](#9-external-displays-picture-in-picture-background-and-airplay)
10. [Errors, logs and strings other code depends on](#10-errors-logs-and-strings-other-code-depends-on)
11. [Constants and timing values](#11-constants-and-timing-values)
12. [Vivid-authored behaviour by commit](#12-vivid-authored-behaviour-by-commit)
13. [Deliberately omitted members and paths](#13-deliberately-omitted-members-and-paths)
14. [Known quirks reproduced deliberately](#14-known-quirks-reproduced-deliberately)
15. [Parity hazards](#15-parity-hazards)
16. [Test checklist](#16-test-checklist)
17. [Amendments after implementation](#17-amendments-after-implementation)

## 1. Purpose and status

### 1.1 What the bridge does

The bridge is the layer between `VividMPVPlayer` (the Lucid Engine adapter, which is not being rewritten) and libmpv. It owns:

- one mpv client context per load, its options, its event loop and its teardown;
- property observation, conversion of mpv values to Swift values, and ordered delivery of properties and events to the adapter on the main thread;
- asynchronous commands and property requests with exactly-once completions;
- the video surface: a black container view holding an `AVSampleBufferDisplayLayer` that mpv's `avfoundation` video output draws into;
- Apple TV display criteria (Match Content: frame rate and dynamic range) and EDR on iPhone and iPad;
- reactions to the app or scene entering the background, returning to the foreground and becoming active;
- placement of the video on an external screen on iPhone and iPad;
- the console error lines and diagnostic events that other code and documentation rely on.

The bridge does not render frames, own the audio session, choose tracks (apart from one hook the adapter drives), or talk to any server.

### 1.2 Status

The current bridge (`MpvPlayerCoreBase.swift`, `MpvPlayerCore.swift` and `ExternalDisplayManager.swift` in `iosApp/iosApp/Playback/MPV/`) was adapted from a third-party GPL-3.0 project without App Store permission. This specification drives a Vivid-written replacement that must behave exactly the same: blurbery describes current playback as perfect, so any visible difference is a regression.

The replacement is compiled alongside the current files. A small selection file picks one of them with the compilation condition `VIVID_OWN_BRIDGE`, which is not defined by default, so the current bridge stays in use until a separate switch-over change defines it (section 4.5).

### 1.3 How to read this document

| Marking | Meaning |
| --- | --- |
| (no tag) | Live: a current caller, mpv or the system drives it in Release builds. Reproduce it exactly. |
| **[debug-only]** | Compiled only when `VIVID_P8_TRIAL` is defined, which only the tvOS Debug configuration does. Reproduce it exactly under the same condition. |
| **[unreached]** | Used only in section 13, for code paths of the current bridge that nothing reaches today. The replacement omits them. |
| *Vivid (`hash`)* | Behaviour Vivid added after the original import, with the commit that added it (details in section 12). |

Naming rules:

- Names that callers use today are written exactly as they are and must not change (section 4).
- New type names come from the naming plan in section 4.5.
- Every other name (helpers, stored properties, locks, nested and private types, local variables) is the implementer's choice. Identifiers that appear inside the quoted Vivid code in section 12 are illustrative only and are not required.
- Where a reason is given for an ordering or a rule, the reason is part of the requirement.

## 2. Clean-room rules for readers

The implementer must never see the current bridge code, and must not see the engine's Apple patches either. Everything the implementer needs about the engine is stated as behaviour in this document, so no engine source is required.

The engine's Apple patches (its `avfoundation` video and audio outputs and related changes) are being rewritten clean-room as a separate project. Sections 6.19 and 7 are therefore the single interface both rewrites share: the bridge may rely on nothing about the engine beyond what they state, and the engine rewrite must keep everything they state true.

### 2.1 May read

| Source | Notes |
| --- | --- |
| `iosApp/iosApp/Playback/MPV/VividMPVPlayer.swift` | The adapter and its subclass of the core. The main caller. |
| `iosApp/iosApp/Playback/MPV/LucidSubtitleInventory.swift` | Uses a bare base instance to convert a `track-list` node. |
| `iosApp/iosApp/Shared/Diagnostics/Playback/PlaybackSessionRecorder.swift` | Uses the external-display role test. |
| Everything under `iosApp/Tests/` | Includes `MpvPropertyCoalescingTests.swift` and `PlayerSurfaceLayoutTests.swift`. |
| Everything under `scripts/` except the two scripts named in section 2.2 | Includes `scripts/tests/mpv-track-tests.py` and `scripts/release/use-patched-libmpv.sh`. |
| `.github/workflows/` except `mpv-audio-driver.yml` | CI definitions. |
| Other current Vivid source files | They contain no bridge or engine code. |
| Vivid documentation | `docs/`, `README.md`, `THIRD_PARTY_NOTICES.md`, `iosApp/Resources/OpenSourceLicenses/README.txt`. These describe the engine only in prose. |
| `docs/playback/lucid-engine-patch-spec.md` (on the engine branch, `experiment/lucid-engine-build`) | The engine side of the same contract, also written by behaviour for a clean-room rewrite. Sections 6.19 and 7 of this document remain the interface both rewrites share: the bridge may rely on nothing about the engine beyond what they state. |
| mpv's public C headers, and nothing else from the engine package | `mpv/client.h`, `mpv/render.h`, `mpv/render_gl.h` and `mpv/stream_cb.h` under `Headers/` inside `Libmpv.xcframework` in the resolved `edde746/mpv-build` SwiftPM binary artifacts at revision `c6f7e635c2c8681fa13c2c678f0e61ae46fe8bc6` (mpv 0.41.0, FFmpeg 8.0.1). The bridge uses only `client.h` and `stream_cb.h`. |
| mpv's public manual (upstream mpv documentation) | Options, properties, commands and the libmpv client API, for mpv 0.41. It does not describe the `avfoundation` video output or the `ao-avfoundation-*` options; this document does. |
| Apple developer documentation | UIKit, AVFoundation, AVKit, Core Media, Core Animation. |

### 2.2 Must not read

- The three current bridge files, any earlier version of them, and anything that shows their content: `git log -p`, `git show`, `git blame` or diffs that include them (including the import commits `1598f91` and `04a349d`, and any repository-wide history listing without a path filter).
- `scripts/tests/playback-end-recovery-tests.py` (it embeds the current bridge's private structure).
- `edde746/plezy` in any form: repository, forks, releases, issues, pull requests or packaged builds.
- Anything from `edde746/mpv-build` or `edde746/MPVKit` other than the four public headers listed above: no patch files (the `patches/` trees and their series files), engine sources, Swift files (including `Demo/`, `Sources/` and the package manifests), build scripts, READMEs or other documents, in the repositories, their history or the resolved SwiftPM checkout.
- Vivid files that reproduce engine patch source: `patches/mpv/` (Vivid's audio-driver patch, whose context lines come from the patched engine), `scripts/tests/compressed-audio-recovery-tests.py` (it extracts and embeds the patched audio driver's source) and `.github/workflows/mpv-audio-driver.yml` (it embeds lines of that source).
- The working notes the spec editor used to prepare this document.

If something here seems incomplete or contradictory, ask the spec editor. Do not look at the current code or the engine patches to settle it.

## 3. Build context and platform conditions

| Item | Value |
| --- | --- |
| Platforms | iPhone and iPad (iOS 18.0 and later, `TARGETED_DEVICE_FAMILY` `1,2`, Mac and Vision Pro "Designed for iPad" switched off) and Apple TV (tvOS 26.0 and later). No macOS, Mac Catalyst or visionOS code paths exist or may be added. |
| Language | Swift 5 language mode, minimal concurrency checking, no default actor isolation. Unannotated classes are nonisolated. |
| Imports | `import Libmpv` (the `edde746/mpv-build` binary package pinned above). On tvOS the core file also imports AVKit, which provides `UIWindow.avDisplayManager`, `AVDisplayCriteria` and the mode-switch notifications. |
| New files | `iosApp/iosApp/Playback/MPV/VividPlayerCoreBase.swift` and `VividPlayerCore.swift`, each wrapped in `#if os(iOS) \|\| os(tvOS)`; `VividExternalDisplay.swift`, wrapped in `#if os(iOS)`; `VividBridgeSelection.swift` (section 4.5). |
| Compilation of both bridges | The new files are not wrapped in `VIVID_OWN_BRIDGE`. Both bridges compile in every configuration; only the selection file reads the flag. Consequences: the new code ships in every binary from its first commit, so the forbidden strings in section 10.4 apply immediately; and the new files must not collide with the current files at the top level. |
| Top-level declarations | Declare only the top-level types named in section 4.5 (plus the private relay type). No top-level functions, variables or constants, and no extensions on system types. The current bridge declares a global C-string helper, and any same-signature global would fail to compile. Do not give any class an explicit `@objc(...)` runtime name. |
| Availability | Every API older than the deployment targets is always available. The only runtime branch is iOS 26: `preferredDynamicRange` on iOS 26 and later, `wantsExtendedDynamicRangeContent` on iOS 18 to 25 (section 8.15). |
| `targetEnvironment(simulator)` | Changes two start-up options (section 6.3). Takes precedence over the platform. |
| `VIVID_P8_TRIAL` | **[debug-only]** diagnostics: the `display-commit-lock` event (section 8.3) and, on tvOS, the `display-switch-started` and `display-switch-ended` events (section 8.16). |
| `DEBUG` | Has no effect on the bridge. |

## 4. Caller contract

### 4.1 Who calls the bridge

| Caller | Uses |
| --- | --- |
| `VividMPVPlayer.swift` | Declares `private final class VividMPVCore` as a subclass of the core and overrides three hooks (section 4.4). Declares `private final class VividMPVDelegate`, which conforms to the delegate protocol. `VividMPVHostView` holds `fileprivate weak var core` typed as the core and calls `updateFrame()` from `layoutSubviews`. Calls the members in section 4.3. Is `@MainActor`, so all its calls arrive on the main thread. |
| `LucidSubtitleInventory.swift` | Inside `Task.detached(priority: .utility)`, creates a bare base instance with no arguments and calls `convertNode(_:)` on a `track-list` node fetched from its own throwaway mpv handle, then casts the result to `[[String: Any]]`. |
| `PlaybackSessionRecorder.swift` | iOS only, on the main actor: calls the static external-display role test on every connected scene's session role to fill the latest-playback report's `externalScreen` field. |
| `iosApp/Tests/MpvPropertyCoalescingTests.swift` | Conforms a recorder to the delegate protocol, creates bare base instances, assigns `delegate`, calls `dispatchDelegateProperty` and `dispatchDelegateEvent` from a private serial queue entered with `sync` from the main actor, and calls `beginDisposal()`. |
| `iosApp/Tests/PlayerSurfaceLayoutTests.swift` | Through the adapter, with real media in the simulator, asserts that the PiP source's layer is the core's `sampleBufferDisplayLayer`; that `layer.superlayer?.superlayer` is the host view's layer; that the layer reports `isReadyForDisplay` within 15 seconds; that layout and preview cycles leave the paused state and position unchanged; that the same layer survives presentation changes within one load; that a successor load has a different layer; and that the video route is the sample-buffer route with no `AVPlayer`. |
| `scripts/tests/mpv-track-tests.py` | Slices the text of `VividMPVPlayer.stop()` between the line that clears the core's delegate and the line that resets the core and proxy, and runs it against a stand-in with `delegate` and `dispose(preserveDisplayCriteria:completion:)`. The text of `stop()` must not change. |

No other file, script, plist or workflow names anything the bridge declares. `VividPlaybackBoundaryTests` and `VividPlaybackStatsProjectionTests` also drive real media through the bridge, via the adapter (section 16.1).

### 4.2 Type requirements

| Requirement | Reason |
| --- | --- |
| The core class is internal, non-final and subclassable in the same module. | `VividMPVCore` subclasses it. |
| The core is constructible with a zero-argument initialiser that subclasses inherit. Do not add a designated initialiser with arguments unless `init()` stays inheritable. | `VividMPVCore` declares only stored properties with defaults and is created as `VividMPVCore()`. |
| The core inherits from the base. Both are classes. | Callers hold weak references and compare identity. |
| The base is constructible with `init()` on any thread, cheaply, with no side effects: no mpv context, no UIKit object, no notification observer, no external-display attach, nothing dispatched. Dropping a bare instance on a background thread must be harmless, so the base has no `deinit` work. | `LucidSubtitleInventory` and the tests. |
| Inheriting from `NSObject` is allowed and recommended (selector-based notification observers need it). No caller requires it. | |
| The delegate protocol is class-bound (`AnyObject`), has exactly two requirements with no default implementations, no actor annotation and no `Sendable` requirement. | `VividMPVDelegate` and the test recorder conform; the core holds the delegate weakly. |
| The video layer type is a subclass of `AVSampleBufferDisplayLayer` with no members of its own. | The adapter wraps it in `SampleBufferPiPSource(layer:engine:)`, which takes an `AVSampleBufferDisplayLayer`, and AVKit builds `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` from it. |
| The external-display type exists on iOS and exposes the static role test. | `PlaybackSessionRecorder`, inside `#if os(iOS)`. |
| No global-actor annotation (`@MainActor` or other) on the base, the core, the delegate protocol or any member in section 4.3. | Off-main callers exist: `LucidSubtitleInventory` (detached task), the coalescing tests (background queue) and the bridge's own event queue (`preloadedAudioTrackID`). |

### 4.3 Members callers use

Members marked "base" must be declared on the base class, because callers use them on a bare base instance. Members marked "core" may be declared on either class, provided they are reachable through the core type. Every signature, label, default, optionality and return type is exact.

| Member | Exact signature | Where | Called by, thread | Behaviour |
| --- | --- | --- | --- | --- |
| initialiser | `init()` (an `override init()` when the base inherits from `NSObject`) | base | `LucidSubtitleInventory` (background), tests (main) | Section 6.1. |
| delegate | `weak var delegate: VividPlayerCoreDelegate?` | base | Adapter sets it before `initialize` and sets it to nil before `dispose`; tests set it. | Read at delivery time on main. Clearing it silences later deliveries. |
| ordered property delivery | `func dispatchDelegateProperty(name: String, value: Any?, sourceId: Int64?)` | base | Bridge internally (event queue); tests (background queue) | Section 6.10. |
| ordered event delivery | `func dispatchDelegateEvent(name: String, data: [String: Any]?, sourceId: Int64? = nil)` | base | Bridge internally; tests call it with two arguments | Section 6.10. |
| start of disposal | `@discardableResult func beginDisposal() -> Bool` | base | Bridge internally; tests on main, result ignored | Section 6.17. |
| node conversion | `func convertNode(_ node: mpv_node) -> Any?` (instance method) | base | `LucidSubtitleInventory` on a bare instance, background thread | Section 6.16. Uses no instance state, no mpv call and no lock. |
| PiP flag | `var isPipActive: Bool` (settable, default `false`) | core | Adapter, main | Gates lifecycle and placement (sections 9.3 and 9.6). |
| HDR flag | `var hdrEnabled: Bool { get }` | core | Adapter, main (Dolby Vision labelling) | Always `true` (section 13). |
| Match Content flag | `var matchContentEnabled: Bool` (settable, default `true`) | core | Adapter, main, before `initialize`, both platforms | Section 8. Also read on the event queue for the early snapshot; it is set once before `initialize`, so an unsynchronised read is acceptable. |
| background hook | `var onEnterBackground: (() -> Void)?` (default nil) | core | Adapter sets it on iOS only, before `initialize` | Declare it on both platforms. Called first in the background handler (section 9.6). *Vivid (`bca4095`)* |
| initialise | `func initialize(in window: UIWindow, hostView: UIView) -> Bool` | core | Adapter, main, once per core, after the host view has a window | Section 6.2. On `true` the adapter immediately reads its own `managedStreamsRegistered` (set inside the options hook) and `sampleBufferDisplayLayer`, so the options hook must have run synchronously inside this call. On `false` the adapter fails the load with "Lucid could not initialise." and keeps the core until its next `stop()`. |
| display layer | `var sampleBufferDisplayLayer: VividSampleBufferLayer? { get }` | core | Adapter, main: sets `videoGravity`, wraps it for PiP on iOS (not for audio-only loads) | The same object whose address was passed as `wid`, from a successful `initialize` until `dispose`; nil before and after. One new layer per core. |
| visibility | `func setVisible(_ visible: Bool)` | core | Adapter, main, always `true`, once per load | Section 9.3. |
| layout | `func updateFrame(_ frame: CGRect? = nil)` | core | `VividMPVHostView.layoutSubviews` and the adapter's PiP handler, main, always with no argument | Section 7.5. A safe no-op before a successful `initialize` and after `dispose`. |
| external display refresh | `func externalDisplayDidChange()` | core | Adapter's PiP handler (both platforms), the external-display coordinator; main | Runs the placement refresh (section 9.3). Must exist on tvOS. |
| PiP subtitle compositing | `func setPipSubtitleCompositing(_ enabled: Bool)` | core | Adapter's PiP handler (both platforms), main | Section 9.5. Must exist on tvOS, where it does nothing. |
| log level | `func setLogLevel(_ level: String)` | core | Adapter, main, after `initialize`: `"v"` in `VIVID_P8_TRIAL` builds, otherwise `"warn"` | Section 6.4. |
| observe | `func observeProperty(_ name: String, format: String)` | core | Adapter, main, 21 times before `loadfile` | Section 6.7. |
| command | `func command(_ args: [String])` | core | Adapter, main | Fire and forget: `commandAsync` with an empty completion. |
| async command | `func commandAsync(_ args: [String], completion: @escaping (Result<Int64?, Error>) -> Void)` | core | Adapter, main (`loadfile`, `sub-add`) | Section 6.13. |
| set | `func setProperty(_ name: String, value: String)` | core | Adapter, main | Fire and forget: `setPropertyAsync` with an empty completion. |
| async set | `func setPropertyAsync(_ name: String, value: String, completion: @escaping (Result<Void, Error>) -> Void)` | core | Adapter, main (`speed`, `audio-spdif`) | Section 6.13. |
| async get | `func getPropertyAsync(_ name: String, completion: @escaping (Result<String?, Error>) -> Void)` | core | Adapter, main (diagnostic sampling) | Section 6.13. |
| error check | `func checkError(_ status: CInt, option: String? = nil, file: StaticString = #fileID, line: UInt = #line)` | core | `VividMPVCore.configurePlatformMpvOptions`, main, with and without `option:` | Section 10.2. Never throws, never aborts, no return value. |
| dispose | `func dispose(preserveDisplayCriteria: Bool = false, completion: (@Sendable () -> Void)? = nil)` | core | Adapter, main, once per core, right after clearing `delegate` | Section 6.17. |
| role test | `static func isExternalDisplayRole(_ role: UISceneSession.Role) -> Bool` | external-display type (iOS) | `PlaybackSessionRecorder`, main | Section 9.1. |

### 4.4 Overridable hooks

`VividMPVCore` overrides these. They must be declared (non-final, internal) on the base or the core with exactly these shapes.

| Hook | Exact shape | Default | When the bridge uses it |
| --- | --- | --- | --- |
| Options hook | `func configurePlatformMpvOptions(mpv: OpaquePointer)` | does nothing | Exactly once per context, synchronously inside `initialize`, on main, after the bridge's own options and before `mpv_initialize` (section 6.2). The adapter sets its options with `mpv_set_option_string` and `checkError`, installs HTTP headers on the raw handle and may register its `vividstream` protocol with `mpv_stream_cb_add_ro`. |
| Preload switch | `var selectsAudioWhilePreloading: Bool { get }` (computed, so it can be overridden with a computed getter) | `false` | Read once, during context setup inside `initialize`, to decide whether to register the `on_preloaded` hook. *Vivid (`8268108`)* |
| Preload choice | `func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64?` | `nil` | On the event queue, while mpv waits in `on_preloaded`, with the converted `track-list`. A non-nil result becomes mpv's `aid` before mpv continues (section 6.15). *Vivid (`8268108`)* |

Name collisions to avoid: `VividMPVCore` declares stored properties named `headers`, `registersManagedStreams`, `managedStreamsRegistered`, `startPosition`, `autoplay`, `audioOnly`, `initialRate`, `initialVolume`, `audioLanguages`, `plannedAudio` and `airPlayPCM`. The new base and core must not declare members with any of these names.

### 4.5 Naming plan and selection aliases

New top-level types:

| New type | Kind | Caller-visible | File |
| --- | --- | --- | --- |
| `VividPlayerCoreBase` | class (recommended: subclass of `NSObject`) | yes | `VividPlayerCoreBase.swift` |
| `VividPlayerCore` | class, subclass of `VividPlayerCoreBase` | yes | `VividPlayerCore.swift` |
| `VividPlayerCoreDelegate` | protocol, `AnyObject` | yes | `VividPlayerCoreBase.swift` |
| `VividSampleBufferLayer` | class, subclass of `AVSampleBufferDisplayLayer`, no members | yes, as the type of `sampleBufferDisplayLayer` | `VividPlayerCoreBase.swift` or `VividPlayerCore.swift` |
| `VividPlayerCoreError` | struct conforming to `LocalizedError` | no (callers see only `Error`) | `VividPlayerCoreBase.swift` |
| `VividPlayerWakeupRelay` | final class, `fileprivate` or `private` | no | `VividPlayerCoreBase.swift` |
| `VividExternalDisplay` | final class, process-wide single instance, iOS only | yes (role test) | `VividExternalDisplay.swift` |

The delegate protocol `VividPlayerCoreDelegate` has exactly:

- `func onPropertyChange(name: String, value: Any?, sourceId: Int64?)`
- `func onEvent(name: String, data: [String: Any]?)`

Selection file `iosApp/iosApp/Playback/MPV/VividBridgeSelection.swift`, compiled for iOS and tvOS. Each caller-visible type has exactly one alias. With `VIVID_OWN_BRIDGE` defined each alias names the new type; otherwise it names the current type.

| Alias | Current type (flag off) | New type (flag on) | Platforms |
| --- | --- | --- | --- |
| `VividBridgeCoreBase` | `MpvPlayerCoreBase` | `VividPlayerCoreBase` | iOS, tvOS |
| `VividBridgeCore` | `MpvPlayerCore` | `VividPlayerCore` | iOS, tvOS |
| `VividBridgeCoreDelegate` | `MpvPlayerDelegate` | `VividPlayerCoreDelegate` | iOS, tvOS |
| `VividBridgeSampleBufferLayer` | `MpvVideoLayer` | `VividSampleBufferLayer` | iOS, tvOS |
| `VividBridgeExternalDisplay` | `ExternalDisplayManager` | `VividExternalDisplay` | iOS only (inside `#if os(iOS)`) |

No caller needs `VividBridgeSampleBufferLayer` today; it exists so the layer type has a selected name like every other caller-visible type.

Caller edits (the only changes outside the new files and the selection file):

| File | Change |
| --- | --- |
| `VividMPVPlayer.swift` | The superclass of `VividMPVCore` becomes `VividBridgeCore`; the conformance of `VividMPVDelegate` becomes `VividBridgeCoreDelegate`; the type of `VividMPVHostView.core` becomes `VividBridgeCore?`. No other line, and nothing in `stop()`. |
| `LucidSubtitleInventory.swift` | The bare instance becomes `VividBridgeCoreBase()`. |
| `PlaybackSessionRecorder.swift` | The role test is called on `VividBridgeExternalDisplay`. |
| `iosApp/Tests/MpvPropertyCoalescingTests.swift` | The recorder conforms to `VividBridgeCoreDelegate` and the bare instances become `VividBridgeCoreBase()`, so the tests exercise whichever bridge is selected. |

Subclassing and overriding through a type alias work in Swift, so `VividMPVCore`'s three overrides compile against either bridge. The selection aliases live in the app module, so `@testable import Vivid` and `@testable import VividTV` pick up the same selection.

### 4.6 Delegate events and payloads

Callers read payloads with `as?` casts, so a value of the wrong Swift type (for example `Int64` where `Int` is expected) fails silently. The types below are part of the contract.

| Event | Trigger | Payload (exact keys and Swift types) | Path |
| --- | --- | --- | --- |
| `start-file` | `MPV_EVENT_START_FILE` | `["sourceId": Int64]` (the event's `playlist_entry_id`); `nil` if the event carried no data | ordered |
| `file-loaded` | `MPV_EVENT_FILE_LOADED` | `["sourceId": Int64]` when a source id is remembered (section 6.6), otherwise `nil` | ordered |
| `end-file` | `MPV_EVENT_END_FILE` | Always `"reason": Int` (the raw value of mpv's end-file reason) and `"sourceId": Int64` (the event's own `playlist_entry_id`, which may be 0). Whenever the reason is `MPV_END_FILE_REASON_ERROR`, also `"error": Int` (the event's error field as it is, normally negative; never test its sign) and `"message": String` (that code's `mpv_error_string`, decoded with section 6.16.1). `nil` if the event carried no data. | ordered |
| `playback-restart` | `MPV_EVENT_PLAYBACK_RESTART` | `"positionSeconds": Double` only when a synchronous `time-pos` read succeeded and was finite; plus `"sourceId": Int64` when remembered. Can be `nil`. | ordered |
| `log-message` | `MPV_EVENT_LOG_MESSAGE`, not while backgrounded | `"prefix": String`, `"level": String`, `"text": String`, each the empty string when mpv's pointer is null; text exactly as mpv sends it (normally with a trailing newline). No `sourceId`. | ordered |
| `display-criteria-prepared` | The early display snapshot was written and the platform write reported applied (section 8.5) | `nil` | direct on main *Vivid (`f347bb7`)* |
| `display-commit-lock` | **[debug-only]** every start-of-file and end-of-file hold (section 8.3) | `"transition": String` (`start_file` or `end_file`), `"wait_ms": Double`, `"held_ms": Double`. No `sourceId`. | ordered *Vivid (`f347bb7`)* |
| `display-switch-started`, `display-switch-ended` | **[debug-only]**, tvOS: `AVDisplayManagerModeSwitchStart` and `AVDisplayManagerModeSwitchEnd` posted by any object | `nil` | direct, synchronous in the notification handler *Vivid (`f347bb7`)* |

How the adapter uses them: `error` present (cast `as? Int`) fails playback; otherwise `reason` cast `as? Int` equal to 0 means natural end of file, and any other reason cancels end confirmation. `file-loaded` marks the session ready (the load loop polls for it). `playback-restart` marks the first frame, clears seeking and buffering and resets `hr-seek` after a keyframe resume. `log-message` is matched against fixed audio diagnostics. The adapter ignores `start-file`, `sourceId`, `positionSeconds`, `level` and `message`, but they are still produced and must stay.

mpv's end-file reason raw values: `MPV_END_FILE_REASON_EOF` 0, `STOP` 2, `QUIT` 3, `ERROR` 4, `REDIRECT` 5.

### 4.7 Property values callers read

`onPropertyChange(name:value:sourceId:)` delivers `value` converted by the change event's format (section 6.8) and `sourceId` as the remembered start-of-file id at the time mpv's change event was handled (nil before the first start of file in that core).

| Property (format requested by the adapter) | Swift value the adapter expects |
| --- | --- |
| `time-pos`, `duration`, `container-fps`, `demuxer-cache-duration`, `avsync`, `frame-drop-count` (`double`) | `Double` (or nil when unavailable; the adapter treats a nil duration as 0) |
| `pause`, `paused-for-cache`, `seeking`, `eof-reached` (`flag`) | `Bool` |
| `aid`, `sid`, `secondary-sid`, `audio-codec-name`, `hwdec-current` (`string`) | `String` (track ids are parsed with `Int(_:)`, so `no` reads as no track) |
| `track-list` (`node`) | `[[String: Any]]` with `type` String, `id` Int64, `ff-index` Int64, `title` String, `codec` String, `lang` String, `demux-channel-count` Int64, `default` Bool, `forced` Bool, `hearing-impaired` Bool, `external` Bool, `selected` Bool, `external-filename` String, `dolby-vision-profile` Int64, `dolby-vision-compatibility-id` Int64 |
| `chapter-list` (`node`) | `[[String: Any]]` with `title` String and `time` Double |
| `video-params` (`node`) | `[String: Any]` with `w` Int64, `h` Int64, `par` Double, `gamma` String |
| `video-out-params` (`node`) | `[String: Any]` with `gamma` String |
| `audio-out-params` (`node`) | `[String: Any]` with `channel-count` Int64, `format` String |
| `demuxer-cache-state` (`node`) | `[String: Any]`; `fw-bytes`, `total-bytes`, `raw-input-rate`, `reader-pts`, `cache-end`, `cache-duration`, `eof`, `underrun` and `idle` are read with `as? NSNumber` (works for `Int64`, `Double` and `Bool`) and printed with string interpolation, so changing a type changes the trace text; `ts-per-stream` is `[[String: Any]]` |

`LucidSubtitleInventory` and the preload hook read `track-list` entries with the same types.

## 5. Threading, isolation and locking

### 5.1 Execution contexts

| Context | What runs there |
| --- | --- |
| Caller thread (main in the app; tests also call the two dispatch methods from a background queue) | Every public method; context creation and all pre-initialisation options; observer registration; async request submission; `dispose` including its UIKit teardown and the tvOS clear. |
| mpv's wakeup thread (any mpv-internal thread) | The wakeup callback only. It must do nothing except schedule a drain (section 6.5). |
| Event queue: one serial `DispatchQueue` per core, label `mpv`, quality of service `.userInitiated`, created with the core | Draining mpv events and handling them; every synchronous `mpv_get_property` read; the `on_preloaded` work including the call to `preloadedAudioTrackID(tracks:)`; source-transition holds and the restart snapshot; the final `mpv_terminate_destroy` and the dispose completion. |
| Main queue | Every delegate callback; every request completion except the inline cases in section 6.13; the platform display write; EDR changes; all view and layer changes; notification handlers. |

Everything except the two items in section 5.6 belongs to one core. Two cores alive at the same time, such as a retiring core and its replacement, must not affect each other.

### 5.2 State that needs protection

The implementer chooses the locks, but these properties must hold.

| State | Touched from | Requirement |
| --- | --- | --- |
| Liveness: whether the core is disposed (terminal) or in the background, and which mpv handle and relay pointer it holds, if any | Caller thread, event queue, main | Guarded. Checking liveness and using the handle for a non-blocking mpv call must be atomic with respect to disposal. |
| Pending request table and request counter | Caller thread (register, cancel on dispose), event queue (take on reply) | Guarded. Registering a request must happen under the same liveness check as its submission, so a request cannot slip past disposal and never complete. Cancelling and replying must both remove the entry under the guard, so a completion can never run twice. |
| Display and pause caches: pause state, width, height, signal peak, Dolby Vision profile and level, container frame rate, deinterlace flag, estimated output frame rate, transfer (gamma), primaries, matrix, the hold flag, the source epoch, the "early snapshot wanted" flag, the "apply scheduled" flag | Event queue, main, caller thread | Guarded by a cache guard that is never held across an mpv call or the platform display write. |
| Source-transition exclusion | Event queue (start and end of file, restart snapshot), main (every platform display write) | A separate exclusion, distinct from the cache guard, that makes a start-of-file or end-of-file hold unable to interleave with a platform display write. |
| Coalescing state: the ordered list of pending coalesced values and the token of the one flush allowed to deliver them | Event queue (and tests' background queue), main | Guarded. Never held while calling the delegate. |
| Remembered source id | Event queue only | No guard needed: only the event queue reads or writes it, and each delivery captures the value current when the delivery is created. |
| Wakeup relay's weak core reference | mpv's wakeup thread, caller thread (detach) | Guarded by the relay itself. |
| View, layer and placement state, `isPipActive`, `matchContentEnabled`, `onEnterBackground`, the initialised mark | Main | Main only by convention. `matchContentEnabled` is also read on the event queue (set once before `initialize`). |

### 5.3 Ordering and deadlock rules

1. Take the source-transition exclusion before the cache guard, never the reverse. The event queue and main both take both.
2. Call the platform display write with the source-transition exclusion held and the cache guard released. Holding the exclusion stops a start-of-file or end-of-file hold from interleaving with a half-finished HDMI write; releasing the cache guard keeps observer cache updates on the event queue from blocking behind a slow main-thread display call.
3. Request registration happens inside the liveness guard. Never take the liveness guard while holding the request guard.
4. Non-blocking mpv calls made from the caller thread (`mpv_set_property_async`, `mpv_get_property_async`, `mpv_command_async`, `mpv_observe_property`, `mpv_request_log_messages` from `setLogLevel`, `mpv_hook_add`) and `mpv_hook_continue` run while the liveness guard is held, so they cannot race destruction of the handle.
5. Blocking mpv calls (`mpv_get_property`, and the preload hook's `mpv_set_property_string`) run only on the event queue, and never while the liveness guard is held: copy the handle while holding the guard and release it before the call. Reason: the engine's video output can wait on main, and main takes the liveness guard. A handle copied on the event queue stays valid for the call, because destruction is queued on that same queue. Assert the queue in these calls (for example with `dispatchPrecondition`).
6. In the restart and early snapshots, finish every synchronous read before taking the source-transition exclusion. Never call mpv while holding the exclusion or the cache guard.
7. The relay's guard is held only while scheduling a drain (which only enqueues an asynchronous block) and while detaching.
8. Apart from the two nestings in rules 1 and 3, never hold two bridge guards at once: the liveness guard is never held together with the cache guard or the coalescing guard, in either order; the cache and coalescing guards are never held together; and nothing else is taken while the request guard or the relay guard is held. Main takes the liveness guard in every delivery block, so any inversion would deadlock playback.
9. Never make main wait synchronously on the event queue, and never destroy a context that has been stored in the core from main: destruction of a stored context runs on the event queue and can need main. The one exception is a context that set-up created but never stored (section 6.2), which is destroyed at once on main; that is safe because no video output exists for it yet.
10. Never hold the coalescing guard while calling the delegate.

### 5.4 Dispatch hops

- Wakeup thread to event queue: one asynchronous drain per wakeup (extra drains are harmless; they find no events).
- Event queue to main: exactly one `DispatchQueue.main.async` per ordered delivery (property or event). No second hop, no `Task`, no `MainActor.run`: the coalescing tests drain main exactly twice and expect every delivery.
- Event queue to main for display work: the cached apply, the early snapshot write and EDR updates.
- Caller thread to main: the inline-or-main completion helper (section 6.13).
- Caller thread to event queue: disposal enqueues the destroy step asynchronously.
- The event queue makes synchronous mpv reads and, inside `on_preloaded`, one synchronous mpv property write. mpv serves client requests while it waits in a hook, so these are safe.

### 5.5 Which thread each callback arrives on

| Callback | Thread |
| --- | --- |
| `onPropertyChange`, `onEvent` for mpv events and `log-message` | Main, one async hop |
| `onEvent("display-criteria-prepared")` | Main, called directly from the main block that performed the early write |
| `onEvent("display-switch-started")`, `onEvent("display-switch-ended")` **[debug-only]** | The thread posting the notification (main in practice), synchronously, no hop |
| `setPropertyAsync`, `getPropertyAsync`, `commandAsync` completions | Main; inline on the caller thread for the cases in section 6.13 |
| `preloadedAudioTrackID(tracks:)` | Event queue, while mpv waits |
| `configurePlatformMpvOptions(mpv:)` | Main, inside `initialize`, before `mpv_initialize` |
| `dispose` completion | Event queue, after `mpv_terminate_destroy` returns |
| `onEnterBackground` | The thread posting the background notification (main), synchronously |

### 5.6 State shared across cores

Exactly two pieces of state are process-wide, both main-thread only:

1. On tvOS, the identity of the display criteria the bridge last wrote (section 8.12). Sharing it is what lets a replacement core recognise that the criteria already on the HDMI link are the ones it wants, so consecutive episodes of the same format cause no renegotiation.
2. On iOS, the external-display coordinator's single weak "active core" slot (section 9.2). Attaching replaces it; detaching clears it only when the same core is passed.

Everything else is per core.

## 6. mpv lifecycle

### 6.1 Construction

- Creating a base instance does only this: base object initialisation, creating the per-core event queue, and default values. It creates no mpv context, touches no UIKit object, registers no observer and dispatches nothing. Safe on any thread.
- Creating the core (or `VividMPVCore`) is equally cheap. No views or layers exist until `initialize`.
- Defaults that matter: delegate nil; `isPipActive` false; `matchContentEnabled` true; `onEnterBackground` nil; not visible; not initialised; pause state "paused" (both the displayed and the confirmed value, section 6.12); width, height, signal peak, Dolby Vision profile and level, container and estimated frame rates 0; deinterlace false; colour tags absent; display criteria **held** (section 8.3); source epoch 0; "early snapshot wanted" false; no source id remembered.
- The base has no `deinit` work. The core's `deinit` calls `dispose()` with default arguments (no preservation, no completion), which is a no-op whenever the owner already disposed (section 6.17).

### 6.2 Initialisation (`initialize(in:hostView:)`)

Called on main, once per core, after the adapter has set `delegate`, `matchContentEnabled`, `onEnterBackground` (iOS) and its own option properties. Everything here completes before `initialize` returns, because the adapter reads the results of its own options hook and `sampleBufferDisplayLayer` straight afterwards.

Objects created:

| Object | State when created |
| --- | --- |
| Container view | Plain `UIView`; frame equal to the window's bounds; black background; user interaction disabled. |
| Video layer (`VividSampleBufferLayer`) | A direct sublayer of the container's layer, filling the container (at creation its geometry may simply be set from the container's bounds; afterwards it is sized only as in section 7.5); `contentsScale` equal to the window screen's `nativeScale`; opaque; black background; `videoGravity` `.resizeAspect`. |

Requirements:

- The host view and the window passed in are remembered weakly, for the core's whole life: they stay remembered after a failed `initialize` and after `dispose` (sections 6.17.2 and 14.1).
- The container, holding the layer, is at subview index 0 of the host view before the mpv context is created. Reason: the layer must already be in its final parent whenever the engine creates its video output (section 7.2), and the adapter's own content sits above the video.

Creating the mpv context, as constraints:

- `mpv_create` creates the context. If it fails, print the creation-failure line (section 10.2) and fail.
- Before `mpv_initialize`, in any order among themselves: request log messages at level `warn` (Debug and Release alike); set `wid` with `mpv_set_option` and `MPV_FORMAT_INT64` (section 7.2); set the bridge's options (section 6.3) with `mpv_set_option_string`. Every status goes through the error check with no option name (section 10.2); a rejected option is logged and set-up continues.
- `configurePlatformMpvOptions(mpv:)` is then called once with the handle, after all of the bridge's options and before `mpv_initialize`. Reason: mpv lets a later set win, so the adapter's options take precedence.
- `mpv_initialize` follows. On a negative status, print the initialisation-failure line, destroy the handle at once on main with `mpv_terminate_destroy` (no video output exists yet) and fail.
- Publication: create the wakeup relay (a weak reference to the core, plus one manual retain held on mpv's behalf). Then, atomically with respect to disposal, either store the handle and relay and install the wakeup callback with `mpv_set_wakeup_callback`, or, if the core is already disposed or already holds a handle, destroy the new handle at once on main, drop the retain and fail. Reason: a disposal running at the same time must see either no handle or the handle together with its callback.
- Only after publication, while the handle is live: register the ten internal observers (section 6.7) and, only if `selectsAudioWhilePreloading` is true at that moment, call `mpv_hook_add(handle, 0, "on_preloaded", 0)` with its status through the error check. *Vivid (`8268108`)*. If no live handle is found here, fail.

After the context exists, in any order before returning `true`: register the lifecycle observers (section 6.18); on iOS, attach to the external-display coordinator (section 9.2), whose placement refresh hides the container because the core is not visible yet (on tvOS nothing hides it); and mark the core initialised. Observers and the attach happen only after the context succeeds, so a failed `initialize` registers and attaches nothing.

Failure end state, whatever step failed: `initialize` returns `false`; the layer and the container are out of the view tree and forgotten; no observer is registered; nothing is attached to the coordinator; the core is not marked disposed. The remembered window and host view are kept. This is a requirement: a later `dispose(preserveDisplayCriteria: false)` on tvOS then clears the display criteria through the remembered window, which is how the TV leaves the previous title's mode when a load fails to start and the player closes. A later `dispose` still calls its completion.

What the adapter does next, for context, all in the same main-actor turn: it applies its subtitle settings (about sixteen `setProperty` calls), connects the host view to the core (only from then on does `layoutSubviews` call `updateFrame()`), sets the layer's `videoGravity`, calls `setVisible(true)`, wraps the layer for Picture in Picture on iOS (not for audio-only loads), calls `setLogLevel("v")` in `VIVID_P8_TRIAL` builds or `setLogLevel("warn")` otherwise, registers its 21 observations, then issues `loadfile`.

Vivid never calls `initialize` twice on one core (section 13).

### 6.3 Options set before `mpv_initialize`

Options the bridge sets after `wid` (their order among themselves is not significant):

| Option | Value | Condition | Note |
| --- | --- | --- | --- |
| `vo` | `avfoundation` | always | The engine's sample-buffer video output (section 7.2). |
| `avfoundation-composite-osd` | `no` | always (every platform and the simulator) | Set for parity. The engine must accept this value; subtitles stay on its separate layer unless Picture in Picture compositing is on (section 7.2). |
| `avfoundation-presentation` | `host` | tvOS physical devices only (not the tvOS simulator) | Required for parity; meaning in section 7.2. iOS relies on the engine's default, `media`. |
| `hwdec` | `no` in any simulator build; `videotoolbox` on every physical device | | |
| `hwdec-codecs` | `all` | always | |
| `hwdec-software-fallback` | `yes` | always | |
| `target-colorspace-hint` | `auto` | always | No visible effect with this video output; set for parity. |
| `keep-open` | `yes` | always | Upstream mpv option. At the end of a file the picture stays, paused on the last frame, so Next Up appears over it. |

The simulator check takes precedence over the platform check: the tvOS simulator gets `avfoundation-composite-osd=no` and `hwdec=no` and does not get `avfoundation-presentation=host`.

A rejected option is logged by the error check and otherwise ignored; only `mpv_create` or `mpv_initialize` failure aborts set-up. The bridge sets no process environment variables (*Vivid (`d5108a5`)* removed the last ones).

For context only (Vivid-owned, not rewritten), the adapter's options hook then sets:

| Option | Value |
| --- | --- |
| `ao` | `avfoundation` |
| `audio-spdif` | `ac3,eac3` when the initial rate is exactly 1, otherwise the empty string |
| `ao-avfoundation-manage-audio-session` | `no` (Vivid owns the audio session) |
| `audio-exclusive` | `yes` |
| `audio-channels` | `7.1,5.1,stereo` when the tvOS route is AirPlay at load time, otherwise `auto-safe` |
| `config`, `input-default-bindings`, `input-vo-keyboard`, `terminal` | `no` |
| `osd-level` | `0` |
| `pause` | `no` when autoplaying, otherwise `yes` |
| `start` | start position in seconds (`String(Double)`) |
| `speed` | initial rate (`String(Float)`) |
| `hr-seek` | `no` when the start position is above 0, otherwise `default` |
| `volume` | initial volume times 100 (`String(Float)`) |
| `sid`, `secondary-sid` | `no` |
| `cache` | `yes` |
| `demuxer-max-bytes`, `demuxer-max-back-bytes` | `268435456`, `16777216` |
| `alang` | preferred audio languages joined with commas |
| `cache-secs` | `60` (tvOS only) |
| `ao-avfoundation-max-lookahead` `4`, `ao-avfoundation-compressed-anchor-start` `yes`, `ao-avfoundation-compressed-start-grace` `1`, `ao-avfoundation-compressed-first-start-grace` `0.25`, `ao-avfoundation-compressed-anchor-resume` `yes`, `ao-avfoundation-compressed-buffer` `1.25` | tvOS with an AirPlay route only |
| `vid` | `no` for audio-only loads |
| `http-header-fields` | set with `mpv_set_option` and `MPV_FORMAT_NODE` as a string array |
| `vividstream` protocol | registered with `mpv_stream_cb_add_ro` when the managed reader applies |

The first group is applied by iterating a Swift dictionary, so its order is unspecified and must not matter. None of the adapter's option names overlap the bridge's. The bridge sets no further options after initialisation; its only run-time writes are listed in section 6.13.6.

### 6.4 Log level and log messages

- Initial level: `warn`, requested while the context is created (section 6.2).
- `setLogLevel(_:)` calls `mpv_request_log_messages` with the given string while the handle is live. It is a silent no-op without a live handle, and its status is ignored.
- `MPV_EVENT_LOG_MESSAGE` becomes the `log-message` event (section 4.6) unless the core is backgrounded, in which case the message is dropped. The bridge applies no level filtering, trimming or redaction of its own; mpv's level request is the only filter. The adapter does the redaction.

### 6.5 Wakeup callback and event drain

- The C wakeup callback receives the raw relay pointer. A null pointer is a no-op. Otherwise it borrows the relay (no retain or release) and asks it to schedule a drain.
- The relay, under its own guard, forwards only if its weak core reference is still set. Forwarding means enqueuing one asynchronous block on the core's event queue that holds the core weakly. Nothing else happens on mpv's thread.
- A drain block, if the core still exists, repeats: fetch the handle under the liveness guard and stop if the core is terminal or has no handle; call `mpv_wait_event(handle, 0)` outside the guard (zero timeout, never blocks); stop if the returned pointer is null or the event id is `MPV_EVENT_NONE`; otherwise handle the event (section 6.6). Because the handle is fetched again on every iteration, a disposal that begins mid-drain stops the drain after the current event.
- The drain keeps the core alive while it runs, so the last release of a core can happen on the event queue (section 15).

### 6.6 Events

| mpv event | Behaviour |
| --- | --- |
| `MPV_EVENT_PROPERTY_CHANGE` | Ignore when the event data is null. Otherwise process the change (section 6.9) with the event's reply userdata and the source id remembered at this moment. The property name is decoded with section 6.16.1. |
| `MPV_EVENT_SET_PROPERTY_REPLY` | Complete the matching "set" request (section 6.13). |
| `MPV_EVENT_GET_PROPERTY_REPLY` | Complete the matching "get" request. |
| `MPV_EVENT_COMMAND_REPLY` | Complete the matching "command" request. |
| `MPV_EVENT_START_FILE` | First apply the start-of-file hold (section 8.3). Then, if the event data is present, remember its `playlist_entry_id` as the current source id and dispatch `start-file` with that source id; if absent, forget the remembered id and dispatch `start-file` with no data. Reason for the order: the hold must be in place before any later property delivery for the new file can reach the display path. |
| `MPV_EVENT_FILE_LOADED` | Dispatch `file-loaded` with the remembered source id. |
| `MPV_EVENT_END_FILE` | Apply the end-of-file hold (section 8.3) before anything else for this event, so property changes for the ending file that arrive later find it set. Then dispatch `end-file` (section 4.6) using the event's own `playlist_entry_id`, not the remembered one. The remembered source id is not cleared. |
| `MPV_EVENT_HOOK` | If the event data is null, ignore the event (mpv does not send one). Otherwise, if the hook name (decoded with section 6.16.1) is `on_preloaded`, run the preload audio choice (section 6.15). Then always call `mpv_hook_continue(handle, hook id)` while the handle is live, whatever the name and whether or not a track was chosen. Reason: mpv does not proceed past a registered hook until it is continued, so a missed continue stalls loading. *Vivid (`8268108`)* |
| `MPV_EVENT_VIDEO_RECONFIG` | Attempt the early display snapshot (section 8.5). *Vivid (`f347bb7`)* |
| `MPV_EVENT_PLAYBACK_RESTART` | Take the authoritative display snapshot and release the hold (section 8.4); schedule a cached display apply; then read `time-pos` synchronously and dispatch `playback-restart` with the remembered source id. Reason for the order: the display apply is queued to main before the `playback-restart` delivery, so the HDMI decision lands before the adapter reacts to the restart. |
| `MPV_EVENT_LOG_MESSAGE` | Drop if backgrounded. Otherwise, if the data is present, dispatch `log-message`. |
| `MPV_EVENT_SHUTDOWN` and every other event (`MPV_EVENT_IDLE`, `MPV_EVENT_SEEK`, `MPV_EVENT_AUDIO_RECONFIG`, `MPV_EVENT_CLIENT_MESSAGE`, `MPV_EVENT_QUEUE_OVERFLOW` and so on) | Ignored. Do not add handling. |

### 6.7 Property observation

Internal observers are registered once the handle is published (section 6.2), each with its own reserved reply userdata: ten distinct values, none of them 0. Their deliveries update the bridge's caches and are never forwarded to the delegate. Registration order is not significant.

| Property | mpv format |
| --- | --- |
| `container-fps` | `MPV_FORMAT_DOUBLE` |
| `current-tracks/video/dolby-vision-level` | `MPV_FORMAT_INT64` |
| `current-tracks/video/dolby-vision-profile` | `MPV_FORMAT_INT64` |
| `deinterlace-active` | `MPV_FORMAT_FLAG` |
| `height` | `MPV_FORMAT_DOUBLE` |
| `video-params/colormatrix` | `MPV_FORMAT_STRING` |
| `video-params/gamma` | `MPV_FORMAT_STRING` |
| `video-params/primaries` | `MPV_FORMAT_STRING` |
| `video-params/sig-peak` | `MPV_FORMAT_DOUBLE` |
| `width` | `MPV_FORMAT_DOUBLE` |

`estimated-vf-fps` is never observed; it is only read synchronously (section 8).

Caller observations through `observeProperty(_:format:)`:

- Format strings map to mpv formats: `double` to `MPV_FORMAT_DOUBLE`, `flag` to `MPV_FORMAT_FLAG`, `node` to `MPV_FORMAT_NODE`, `string` to `MPV_FORMAT_STRING`. Any other string (including `int64`) is silently ignored and nothing is observed.
- Registered with `mpv_observe_property(handle, 0, name, format)` (reply userdata 0) while the handle is live; a silent no-op without one; status ignored. There is no unobserve API.
- The adapter registers, in this order: `time-pos` double, `duration` double, `pause` flag, `paused-for-cache` flag, `seeking` flag, `eof-reached` flag, `track-list` node, `chapter-list` node, `aid` string, `sid` string, `secondary-sid` string, `video-params` node, `video-out-params` node, `audio-out-params` node, `audio-codec-name` string, `hwdec-current` string, `container-fps` double, `demuxer-cache-duration` double, `demuxer-cache-state` node, `avsync` double, `frame-drop-count` double.
- `container-fps` is therefore observed twice. mpv sends two change events: the internal one updates the caches only; the userdata-0 one updates the same caches again and is delivered. Internal observations must be suppressed by reply userdata, never by property name, or `container-fps` stops reaching the adapter.

### 6.8 Converting a property change to a Swift value

The value is decided by the change event's format, not by the format requested:

| Change event format | Swift value |
| --- | --- |
| `MPV_FORMAT_DOUBLE` | `Double` (no finiteness filtering) |
| `MPV_FORMAT_INT64` | `Int64` |
| `MPV_FORMAT_FLAG` | `Bool` (non-zero is true) |
| `MPV_FORMAT_STRING` | `String` decoded with section 6.16.1 (no size budget); nil if the C string pointer is null |
| `MPV_FORMAT_NODE` | the result of node conversion (section 6.16.2), which may itself be nil |
| any other format, including `MPV_FORMAT_NONE` (property unavailable) | nil |
| null data pointer | nil |

A nil value is still processed and, unless suppressed, still delivered (callers treat nil as unavailable).

### 6.9 What a property change does

Every change event first updates the bridge's own state and is then either delivered or suppressed. The state is always updated, even for a change that is then suppressed (an internal observation, or a non-critical property while backgrounded); that is the whole point of the internal observers.

Effects by property name, whichever observation delivered the change:

| Property | Effect |
| --- | --- |
| `container-fps` | When the value is a `Double`: stored, and a cached display apply is scheduled (section 8.6). |
| `current-tracks/video/dolby-vision-level`, `current-tracks/video/dolby-vision-profile` | When the value is an `Int64`: stored, and an apply is scheduled. |
| `deinterlace-active` | When the value is a `Bool`: stored, and an apply is scheduled. |
| `height`, `width` | When the value is a `Double`: stored as the size. For any non-nil value: an apply is scheduled. |
| `pause` | When the value is a `Bool`: a pause observation (section 6.12). |
| `video-params/colormatrix`, `video-params/gamma`, `video-params/primaries` | When the value is a `String`: stored, and an apply is scheduled. |
| `video-params/sig-peak` | When the value is a `Double`: stored as the signal peak, an EDR update with this value is enqueued on main (section 8.15), and an apply is scheduled. |

An unavailable or wrongly typed value never changes a display cache and never schedules an apply; only the restart snapshot (section 8.4) writes defaults. Reason: such a value says nothing reliable about the stream that is about to be shown.

Delivery: after those effects, the change is suppressed if its reply userdata is one of the internal observer values, or if the core is backgrounded and the name is not one of `duration`, `eof-reached`, `pause`, `paused-for-cache`, `seekable` or `time-pos`. Otherwise it goes to ordered delivery (section 6.10) with the source id remembered when the event was handled.

### 6.10 Ordered delivery and coalescing *Vivid (`128014c`)*

Goal: main sees properties and events in mpv's order, except that four high-frequency properties are merged, so a main thread that falls behind receives only their newest values instead of a backlog.

Coalesced properties: `time-pos`, `avsync`, `demuxer-cache-state`, `demuxer-cache-duration`. Every other property and every event dispatched through `dispatchDelegateEvent` is "ordered".

State, under the coalescing guard: an ordered list of pending coalesced values (at most one entry per property name, each holding name, value and source id); the token of the one scheduled flush entitled to deliver that list, or none; and a token counter (wrapping arithmetic).

Rules:

- A coalesced value whose name is already pending replaces that entry in place, keeping the entry's original position. A new name is appended.
- If no flush is scheduled when a coalesced value arrives, allocate a new token, record it as the scheduled one and enqueue one main block carrying it. If a flush is already scheduled, enqueue nothing.
- An ordered item first takes the whole pending list and clears the scheduled token, synchronously on the calling thread, then enqueues one main block that delivers the taken list in order followed by the item itself.
- A flush block on main checks, under the guard, whether its token is still the scheduled one. If not, its values have already gone out ahead of a later ordered item, and it does nothing. If so, it takes the list and clears the token; then, only if the core is not terminal, delivers the list. If terminal, the taken values are discarded.
- Every main block for an ordered item first checks that the core still exists (weak capture) and is not terminal. If either fails it delivers nothing, including the pending values it carried.
- The delegate is read at delivery time on main.
- No timers: coalescing depends only on how far main lags.

`dispatchDelegateEvent` data rule: if a source id is given, the payload becomes the given dictionary (or a new empty one if nil) with key `sourceId` set to the `Int64` id; if no source id is given, the data is passed through unchanged, possibly nil.

Worked scenarios (the three unit tests, which must pass unchanged):

| Dispatches from a background queue while main is blocked | Main receives |
| --- | --- |
| `time-pos` 1, `avsync` 0.01, `time-pos` 2, `pause` true, `time-pos` 3, event `seek`, `time-pos` 4, `time-pos` 5 | `time-pos` 2, `avsync` 0.01, `pause` true, `time-pos` 3, event `seek`, `time-pos` 5 |
| `time-pos` 1, main drains; `time-pos` 2, main drains; `time-pos` 3, main drains | `time-pos` 1, 2 and 3 |
| `time-pos` 1, then `beginDisposal()`, then main drains | nothing |

Events that bypass ordered delivery: `display-criteria-prepared` and, **[debug-only]**, `display-switch-started` and `display-switch-ended` call the delegate directly on main without taking the pending list. A coalesced value pending at that moment goes out later with its flush or the next ordered item.

### 6.11 Background filtering

While the core is marked backgrounded (section 6.18):

- only `duration`, `eof-reached`, `pause`, `paused-for-cache`, `seekable` and `time-pos` property changes are delivered; every other property change is dropped after the caches are updated (it is not queued for later);
- every `log-message` is dropped;
- everything else continues: caches, other events, request completions and display work.

This applies whenever the core is backgrounded, including while Picture in Picture runs in the background.

### 6.12 Pause cache

Purpose: decide whether iOS scene activation needs the paused redraw (section 6.18), using a "displayed" pause state that follows the adapter's requests at once and falls back to what mpv confirms. Only `setProperty("pause", ...)` and `setPropertyAsync("pause", ...)` create requests. A value of `1`, `true`, `yes` or `on`, in any letter case, means paused; anything else means playing. The original string is sent to mpv unchanged. The bookkeeping is the implementer's choice; these rules must hold, under the cache guard:

- Initially both the displayed and the confirmed state are paused.
- A new request sets displayed to its value at once.
- A request resolves when its completion arrives, whatever the result: success, mpv error, no handle, or cancellation at disposal. The resolution is applied before the caller's completion runs. If the core has gone by then, only the caller's completion runs.
- Requests are ordered by when they were made. A request that resolves after a newer request has already resolved changes nothing.
- When a request resolves, every older request still outstanding is retired with it and no longer counts as outstanding.
- A successful resolution sets confirmed to the request's value, unless a `pause` observation arrived after the request was made; then the observation's value stands. A failed resolution leaves confirmed unchanged.
- A `pause` observation (a `Bool`) always sets confirmed. It also sets displayed, but only when no request is outstanding.
- After every resolution, displayed is the value of the newest outstanding request, if there is one, otherwise confirmed.

| Sequence (start: displayed and confirmed paused, nothing outstanding) | Displayed after | Confirmed after |
| --- | --- | --- |
| request play, reply success, no observation | playing | playing |
| request play, observation "playing" before the reply, reply success | playing | playing (from the observation) |
| request play, reply failure | paused (reverts) | paused |
| request play (1), request pause (2), reply 1 success, reply 2 success | paused (after reply 1 it stays paused because request 2 is outstanding) | paused |
| request pause (1), request play (2), reply 2 success, then reply 1 success | playing (the late reply 1 changes nothing) | playing |
| request pause (1), request play (2), reply 2 success, observation "paused", then reply 1 success | playing after reply 2, then paused from the observation onwards (request 1 was retired when request 2 resolved, so it does not block the observation) | paused |
| request play, mpv reports paused (for example at end of file) before the reply, reply success | paused (the observation wins) | paused |
| observation "playing" with nothing outstanding | playing | playing |

### 6.13 Commands and property requests

#### 6.13.1 Request numbering and the pending table

- Each core numbers its asynchronous requests with its own `UInt64` counter starting at 1, incrementing by 1. The number is the request's reply userdata.
- A request (number, kind "set", "get" or "command", and completion) is registered immediately before its mpv submission, under the liveness guard, so registration and submission happen only while a live handle exists.
- On a reply, the entry is removed by number. A reply with no entry (unknown, or already cancelled by disposal) is ignored. Every completion therefore runs at most once, and exactly once in practice.

#### 6.13.2 Replies

| Reply | Completion |
| --- | --- |
| `MPV_EVENT_SET_PROPERTY_REPLY`, negative `error` | failure with an mpv error (section 10.1) |
| `MPV_EVENT_SET_PROPERTY_REPLY`, otherwise | success |
| `MPV_EVENT_COMMAND_REPLY`, negative `error` | failure with the mpv error |
| `MPV_EVENT_COMMAND_REPLY`, otherwise | success with the `Int64` value of the first `playlist_entry_id` key in the command's result map, read before the next event is fetched; nil when the result is not a map, has no such key, or that key's value is not `MPV_FORMAT_INT64`. In practice only `loadfile` yields an id. |
| `MPV_EVENT_GET_PROPERTY_REPLY`, negative `error` | failure with the mpv error (an unavailable property arrives as `MPV_ERROR_PROPERTY_UNAVAILABLE`) |
| `MPV_EVENT_GET_PROPERTY_REPLY`, otherwise | success with `String?`: the decoded string when the reply's format is `MPV_FORMAT_STRING` and both its data pointer and string pointer are non-null, otherwise nil |

Every reply completion is delivered with `DispatchQueue.main.async`, in the order the replies were drained.

#### 6.13.3 Inline or asynchronous completion

An inline-or-main helper calls the completion immediately when already on the main thread, otherwise enqueues it on main. It is used for:

- `setPropertyAsync` and `getPropertyAsync` on a terminal core (failure);
- any submission attempted without a live handle, whether terminal or never created (failure);
- `commandAsync` with an empty argument array (success with nil; this path does not check liveness at all).

Always `DispatchQueue.main.async`, never inline: a negative status returned by the `*_async` submission call (the request is taken back out of the table and failed with the mpv error), every reply, and every cancellation at disposal.

The adapter wraps several completions in `withCheckedThrowingContinuation`. The inline path resumes the continuation synchronously, which is fine; a completion must never run twice or zero times.

#### 6.13.4 The request methods

- `setPropertyAsync(_:value:completion:)`:
  1. If the core is terminal, fail inline-or-main with the not-available error (section 10.1). (A core that is not terminal but has no handle passes this check and then fails the same way at submission.)
  2. If the name is `pause`, begin a pause intent (section 6.12), send the original string, and when the reply arrives finish the intent and then call the caller's completion.
  3. Otherwise send the value as a string property.
- "Send as a string property" means `mpv_set_property_async(handle, number, name, MPV_FORMAT_STRING, &cString)`, registered as a "set" request.
- `setProperty(_:value:)` is `setPropertyAsync` with an empty completion.
- `getPropertyAsync(_:completion:)`: terminal check as above, then `mpv_get_property_async(handle, number, name, MPV_FORMAT_STRING)`, registered as a "get" request. Callers parse numbers from the string themselves (the adapter uses `Double(_:)`).
- `commandAsync(_:completion:)`: an empty array completes as in section 6.13.3. Otherwise build NUL-terminated C copies of the arguments and a null-terminated pointer array, submit with `mpv_command_async`, registered as a "command" request, and free the copies after the submission call returns whatever the outcome (mpv copies the arguments during the call).
- `command(_:)` is `commandAsync` with an empty completion.

#### 6.13.5 Ordering

- Requests reach mpv in call order, because submission is synchronous within each call. The adapter relies on this (for example, it queues `seek 0 relative+exact` immediately before an `audio-spdif` change).
- mpv decides the order of replies (a `loadfile` reply can arrive after replies to later property sets). The bridge adds no reordering.
- Completions and delegate deliveries share the main queue, so a completion and a property change produced by the same drain arrive in drain order, except that coalesced properties can be merged or delivered later (section 6.10).

#### 6.13.6 Writes the bridge makes on its own

| Trigger | Write |
| --- | --- |
| Background notification, Picture in Picture not active | `setProperty("vid", "no")` |
| Foreground notification, Picture in Picture not active | `setProperty("vid", "auto")` |
| iOS scene activation, Picture in Picture not active | `setProperty("vid", "auto")`, then the paused redraw below when the displayed pause state is paused |
| Paused redraw | `command(["seek", "0", "relative+exact"])` |
| `on_preloaded` hook | synchronous `mpv_set_property_string(handle, "aid", <id as decimal string>)` |
| `setPipSubtitleCompositing` (iOS) | `avfoundation-pip-composite-osd` = `yes` or `no` |

### 6.14 Synchronous reads

Only on the event queue (assert it). Each copies the handle under the liveness guard and calls `mpv_get_property` without it (section 5.3 rule 5). Each returns nil when there is no live handle or mpv returns a negative status.

| Shape | mpv format | Result |
| --- | --- | --- |
| number | `MPV_FORMAT_DOUBLE` | `Double`, nil if not finite |
| flag | `MPV_FORMAT_FLAG` (32-bit integer) | `Bool`, non-zero is true |
| map | `MPV_FORMAT_NODE` | node conversion cast to `[String: Any]`, nil if not a map; the node is freed with `mpv_free_node_contents` after conversion |
| list of maps | `MPV_FORMAT_NODE` | node conversion cast to `[[String: Any]]` (the whole cast fails, giving nil, if any element is not a map); node freed after conversion |

Reads made: `estimated-vf-fps`, `container-fps`, `time-pos` (number); `deinterlace-active` (flag); `video-params`, `video-out-params`, `current-tracks/video` (map); `track-list` (list of maps).

### 6.15 Preload audio choice *Vivid (`8268108`)*

Purpose: when the playback plan names an audio track, select it inside `on_preloaded`, which mpv runs once the file's tracks are known but before its own default track pick and before the initial seek. Selecting it any later makes a resume seek twice.

- The hook is registered only when `selectsAudioWhilePreloading` was true during set-up.
- On the hook, on the event queue: read `track-list` as a list of maps; ask `preloadedAudioTrackID(tracks:)` for an id; if both succeed and the handle is live, set `aid` synchronously with `mpv_set_property_string` to the id rendered with Swift's default decimal `String` conversion, status through the error check with option name `aid`. Any nil along the way leaves mpv's own choice.
- The hook is always continued afterwards (section 6.6).

### 6.16 Value conversions

#### 6.16.1 C strings

Applies to every C string the bridge receives from mpv: property names, string property values, get-property replies, log prefix, level and text, end-file error messages, `mpv_error_string` results and hook names. mpv may hand over bytes that are not UTF-8.

Rule: decode the NUL-terminated bytes as UTF-8 if they are valid UTF-8; otherwise map every byte before the NUL to the Unicode scalar with the same value (a Latin-1 reading). Never fail and never return nil for a non-null pointer; never produce replacement characters.

#### 6.16.2 Node conversion (`convertNode(_:)`)

This is the most cast-sensitive part of the contract: `track-list`, `chapter-list`, `video-params`, `video-out-params`, `audio-out-params`, `demuxer-cache-state` and the subtitle inventory probe all go through it.

Results by node format (children of arrays and maps are converted one level deeper):

| Node format | Swift result |
| --- | --- |
| `MPV_FORMAT_INT64` | `Int64` (never `Int`) |
| `MPV_FORMAT_DOUBLE` | `Double`, including NaN and infinities |
| `MPV_FORMAT_FLAG` | `Bool`, non-zero is true |
| `MPV_FORMAT_STRING` | `String`, decoded with section 6.16.1 |
| `MPV_FORMAT_BYTE_ARRAY` | `Data` (empty for size 0) |
| `MPV_FORMAT_NODE_MAP` | `[String: Any]` in entry order. An entry whose key is null or cannot be converted, or whose value converts to nil, is left out; a repeated key keeps its last converted value. The whole map is nil if it fails the dimension rule (section 6.16.3), which is checked before any entry is converted. |
| `MPV_FORMAT_NODE_ARRAY` | `[Any]` in order, leaving out children that convert to nil (later elements shift down; never padded) |
| `MPV_FORMAT_NONE` or anything else | nil |

Budget, as invariants. Each top-level call has its own budget, shared by the whole tree: 4,096 nodes and 16,777,216 bytes (16 MiB) of string and byte-array data. The root is at depth 0.

- A node deeper than 32, or reached when the node budget is used up, converts to nil. Every other visited node uses one unit of the node budget before anything else is checked.
- A string or byte array uses its length in bytes. One longer than the bytes left converts to nil, and measuring a string never reads further than the bytes left allow (plus its terminator).
- A map key uses bytes like a string but no node unit. When a key cannot be converted, its entry is skipped and its value is never visited; when a value converts to nil, its key's bytes stay used.
- An array or map converts to nil when its count is negative, when its count exceeds the node units left after its own unit, or when its count is above 0 but its storage is missing (no values, or for a map no keys).
- A null string, byte-array or list pointer converts to nil, as does a byte array with a size above 0 and no data.

Consequences callers depend on: flags stay `Bool`, integers stay `Int64`, fractions stay `Double`; an `[Any]` whose elements are all `[String: Any]` casts to `[[String: Any]]`, and a single non-map element makes that cast fail; the function uses no instance state and must work on a bare instance on any thread.

#### 6.16.3 Dimension check

The side-data dimension check takes two `Int64` values and passes exactly when both are above 0, both are at most 16,384, and width times height, computed without overflow, is at most 67,108,864 (64 x 1,024 x 1,024). It is used by the early snapshot, by the tvOS platform write and by this map rule:

Map rule (applied to every map before its entries are converted): scan all entries. If no value in the map is a byte array, or the map has neither a `width`/`w` key nor a `height`/`h` key, the map passes. Otherwise both a width-like and a height-like entry must exist (when a key appears more than once the last occurrence counts; entries with null keys are skipped for this lookup but still count towards "has a byte array"); each value must convert to `Int64` (an `MPV_FORMAT_INT64` value as is, or an `MPV_FORMAT_DOUBLE` value that is finite, integral and exactly representable as `Int64`); and the pair must pass the dimension check. The scan compares raw key bytes and uses none of the budget. (The current bridge traps on a double of exactly 2^63 here; the replacement may reject it instead.) Failing makes the whole map nil. Purpose: reject attacker-sized side data (for example an embedded image) before allocating for it.

#### 6.16.4 Other conversions

- `end-file`: `reason` is the raw value of mpv's end-file reason as a Swift `Int`, and `error` is the event's error field as a Swift `Int`.
- A failed mpv status becomes an `NSError` whose code is the status and whose localised description is that status's `mpv_error_string`, decoded with section 6.16.1. The domain is the implementer's choice (section 10.1).

### 6.17 Disposal

#### 6.17.1 `beginDisposal()`

Under the liveness guard: if already terminal, return false; otherwise mark terminal and return true. Marking terminal alone immediately makes later requests fail, queued delivery blocks drop their payloads and drains stop. It destroys nothing. It must work on a bare instance that never had a context.

#### 6.17.2 `dispose(preserveDisplayCriteria:completion:)`

Required order, with reasons:

1. Call `beginDisposal()`. If it returns false, return at once without calling this call's completion. Reason: `deinit` also disposes, and only the first dispose does the work.
2. tvOS, unless `preserveDisplayCriteria` is true: clear the display criteria synchronously, before `dispose` returns, through the `avDisplayManager` of the container's window, else the remembered window (section 8.13). If neither exists, nothing is cleared. This clear is not gated by `matchContentEnabled` or by the system's matching setting. Reason: the adapter lets go of the core as soon as `dispose` returns, so the clear cannot wait for a later turn, and it must run while the container, if any, is still in its window.
3. Remove every notification observer this core registered and, on iOS, detach from the external-display coordinator (in either order).
4. The shared teardown below, which queues mpv's destruction.
5. The UIKit teardown below, after the destruction has been queued, without waiting for it.

Shared teardown:

- Every pending request is taken out of the table and failed with the disposed error (section 10.1), asynchronously on main. Replies that arrive later find no entry.
- Under the cache guard only (not the source-transition exclusion), the hold is set and these caches are cleared: Dolby Vision profile and level, container frame rate, signal peak and measured cadence to 0; deinterlace to false; transfer, primaries and matrix to absent. Left as they are (all harmless once disposed): width, height, the pause state, the epoch, the "early snapshot wanted" and "apply scheduled" flags, the visible mark and the remembered source id.
- Under the liveness guard, the core is marked disposed and its handle and relay pointer are taken out of the state. The relay is then detached (its weak core reference cleared under its own guard), so no new drain can be scheduled even if mpv calls the wakeup callback again.
- The destroy step is enqueued on the event queue: if there was a handle, clear its wakeup callback with `mpv_set_wakeup_callback(handle, nil, nil)` and then call `mpv_terminate_destroy`; if there was a relay, drop the manual retain; finally call the completion, if given. Any drain already queued or running finishes first, and drains that run later find no handle. The completion therefore runs on the event queue, exactly once, even when no handle was ever created.
- Capture rule: the destroy step and every block that disposal enqueues (including the request failures) capture only plain values: the handle, the relay pointer, the completion, the pending completions and their error. Never the core, strongly or weakly. Reason: disposal can run inside the core's `deinit`, where enqueuing a block that refers to the core, even weakly, crashes the app.

UIKit teardown, as the end state once `dispose` returns: no layer (`sampleBufferDisplayLayer` is nil and the layer has left its parent); no container in any view; no cover view; not initialised. The remembered window and host view are kept (section 14.1). The host view is untouched and shows its black background until the next load's container arrives. On iOS, an adopted external window stays up. Removing the layer before mpv is destroyed is safe because the engine's video output keeps its own reference to the layer until its own teardown (section 7.2).

#### 6.17.3 What happens to work in flight

| In flight when `dispose` starts | Outcome |
| --- | --- |
| A pending request | Fails once with the disposed error, asynchronously on main. |
| A reply already taken by a drain before the pending requests are taken out | Its normal completion is delivered. |
| A request submitted after `beginDisposal` | Fails with the not-available error, inline when called on main. |
| Queued ordered delivery blocks | Dropped by the terminal check on main. |
| A queued coalescing flush | Takes and discards the pending values. |
| A queued cached display apply | Sees the hold and commits nothing (it has no terminal check of its own; see section 14.1 for the one exception). |
| A queued early display write | Sees the terminal state and does nothing. |
| Queued EDR updates | Still run (they keep the core alive and do not check the terminal state); after dispose there is no layer, so they do nothing. |
| A drain in the middle of an event | Finishes that event (its synchronous reads now return nil because the handle has left the state), then stops. |
| Wakeups after the relay is detached | Ignored by the relay. |

The adapter's `stop()` relies on this: it clears `delegate`, enters a shared `DispatchGroup`, calls `dispose(preserveDisplayCriteria:)` with a completion that leaves the group, then drops its reference. Audio session deactivation waits on that group.

#### 6.17.4 Second dispose and `deinit`

A second `dispose` is a complete no-op, including not calling its completion. The core's `deinit` runs `dispose()` with defaults: a no-op after an explicit dispose; on tvOS, if the owner never disposed, it clears the display criteria. If the last release happens off main (section 15), that `dispose` would run its UIKit teardown off main; the adapter always disposes first, so in practice `deinit` does nothing.

### 6.18 App lifecycle

Registration (in `initialize`, after mpv set-up succeeds). Handlers must run synchronously on the posting thread (selector-based observers, or block observers with a nil queue):

| Platform | Notifications | Object |
| --- | --- | --- |
| iOS | `UIScene.didEnterBackgroundNotification`, `UIScene.willEnterForegroundNotification`, `UIScene.didActivateNotification` | the `windowScene` of the window passed to `initialize`, read at registration time. If that window has no scene at that moment, the object is nil and the core reacts to every scene's notifications (including an external display scene). Keep this. |
| tvOS | `UIApplication.didEnterBackgroundNotification`, `UIApplication.willEnterForegroundNotification` | nil |
| tvOS, **[debug-only]** | `AVDisplayManagerModeSwitchStart`, `AVDisplayManagerModeSwitchEnd` | nil (section 8.16) |

All of them are removed in `dispose`.

Behaviour:

| Notification | Behaviour |
| --- | --- |
| Entered background | First call `onEnterBackground`, if set, before anything else, so the adapter's hook (on iOS: pause unless background playback is enabled or Picture in Picture is active) sees the state before the bridge changes it. Then mark the core backgrounded and, unless Picture in Picture is active, `setProperty("vid", "no")`. Display criteria on tvOS are untouched. |
| Will enter foreground | Clear the backgrounded mark and, unless Picture in Picture is active, `setProperty("vid", "auto")`. Nothing else. |
| Did activate (iOS only) | Clear the backgrounded mark. If Picture in Picture is active, do nothing more. Otherwise: `setProperty("vid", "auto")`; the placement refresh (section 9.3); `flush()` on the layer if its `requiresFlushToResumeDecoding` is true or its `status` is `.failed` (never `flushAndRemoveImage`); EDR with the cached signal peak; and, if the displayed pause state (section 6.12) is paused, the paused redraw `seek 0 relative+exact`. Required order: the `vid` write is issued before the redraw seek, so mpv receives them in that order. The other actions all happen on main in the same turn, and their relative order is not observable. |

What `vid=no` and `vid=auto` do in the engine: with `force-window` unset (mpv 0.41), deselecting video destroys the engine's video output and selecting it again creates a new one. Backgrounding without Picture in Picture is therefore a full teardown: the picture is removed (the layer shows its black background) and the engine's subtitle layer and its control of the layer's timing go with it. Returning builds a new video output with a new subtitle layer and new timing. That needs the layer still in its container (it always is) and main free to answer the engine (section 5.3). Audio continues while video is deselected, if playback was not paused.

Did activate also fires on returns that never backgrounded (Control Centre, notification banners, alerts, an app-switcher peek). Screen lock behaves as background followed by foreground and activation on unlock. The engine also recovers its own presentation when the app becomes active again; the bridge's recovery is additional and must stay.

The bridge handles no memory warnings, thermal state changes, audio session interruptions or route changes, and never touches `AVAudioSession`. Do not add any.

### 6.19 Audio-output options (set by the adapter, for context)

The bridge sets no audio option, never touches `AVAudioSession`, and must never override the options below. Its only duty is to run the adapter's options hook at the right moment (section 6.2). These options belong to the engine's AVFoundation audio output; upstream mpv's manual does not describe them, so their meaning is recorded here.

| Option | Value the adapter sets | Meaning |
| --- | --- | --- |
| `ao` | `avfoundation` | The engine's AVFoundation audio output. At normal speed, AC-3 and E-AC-3 that `audio-spdif` allows are passed through compressed via an `AVPlayer` resource loader; everything else is decoded to PCM and played through sample-buffer audio. The audio output schedules audio and drives mpv's audio clock, and video follows that clock. |
| `audio-spdif` | `ac3,eac3` at rate 1, otherwise empty | Which codecs may be passed through compressed. The adapter changes it with the playback speed (seeking in place first on AC-3 and E-AC-3, so queued audio for the old output is dropped). |
| `audio-exclusive` | `yes` | Upstream mpv option. It has no effect on this audio output. |
| `audio-channels` | `7.1,5.1,stereo` on tvOS when the route is AirPlay at load time, otherwise `auto-safe` | The PCM layouts the output may use. |
| `ao-avfoundation-manage-audio-session` | `no` | The output neither activates nor deactivates the shared `AVAudioSession` and sets no category or mode. It still declares multichannel content (passthrough, or more than two channels) and sets the preferred output channel count for decoded audio. Vivid activates the session and waits for the `dispose` completions of retired cores before deactivating. |
| `ao-avfoundation-max-lookahead` | `4` (tvOS, AirPlay route only) | Limits PCM read-ahead to four seconds. |
| `ao-avfoundation-compressed-anchor-start` | `yes` (tvOS, AirPlay route only) | On AirPlay, `AVPlayer`'s clock stays parked at start-up until the output's seek-to-start recovery runs. With this on, video stays anchored to the parked audio clock, so it waits for the audio instead of running ahead. |
| `ao-avfoundation-compressed-start-grace` | `1` (tvOS, AirPlay route only) | Seconds after the rate is applied before that recovery runs (one instead of two), then before falling back to decoded audio if the clock still has not moved, extended by the same amount each time a slow source delivers more. Seeks and resumes engage sooner than this, so they do not trigger it. |
| `ao-avfoundation-compressed-first-start-grace` | `0.25` (tvOS, AirPlay route only) | For the first start of each audio output instance (until its clock first moves; on an AC-3 or E-AC-3 track, every speed change across 1x creates a new instance, section 17.11), run the recovery this soon after the item is ready, capped at `ao-avfoundation-compressed-start-grace`. Later seeks and resumes on the same instance use that grace. |
| `ao-avfoundation-compressed-anchor-resume` | `yes` (tvOS, AirPlay route only) | After a pause, anchor mpv to AirPlay's clock as at start-up, so video waits for the audio instead of running ahead and then stopping to resynchronise. |
| `ao-avfoundation-compressed-buffer` | `1.25` (tvOS, AirPlay route only) | Seconds of compressed audio queued before starting (instead of two), kept above the output's one-second priming reserve. |

These options belong to Vivid's own engine (the Lucid Engine patch specification). A build that still links the third-party package without the old driver rebuild rejects them; the console then shows, through the error check (section 10.2), one `MPV error: option not found option=ao-avfoundation-manage-audio-session at <module>/VividMPVPlayer.swift:<line>` line on every load (the module is `Vivid` on iOS and `VividTV` on tvOS) and, on tvOS with an AirPlay route, five more `MPV error: option not found at ...` lines with no `option=` detail, because the adapter does not pass the name for those. Playback continues without the options' effects.

## 7. Video surface and the video-output contract

### 7.1 Who draws the picture

The bridge does not render. It creates one `AVSampleBufferDisplayLayer` subclass per core, hands that layer to the engine as `wid`, and selects the engine's sample-buffer video output with `vo=avfoundation`. From then on the engine alone puts pictures on the layer, controls its timing and draws subtitles. Hardware-decoded frames keep the decoder's own colour tags; only software uploads are tagged from mpv's parameters. Nothing in the bridge touches pictures or their tags.

The bridge never calls any `mpv_render_context_*` function, never creates a `CAMetalLayer`, never creates or tags pixel buffers, never sets the layer's `controlTimebase`, never enqueues a sample buffer and never flushes the layer except for the recovery in section 6.18. Do not add any of these: the engine already owns them, and two owners would fight.

### 7.2 The video-output contract

This is the complete contract between the bridge and the engine's sample-buffer video output: what the bridge guarantees, the options it uses, and the engine behaviour it relies on. The engine rewrite keeps the same contract (section 2).

What the bridge guarantees:

| Guarantee | Reason |
| --- | --- |
| `wid` is the address of the core's `AVSampleBufferDisplayLayer` subclass, passed as a 64-bit integer with `mpv_set_option` and `MPV_FORMAT_INT64` before `mpv_initialize`, without the bridge retaining the layer for it. Any other object, or a released layer, crashes the engine; a retain taken for `wid` would leak the layer. | The engine reads the value as a pointer to the display layer and draws into it. |
| The layer is in its final parent (the container's layer) before any file loads and every time the engine creates its video output, and only the parent ever moves, never the layer on its own. | The engine creates its video output when a file first selects video, and again whenever video is selected after `vid=no` (section 6.18). This includes audio-only loads with embedded cover art, which get a video output whenever `vid=auto` selects the artwork. Each time, it adds its own subtitle layer next to the video layer, in the same parent. |
| One new layer per core, never shared between two mpv contexts. | The engine takes control of the layer's contents and timing for its context. |
| After creation, `bounds` and `contentsScale` are written only with their exact final values, with implicit animations disabled, and `bounds` and `position` are always set together (section 7.5). | The engine sizes its output, including subtitle resolution, from `bounds` and `contentsScale` only, and it visibly re-lays out separate-layer subtitles whenever either changes. It does not follow `position` on its own. |
| The main thread never blocks waiting on mpv, and a stored context is never destroyed from main (section 5.3). | The engine waits synchronously for the main thread while creating, reconfiguring and tearing down the video output (creation happens at load and at every `vid=auto`), when reading geometry (including on the first frame after any subtitle-layer resynchronisation) and when recovering the layer, so a main thread blocked on mpv deadlocks playback. |
| The bridge never sets `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x` or `video-scale-y`. | The engine never re-renders, scales or moves the picture for these options, so they have no effect on it. mpv still applies them to the rectangle that separate-layer subtitles are placed against, so subtitles would move away from the picture. Vivid has no viewer zoom (section 13), so nothing needs them. |
| The bridge never sets `panscan` or `video-aspect-override`. | The engine handles these without re-rendering, but fitting the picture belongs to the adapter's `videoGravity` on the layer (section 7.4), and the current bridge never sets them. |
| The bridge never touches the layer's `controlTimebase`. | The engine creates and drives it. |
| The bridge may remove the layer from its parent before mpv is destroyed (section 6.17.2). | The engine keeps its own reference to the layer from creating its video output until tearing it down. |

Engine options the bridge uses, and what they mean:

| Option | Meaning |
| --- | --- |
| `vo=avfoundation` | Use the sample-buffer video output that draws into the `wid` layer. |
| `avfoundation-composite-osd=no` | Accepted by the engine and otherwise without effect. Subtitles and OSD are on the engine's separate layer except while `avfoundation-pip-composite-osd` is `yes`. |
| `avfoundation-pip-composite-osd` | `yes`: subtitles are drawn into the video pictures themselves, so Picture in Picture, which shows only the pictures, shows them. `no`: subtitles go back to the separate layer. Switched at run time by `setPipSubtitleCompositing` (section 9.5); the bridge needs no extra geometry handling when it switches. |
| `avfoundation-presentation` | `host`: pictures are presented on the device clock at the times mpv schedules. `media`: presentation follows the media timeline, which Picture in Picture requires. The bridge sets `host` on tvOS devices; iOS relies on the engine's default, which must be `media`. |

Engine behaviour the bridge relies on:

| Behaviour | Consequence for the bridge |
| --- | --- |
| A seek does not blank the picture: the current picture stays until the first picture at the new position is ready. | The paused redraw is `seek 0 relative+exact`, which shows the paused frame again without a black flash. Never replace it with a layer flush-and-remove or an engine reset. |
| Deselecting video (`vid=no`) destroys the video output, which removes the picture, the subtitle layer and the engine's control of the layer's timing; selecting video again (`vid=auto`) creates a new one. | Background and return (section 6.18) are a full teardown and rebuild. |
| The engine recovers its own presentation when the app becomes active again. | The bridge's activation recovery (section 6.18) is additional and must stay. |
| With `keep-open=yes` the engine stays paused on the last frame at the end of a file. | Keep the option; Next Up relies on that picture. |
| HDR and Dolby Vision pictures reach the layer with their colour information and per-frame metadata intact, and the engine does no tone mapping. | HDR presentation is decided by the display criteria on tvOS and by EDR on the layer on iOS (section 8). |

### 7.3 View and layer tree

From outermost to innermost:

| Element | Owner | Properties |
| --- | --- | --- |
| Host view | The adapter (`VividMPVHostView`, one per adapter, persistent across loads) | Black background, user interaction off. Calls `updateFrame()` on every `layoutSubviews`. |
| Container view | The bridge, one per core | Plain `UIView`, black background, user interaction off. Subview index 0 of the host view (or of the external root view, section 9). |
| Video layer | The bridge, one per core | `VividSampleBufferLayer`; opaque, black background, initial `videoGravity` `.resizeAspect`; a direct sublayer of the container's layer. |
| Subtitle and OSD layer | The video output | Sibling of the video layer inside the container's layer. The bridge never touches it. |
| Cover view (iOS) | The bridge, only while video is on an external screen | Section 9.4. |
| External window and root view (iOS) | The external-display coordinator | Section 9.2. |

`PlayerSurfaceLayoutTests` asserts this two-level nesting (layer directly in the container's layer, container directly in the host view) and one new layer per load with the host view never replaced. Keep both.

### 7.4 Gravity

The adapter owns the viewer's gravity choice and writes it straight onto `sampleBufferDisplayLayer?.videoGravity` whenever it changes and once after each `initialize`. The bridge does not intercept, animate or override it.

### 7.5 Geometry updates (`updateFrame`)

Called on main by the host view's `layoutSubviews` (every layout pass, including rotation, iPad split-view resizing, preview and full-screen transitions), by the adapter when Picture in Picture starts or stops, and by the placement refresh. It does nothing if the layer or the container no longer exists. Otherwise it establishes this end state within one `CATransaction` with actions disabled:

| Item | End state |
| --- | --- |
| Container | Frame equal to its superview's bounds; with no superview, the remembered window's bounds; with neither, unchanged. |
| Video layer | `bounds` with origin zero and the container's bounds size, and `position` at the centre of the container's bounds. `frame` is not assigned. |
| Cover view, if any | Frame equal to the remembered window's bounds, or `.zero` if the window has gone. |
| Layer `contentsScale` | Taken from the screen of the container's own window (so an external screen wins while the container is there), else the remembered window's screen, else `UIScreen.main`: that screen's `nativeScale` if above 0, otherwise its `scale`. |

On iOS, EDR is then applied with the cached signal peak (section 8.15), after the transaction, so EDR is re-asserted on every host layout pass. Rotation produces one snap per layout pass, never an animated stretch.

### 7.6 Options deliberately not set

| Option | Why it stays at the engine default |
| --- | --- |
| `video-sync` | Not set; engine default. |
| `interpolation`, `tscale` and other options of mpv's `gpu` video output | Not applicable to this video output. |
| `display-fps`, `override-display-fps` | Never set. The adapter only reads `display-fps` for diagnostics. |
| `tone-mapping`, `target-peak`, `target-trc`, `target-prim`, `hdr-compute-peak` | The video output passes decoded pixels through with colour tags and does not tone map. HDR is handled by the display (tvOS) or EDR (iOS). |
| `gpu-api`, `gpu-context` | Not used by this video output. |
| `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x`, `video-scale-y`, `panscan`, `video-aspect-override` | See section 7.2. |
| `deinterlace`, `vf`, `hwdec-image-format`, `vd-lavc-*` | Engine defaults. |
| `avfoundation-queue-lead-ms` | Video output default. |
| `avfoundation-presentation` on iOS | The default `media` is what Picture in Picture needs. |
| `force-window` | Not set. |

## 8. Match Content and HDR

### 8.1 Overview

On Apple TV the bridge asks for the HDMI frame rate and dynamic range that suit the decoded stream, by assigning `AVDisplayCriteria` to `preferredDisplayCriteria` on the `avDisplayManager` of the window showing the video, always on main. The inputs are the stream properties mpv reports (section 8.2). Nothing is written between files, so the TV stays in whatever mode it is in (section 8.3). Each file's criteria are then written from an early snapshot (section 8.5) or from the restart snapshot (section 8.4), and later observer changes are merged into single writes (section 8.6).

On iPhone and iPad the same caches and holds run, but nothing is written (section 8.15).

### 8.2 Inputs

| Input | From observers (available values only) | At playback restart (overwrites the cache) | Early snapshot | Default at restart when unavailable |
| --- | --- | --- | --- | --- |
| Dolby Vision profile | `current-tracks/video/dolby-vision-profile` | `dolby-vision-profile` of `current-tracks/video` (`Int64`) | same key of `current-tracks/video` | 0 |
| Dolby Vision level | `current-tracks/video/dolby-vision-level` | `dolby-vision-level` of `current-tracks/video` (`Int64`) | same | 0 |
| Container frame rate | `container-fps` | `container-fps` | `container-fps`, must be finite and above 0 | 0 |
| Measured output cadence | never observed | `estimated-vf-fps` | `estimated-vf-fps`, must be finite and above 0 | 0 |
| Deinterlacer active | `deinterlace-active` | `deinterlace-active` | `deinterlace-active`, must be readable | false |
| Width and height | `width`, `height` (`Double`) | `w`, `h` of `video-params` (`Int64`, stored as `Double`) | `w`, `h` of `video-out-params` (`Int64`), must pass the dimension check | 0 |
| Signal peak | `video-params/sig-peak` | `sig-peak` of `video-params` (`Double`) | `sig-peak` of `video-out-params` | 0 |
| Transfer (gamma) | `video-params/gamma` | `gamma` of `video-params` (`String`) | `gamma` of `video-out-params` | absent |
| Primaries | `video-params/primaries` | `primaries` of `video-params` | `primaries` of `video-out-params` | absent |
| Matrix | `video-params/colormatrix` | `colormatrix` of `video-params` | `colormatrix` of `video-out-params` | absent |

The early snapshot reads the decoded **output** parameters (`video-out-params`) while the restart snapshot reads `video-params`. Do not unify them.

### 8.3 The hold, the epoch and the source-transition exclusion *Vivid (`f347bb7`)*

State (under the cache guard): the hold flag (initially held); a source epoch (`UInt64`, wrapping); an "early snapshot wanted" flag; an "apply scheduled" flag; the cached inputs.

Transitions:

- **Start of file** (`MPV_EVENT_START_FILE`), before anything else for that event: take the source-transition exclusion, then the cache guard; reset the measured cadence to 0; advance the epoch; set "early snapshot wanted"; set held. Release the cache guard, then the exclusion.
- **End of file** (`MPV_EVENT_END_FILE`), before the `end-file` dispatch: the same, except "early snapshot wanted" is cleared and the cadence is left alone.
- **Playback restart**: the snapshot in section 8.4 releases the hold.
- **Dispose**: sets the hold and resets the caches (section 6.17.2).

Seeks do not engage the hold; they only produce another restart snapshot. Of the two holds, only the start-of-file hold resets the measured cadence.

**[debug-only]** Each start-of-file and end-of-file hold measures, with a monotonic clock in nanoseconds on the event queue, how long it waited to acquire the exclusion (`wait_ms`) and how long from acquiring it until just after releasing it (`held_ms`), each divided by 1,000,000 as a `Double`. After releasing, it dispatches `display-commit-lock` with `transition` (`start_file` or `end_file`), `wait_ms` and `held_ms` through ordered delivery, so the event precedes the `start-file` or `end-file` of the same mpv event.

### 8.4 Authoritative snapshot at playback restart

`MPV_EVENT_PLAYBACK_RESTART` arrives each time the first picture after a load or a seek is on screen. On the event queue, in this order:

1. Read synchronously, in any order and holding no bridge guard: `estimated-vf-fps` (number), `container-fps` (number), `deinterlace-active` (flag), `video-params` (map), `current-tracks/video` (map).
2. Take the exclusion, then the cache guard. Overwrite every cached input from the reads, writing the section 8.2 defaults for anything unavailable. Clear the hold and clear "early snapshot wanted", even when every read failed. Release both.
3. Schedule a cached apply (section 8.6).
4. Read `time-pos` and dispatch `playback-restart` (section 6.6 gives the reason for this order).

Reason for reading instead of using the caches: property changes for the new file can still be queued behind this event, so the caches may be stale. The snapshot does not apply EDR. It also overwrites the width and height caches.

### 8.5 Early snapshot at video reconfiguration *Vivid (`f347bb7`)*

Enabled only on tvOS and only when the core's `matchContentEnabled` is true; on iOS it never runs. Purpose: start the HDMI switch from the first complete picture-format snapshot, which can be available before audio is ready, without pausing either stream.

On each `MPV_EVENT_VIDEO_RECONFIG`, on the event queue:

1. Under the cache guard, note the epoch and whether "early snapshot wanted" and the hold are both set. If not both, stop.
2. Read synchronously, stopping silently at the first failure (leaving "early snapshot wanted" set, so a later reconfiguration can retry and the restart snapshot remains the fallback): `video-out-params` (map); `current-tracks/video` (map); `w` and `h` from the output parameters as `Int64`; those dimensions must pass the dimension check (section 6.16.3); `container-fps` present, finite and above 0; `estimated-vf-fps` present, finite and above 0; `deinterlace-active` present.
3. Derive, from these fresh values (not the caches): field output and the requested rate (section 8.7); profile and level from the track (`Int64`, default 0); signal peak from the output parameters' `sig-peak` (`Double`, default 0); transfer, primaries and matrix from the output parameters; then the profile 7 mapping (section 8.8).
4. Under the cache guard, clear "early snapshot wanted", so repeated reconfigurations within one file never dispatch a second early write.
5. Enqueue on main, holding the core weakly: stop if the core is gone or terminal; take the exclusion; under the cache guard confirm that the epoch is unchanged and the hold is still set (otherwise a source transition or the restart snapshot happened meanwhile: release and stop); release the cache guard and run the platform write (section 8.9) with the derived values (width and height as `Int32`). If it reports applied (which includes "already applied"), call the delegate's `onEvent` directly with the name `display-criteria-prepared` and nil data, still inside the exclusion, bypassing ordered delivery. Release the exclusion.

The early write does not touch the caches and does not release the hold, so partial observer updates cannot clear or change the mode before the restart snapshot reconciles the final cadence. The adapter uses the event only as a trace mark.

### 8.6 Cached apply (coalesced)

Scheduling: under the cache guard, if an apply is already scheduled do nothing; otherwise mark one scheduled and enqueue one main block that holds the core weakly. Merging is an optimisation only; correctness comes from sections 8.3 and 8.4.

Triggers: an available observer value for profile, level, container rate, deinterlace flag, transfer, primaries, matrix, signal peak, width or height (section 6.9); and the restart snapshot.

The main block:

1. Take the exclusion, then the cache guard. Clear the scheduled mark, so changes that arrive during the write schedule a fresh pass.
2. If held, release both and return without calling the platform write. There is no disposal check in this block; disposal sets the hold.
3. Derive from the caches: field output and the requested rate (section 8.7); width and height as `Int32`, truncated from the `Double` caches (an out-of-range value traps, as today; real values are always small); profile, level, signal peak, transfer, primaries and matrix, with the profile 7 mapping applied (section 8.8).
4. Release the cache guard and run the platform write with the exclusion held, ignoring its result. Release the exclusion.

### 8.7 Frame rate

1. **Field output**: true when the deinterlace flag is set, or when both the container rate and the measured cadence are above 0 and measured divided by container is strictly between 1.7 and 2.3. So ratios of 1.71 and 2.29 count, and 1.7, 2.3, 1.0 and 3.0 do not.
2. **Presented rate**: twice the container rate for field output, otherwise the container rate.
3. **Nominal snapping**: a rate that is not above 0 (including NaN) becomes 0. Otherwise find the nearest of 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88 and 120 Hz by absolute difference (on an exact tie the earlier entry in that list wins). If the absolute difference divided by that nominal rate is strictly below 0.01, use the nominal rate; otherwise use the presented rate unchanged. Reason: TVs offer modes only at nominal rates.

Examples: 23.9 gives 23.976; 59.9 gives 59.94; 47.9 gives 48; 23.5 stays 23.5 (about 2% from 23.976); 45 stays 45; 0 and NaN give 0; container 25 with the deinterlacer active gives 50; container 30 with a measured 60 gives 60.

The cadence is re-measured at every restart, including after seeks, so a seek can change field detection and request a new rate mid-stream.

### 8.8 Profile 7 mapping

In both the early snapshot and the cached apply: when the Dolby Vision profile is 7, pass profile 8 with compatibility id 1, keep the level, and fill any absent transfer, primaries and matrix with `smpte2084`, `bt2020` and `bt2020nc`. Otherwise pass the values unchanged with no compatibility id. Reason: the pinned decoder outputs profile 8.1 for these streams. *Vivid (`d5108a5`)* made this unconditional and removed every configurable conversion mode; the bridge never touches the process environment.

### 8.9 The platform write (tvOS)

Runs on main with the exclusion held and the cache guard released. Inputs: profile, level, compatibility id (optional), rate (already snapped), width and height (`Int32`), signal peak, transfer, primaries, matrix. It reports whether suitable criteria are in effect afterwards ("applied").

Definitions:

- **Window and manager**: the container's current window, else the remembered window; the manager is that window's `avDisplayManager`.
- **Request rate**: the input rate as a `Float` when it is above 0, otherwise 0.
- **No usable metadata**: the request rate, the profile and the signal peak are all not above 0, and transfer, primaries and matrix are all absent.
- **Requested range**: Dolby Vision when the profile is above 0, with no check of what the display supports; otherwise the base range (section 8.10) passed through the capability filter.
- **Hint**: the format description for the requested range (section 8.11). If it cannot be built and the profile is above 0, the requested range becomes the base range **without** the capability filter and the hint is built for that instead.
- **Identity**: section 8.12, built from the final requested range, the request rate, width, height, profile, level and compatibility id.

Outcomes:

| Outcome | When | Effect |
| --- | --- | --- |
| Nothing, not applied | `matchContentEnabled` is false, or there is no window. (On iOS the flag check comes first and the result is always not applied.) | No write and no clear. Takes precedence over every row below. |
| Clear, not applied | Any of: the dimensions fail the dimension check (section 6.16.3); no usable metadata; the manager's `isDisplayCriteriaMatchingEnabled` is false; no hint even after the Dolby Vision fallback | Clearing as in section 8.13. All four conditions behave identically, so their relative order does not matter. |
| Applied, no write | None of the above, and the identity equals the shared identity while the manager's `preferredDisplayCriteria` is currently not nil | Nothing written. |
| Write, applied | Everything else | Assign `AVDisplayCriteria(refreshRate: <request rate>, formatDescription: <hint>)` to `preferredDisplayCriteria` and record the identity in the shared slot. |

The identity is compared only once a hint exists, so a request that cannot be described always clears rather than matching an older identity.

### 8.10 Dynamic range

Normalise each colour tag by lowercasing it and keeping only characters that are letters or numbers (Swift's `Character.isLetter` or `isNumber`) (`bt.2020-ncl` becomes `bt2020ncl`, `arib-std-b67` becomes `aribstdb67`; an absent tag becomes the empty string).

Base range, first match wins:

1. HLG if the normalised transfer contains `hlg` or `arib`.
2. HDR10 if the normalised transfer contains `pq`, `smpte2084` or `st2084`; or the signal peak is above 1.0; or the normalised primaries contain `bt2020`; or the normalised matrix contains `bt2020`.
3. By compatibility id: 1 or 6 gives HDR10; 4 gives HLG; 2 gives SDR.
4. Otherwise SDR.

So SDR video tagged with BT.2020 primaries or matrix is requested as HDR10, and the compatibility id matters only when the tags say nothing (in practice only the profile 7 mapping supplies one, and it also fills the tags).

Capability filter, used only for non-Dolby-Vision ranges, from `AVPlayer.availableHDRModes`: HDR10 stays HDR10 if `.hdr10` is available, else SDR; HLG stays HLG if `.hlg` is available, else SDR; SDR stays SDR.

Range names (used in the identity and for diagnostics): `SDR`, `HDR10`, `HLG`, `Dolby Vision`.

### 8.11 Format hints

Each hint is built with `CMVideoFormatDescriptionCreate` (default allocator, the input width and height). A status other than `noErr` means no hint.

| Range | Codec type | Extensions |
| --- | --- | --- |
| HDR10 | `kCMVideoCodecType_HEVC` | `kCMFormatDescriptionExtension_ColorPrimaries` = `kCMFormatDescriptionColorPrimaries_ITU_R_2020`; `kCMFormatDescriptionExtension_TransferFunction` = `kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ`; `kCMFormatDescriptionExtension_YCbCrMatrix` = `kCMFormatDescriptionYCbCrMatrix_ITU_R_2020` |
| HLG | `kCMVideoCodecType_HEVC` | primaries `ITU_R_2020`; transfer `kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG`; matrix `ITU_R_2020` |
| SDR | `kCMVideoCodecType_HEVC` | primaries `kCMFormatDescriptionColorPrimaries_ITU_R_709_2`; transfer `kCMFormatDescriptionTransferFunction_ITU_R_709_2`; matrix `kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2` |
| Dolby Vision | `kCMVideoCodecType_DolbyVisionHEVC` (`dvh1`) | `kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms` = a dictionary with one entry: key `dvvC` when the profile is above 7, otherwise `dvcC`; value the 24-byte configuration record below as `CFData`. Plus primaries `ITU_R_2020`, transfer `SMPTE_ST_2084_PQ`, matrix `ITU_R_2020`. |

The codec type is HEVC for every non-Dolby-Vision request and `dvh1` for every Dolby Vision request, whatever the real codec.

Dolby Vision configuration record (`DOVIDecoderConfigurationRecord`, ETSI TS 103 572): 24 bytes, all zero except:

- byte 0: version major 1; byte 1: version minor 0;
- bytes 2 and 3: a big-endian 16-bit field holding, from the most significant bit down, the profile (7 bits), the level (6 bits), RPU present (1 bit, set), enhancement layer present (1 bit, clear) and base layer present (1 bit, set);
- byte 4: the compatibility id in the top 4 bits (the remaining bits zero).

Profile, level and compatibility id are first narrowed to 8 bits by truncation, then masked to 7, 6 and 4 bits; the `dvvC` or `dvcC` choice also uses the truncated profile. The compatibility id is the supplied one; when none is supplied it is 1 for profile 8 and 0 otherwise. So profile 5 is requested with id 0, and every profile 8 stream (including 8.4) with id 1.

### 8.12 Shared request identity

The identity is the tuple (final range, request rate as `Float`, width, height, profile, level, compatibility id or "none", where "none" differs from every real id). Any encoding that compares these seven fields exactly will do; compare the rate as the `Float` that is actually requested, after snapping. The signal peak and colour tags are not part of it beyond their effect on the range.

There is one identity slot for the whole process, shared by every core and touched only on main (section 5.6). It is recorded by every real write and forgotten by every real clear.

### 8.13 Clearing, replacement and final stop

**Clearing** (from the platform write's clearing outcomes and from `dispose`): act only if something is set, meaning the shared identity is recorded or the manager's `preferredDisplayCriteria` is currently not nil. Then assign nil to `preferredDisplayCriteria` and forget the identity. When nothing is set, do nothing, so repeated failures never cause spurious writes. Clearing removes criteria set by anyone, not only by the bridge.

**Replacement**: the adapter builds a new core for every load and, at the start of each load, disposes the previous core with `dispose(preserveDisplayCriteria: true, ...)`. The outgoing core then leaves the criteria and the shared identity alone, so when the incoming core asks for the same criteria the outcome is "applied, no write": episodes of one format play back to back with no HDMI renegotiation.

**Final stop**: the adapter's final teardown disposes with `preserveDisplayCriteria: false`. On tvOS `dispose` then clears synchronously on main, before mpv teardown is queued, while the container is still in its window (section 6.17.2). This clear is not gated by `matchContentEnabled` or the system matching setting.

**Audio-only loads** (`vid=no` from the start) reach a restart snapshot with no video parameters, so the size is 0 and the next apply clears any criteria preserved from the previous video. Backgrounding (`vid=no`, section 6.18) does not clear: the resulting unavailable observer values are ignored, and nothing is written until video returns.

### 8.14 Where the core's Match Content flag comes from (caller side, for context)

The adapter copies `LoadOptions.matchContentEnabled` into `matchContentEnabled` before `initialize`:

| Load path | Value given to the core |
| --- | --- |
| Server playback plan | On tvOS, the key window's `avDisplayManager.isDisplayCriteriaMatchingEnabled`, sampled when the load is built; on iOS always true |
| Direct URL with server quality options | The same sampled tvOS setting |
| Direct URL without server quality options | Always true |
| Offline file | Always true |

Consequences: on the last two paths the flag is true even when the system setting is off, so the early snapshot still runs and every write lands on the "system matching disabled" clear; if the viewer turns the setting on mid-play, the next re-evaluation performs a real write. On the first two paths, a load started with the setting off never writes or clears for its whole life. On any path, a load started with the setting on clears at its next re-evaluation if the setting is turned off.

### 8.15 iPhone and iPad: no display criteria, EDR on the layer

- There is no `AVDisplayManager` path: the platform write returns not applied without doing anything, the early snapshot never runs, and `dispose` has nothing to clear. External screens get no display criteria.
- EDR decision: wanted when the signal peak is strictly above 1.0 (mpv reports the peak relative to SDR reference white, so SDR is 1.0 and PQ, HLG and Dolby Vision content is normally above it).
- Applying it, with implicit animations disabled: on iOS 26 and later set the layer's `preferredDynamicRange` to `.high` when wanted, else `.standard`; on iOS 18 to 25 set `wantsExtendedDynamicRangeContent` to the decision. Nothing happens if the layer has gone, and nothing at all on tvOS.
- Applied: on every available signal-peak observer value (with that value, enqueued on main; the hop keeps the core alive until it runs and does not check the terminal state); on every geometry update with the cached peak (section 7.5); and on scene activation with the cached peak. The restart snapshot updates the cached peak but does not apply EDR itself.
- External screen and Picture in Picture use the same layer, so the EDR state follows it.

### 8.16 HDR by source on Apple TV, and debug-only switch events

| Source (as mpv reports it) | Requested range and hint | When the TV lacks that mode |
| --- | --- | --- |
| SDR (BT.709 tags, peak 1.0 or absent) | SDR, HEVC hint with 709 tags | SDR |
| SDR tagged BT.2020 primaries or matrix | HDR10 | SDR |
| HDR10 or HDR10+ (PQ transfer or peak above 1.0) | HDR10 | SDR |
| HLG (`hlg` or `arib-std-b67` transfer) | HLG | SDR |
| Dolby Vision profile 5 | Dolby Vision, `dvcC` record, compatibility 0 | Still requested as Dolby Vision (no capability check) |
| Dolby Vision profile 8 (8.1, 8.2, 8.4) | Dolby Vision, `dvvC` record, compatibility 1 | As above |
| Dolby Vision profile 7 | Dolby Vision profile 8, compatibility 1, absent tags filled as PQ, BT.2020 and BT.2020 non-constant | As above |
| Dolby Vision whose hint cannot be built | The base range from the tags, without the capability filter | |

The rate is always part of the same request. Which parts tvOS honours (rate, range or both) is decided by the viewer's Match Content settings.

**[debug-only]**, tvOS: the core observes `AVDisplayManagerModeSwitchStart` and `AVDisplayManagerModeSwitchEnd` (any object) and, synchronously in the handler, calls the delegate's `onEvent` with the name `display-switch-started` or `display-switch-ended` and nil data, with no hop and no disposal check. The observers are removed at `dispose`. The adapter records the events in its trial trace and latest-playback report; Release builds never receive them.

## 9. External displays, Picture in Picture, background and AirPlay

### 9.1 Role test

`VividExternalDisplay.isExternalDisplayRole(_:)` returns true exactly when the role's raw string value is `UIWindowSceneSessionRoleExternalDisplay` or `UIWindowSceneSessionRoleExternalDisplayNonInteractive` (exact, case-sensitive, whole-string comparison). Every other role returns false, including the application role, CarPlay roles and any role added in a future SDK. Compare raw strings; do not reference the deprecated `windowExternalDisplay` constant. The test is pure and stateless and callable from any isolation. `PlaybackSessionRecorder` relies on it classifying exactly the roles the coordinator adopts.

With Stage Manager on iPad, an app window dragged to an extended display is an application-role scene, so it is never treated as external. Only the role decides, never which screen a scene is on.

### 9.2 The external-display coordinator (iOS only)

A final class with a single process-wide instance (private initialiser), used only on main, with no locks, no actor annotation, no notifications observed or posted, and no timers.

State: a weak reference to the active core (one at a time), and strong references to the adopted external window scene, the window created on it and that window's root view controller.

| Operation | Behaviour |
| --- | --- |
| Attach a core (from `initialize`, after the context succeeds) | Make it the active core, replacing any previous one without telling it. If no scene is adopted yet, look through `UIApplication.shared.connectedScenes` for the first `UIWindowScene` whose session role passes the role test and adopt it (the set is unordered; at most one scene is adopted). If a scene is already adopted, do not search. Then run the active core's placement refresh, at least once after the core is recorded and after any adoption (running it more than once is harmless because the refresh is idempotent). |
| Detach a core (from `dispose`) | Forget it only if it is the same object as the active core. Never touches the adopted scene, window or root view controller. |
| Adopt a scene | Record it as the adopted scene (a previously adopted scene is simply forgotten). End state: the adopted scene has exactly one external window, created with `UIWindow(windowScene:)`, shown (`isHidden` false), never made key, at the default window level and black, whose root view controller is a plain `UIViewController` with a black view sized to the scene's `coordinateSpace.bounds` at adoption. A window the coordinator already had for this same scene is reused unchanged; a window it had for another scene is hidden and released. Then run the active core's placement refresh. |
| External root view | The root view controller's view while a scene is adopted, otherwise nil. Only the core reads it. |

Nothing ever releases an adopted scene (section 14.2).

Wiring status in Vivid today: `iosApp/iosApp/Info.plist` has no `UIApplicationSceneManifest`, the XcodeGen specs add no scene keys, the app uses the SwiftUI `App` life cycle with a single `WindowGroup`, and the only app delegate (`VividAppDelegate`) does not implement `application(_:configurationForConnecting:options:)`. So adoption can happen only through the search at attach time, once per load. A display connected in the middle of playback is not picked up until the next load. Whether iOS ever hands this app an external-display-role scene at all is unverified (section 16.3 records how to check). If it never does, external screens simply mirror the device and the only live part of this section is the role test.

### 9.3 Placement refresh

Runs on main from `externalDisplayDidChange()`, `setVisible(true)`, the coordinator and iOS scene activation. It does nothing if there is no container (never initialised, or disposed). Otherwise, the external target is the coordinator's external root view, but only on iOS, only while the core is visible and only while `isPipActive` is false; in every other case there is no target.

| Situation | Container's parent afterwards | Cover view (iOS) afterwards |
| --- | --- | --- |
| An external target exists | The external root view (section 9.4) | Shown in the remembered window (section 9.4); removed instead if that window has gone |
| No target, the core is visible and the remembered window exists | The host view, or the remembered window itself if the host view has gone | Removed |
| Otherwise | Unchanged (a hidden container can stay parked in the external root view) | Removed |

In every case the container's `isHidden` then equals "not visible" (implicit animations disabled), and the geometry update (section 7.5) runs last, so sizes and scale reflect the new parent and screen.

`setVisible(true)`: does nothing without a container; otherwise records the core as visible, runs the placement refresh, and unhides the container with implicit animations disabled. Vivid calls it once per load, straight after `initialize`; on iOS it reveals the container that `initialize` left hidden (section 6.2), and on both platforms it gives the container its flexible autoresizing mask through the move.

On tvOS there is never an external target, so the refresh always keeps or returns the container to the host view.

### 9.4 Container placement and the cover view

End states:

- After the container is placed in a target view, it is the target's first (bottom-most) subview, its frame equals the target's bounds, and it resizes with the target (flexible width and height). It is moved to index 0 even when it was already in the target but not first. This is done with implicit animations disabled. The same layer moves with the container; nothing is recreated, and mpv is not told.
- While shown, the cover view (iOS) is the remembered window's first subview: black, not interactive, resizing with the window, filling its bounds and not hidden. It is created on first need and reused, with implicit animations disabled. Removing it takes it out of the window and forgets it. Each geometry update re-sizes it to the window's bounds.

When video moves to an external screen: the container (with the video layer and the engine's subtitle layer) shows full-screen on the external screen at that screen's scale, and the device shows the player controls over the black cover view. The container returns to the host view when Picture in Picture starts.

If two cores were alive and visible at once, each could move its own container into the shared external root view when its refresh runs (each at index 0, so the most recently refreshed is bottom-most). Reproduce this as is; add no arbitration.

### 9.5 Picture in Picture (iOS)

- Source: after each successful `initialize` the adapter wraps `sampleBufferDisplayLayer` in `SampleBufferPiPSource` (not for audio-only loads), and `PictureInPictureCoordinator` builds an `AVPictureInPictureController` from `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)` with `canStartPictureInPictureAutomaticallyFromInline = true`. A new load produces a new layer; while Picture in Picture is up, the coordinator swaps the content source on the same controller. The bridge only has to keep exposing the current layer.
- Flag flow: the coordinator sets the adapter's `pictureInPictureActive` synchronously in will-start (so it is already true when the scene's did-enter-background arrives during an automatic start), again in did-start, and to false in did-stop, failed-to-start and session teardown. Every assignment, changed or not, makes the adapter, in order: set the core's `isPipActive`; record it in the session recorder; call `setPipSubtitleCompositing(_:)` with the same value; call `externalDisplayDidChange()`; call `updateFrame()`. The bridge must read `isPipActive` at the moment each notification or refresh runs.
- `setPipSubtitleCompositing(_:)`: on iOS, send `avfoundation-pip-composite-osd` = `yes` or `no` as an asynchronous string property set, on every call (not only on changes), ignoring the result; failures are silent. On tvOS, do nothing.
- Effects while active: subtitles are composited into the samples in frame space so the Picture in Picture window shows them; the container is never placed on an external screen (it returns to the host view and the cover view is removed); entering the background keeps video running; foreground and activation skip the `vid` restore and the presentation restore. On stop, compositing is switched off, placement is re-evaluated (video may move back to an external screen) and geometry is refreshed. No paused redraw is issued on stop itself.
- iOS stays on the video output's media-time presentation so Picture in Picture's timeline and play or pause follow media time. Play, pause, skip and the time range in the Picture in Picture window go through the adapter, not the bridge.

### 9.6 Background, screen lock and return

Section 6.18 gives the full behaviour. Display-relevant points:

- On iOS the core observes only the main window's scene (captured at `initialize`), so activity on an external scene is ignored. When the main scene enters the background, video output is switched off (`vid=no`) unless Picture in Picture is active, even if the video is currently on the external screen.
- Only scene activation runs the placement refresh, the layer recovery, EDR and the paused redraw. Will-enter-foreground only restores `vid`.
- On tvOS there is no activation handler and no placement refresh; Home and return only toggle `vid`, leaving the HDMI mode untouched.
- With Picture in Picture off, every background and return destroys and rebuilds the engine's video output (section 6.18).

### 9.7 AirPlay and screen mirroring

- The bridge has no AirPlay-specific logic. This pipeline has no `AVPlayer` for video, so there is no AirPlay video hand-off.
- When no external-role scene is adopted (the expected case today, section 9.2), iOS mirrors the device screen to a cable display or to AirPlay Screen Mirroring, so the video is mirrored as part of the host view, and the recorder's `externalScreen` field reads false.
- If an external-role scene exists at load time and is adopted, video moves as described in section 9.4, and Picture in Picture pulls it back to the device.
- AirPlay audio (for example to HomePod) is handled by the engine's audio output and the adapter's AirPlay options. The bridge's only part is that video presentation follows mpv's audio-driven clock through the video output.

## 10. Errors, logs and strings other code depends on

### 10.1 Errors that reach callers

| Error | Meaning | When | Delivered |
| --- | --- | --- | --- |
| Not-available error | The player cannot take the request: it was never set up, or it has been disposed. | `setPropertyAsync` or `getPropertyAsync` on a disposed core; any submission without a live handle (disposed or never created), including `commandAsync` and the bridge's own string sets | Inline when called on main, otherwise asynchronously on main |
| Disposed error | The request was still pending when the player was disposed. | Every request pending when disposal starts | Asynchronously on main |
| mpv error | An mpv call failed. Its code is the mpv status and its localised description is that status's `mpv_error_string` (section 6.16.1). | An mpv `*_async` call returned a negative status at submission, or a reply carried a negative `error` | Asynchronously on main |

Nothing in Vivid tests these errors' types, domains or texts. They reach the adapter's callers untyped (for example through `VividPlaybackController.finishLoad`), where only diagnostics record the bridged `NSError` domain and code. The new code therefore chooses its own wording for the two bridge errors and its own domain for mpv errors. Recommended: make `VividPlayerCoreError` a plain struct conforming to `LocalizedError` whose `errorDescription` is the wording, with no `CustomNSError` conformance (its bridged domain is then its module-qualified type name, which necessarily differs from today's, and its code 1); and keep mpv errors as `NSError` with the mpv status as the code. The bridge special-cases no mpv error code. Those seen in practice include `MPV_ERROR_PROPERTY_UNAVAILABLE` (-10) from gets, `MPV_ERROR_OPTION_NOT_FOUND` (-5) for unknown options and `MPV_ERROR_LOADING_FAILED` (-13) in `end-file`. `mpv_create` and `mpv_initialize` failures are reported only as `initialize` returning false.

### 10.2 Console output

The bridge prints only these lines, with Swift `print` to standard output (tvOS captures main-app standard output), in Debug and Release alike. It emits no debug traces and builds no trace strings anywhere.

| When | Text |
| --- | --- |
| `mpv_create` returned null | One line, starting with the tag `[VividPlayerCore]`, saying the context could not be created. Wording free. |
| `mpv_initialize` failed | One line, starting with the tag, giving the `mpv_error_string` of the status. Wording free. |
| `checkError` sees a negative status | Exactly `[VividPlayerCore] MPV error: <mpv_error_string>`, then ` option=<name>` when an option name was passed, then ` at <file>:<line>` from the `file` and `line` parameters. |

`checkError` does nothing for a status of 0 or above. Its `file` and `line` defaults (`#fileID`, `#line`) capture the caller's location, so the adapter's option errors report `<module>/VividMPVPlayer.swift` (`Vivid` on iOS, `VividTV` on tvOS). The bridge's own checks (the initial log level request, `wid`, every bridge option and `mpv_hook_add`) pass no option name; only the preload `aid` write passes `aid`. The adapter passes the name for the options in its dictionary group and not for the others (section 6.19). `docs/cores/player-engine.md` quotes the `MPV error: option not found` form, which is what an unpatched engine prints for Vivid's driver options; keep that text and the `option=` detail. The tag changes from the current `[MpvPlayerCore]` to `[VividPlayerCore]`; nothing in the repository depends on the tag.

### 10.3 Strings other code reads

| Dependent | What it needs |
| --- | --- |
| `VividMPVPlayer` | The event names and payload keys in section 4.6 and property names exactly as mpv delivers them. |
| `PlaybackSessionRecorder` | The two role strings in section 9.1. |
| `docs/cores/player-engine.md` | The `MPV error: option not found` console form. |
| Debuggers and crash logs | The event queue label `mpv`. |

### 10.4 Forbidden strings

`scripts/release/use-patched-libmpv.sh verify` proves that the patched audio driver is linked by finding the literal strings `first start recovery after` and `trace edge %s` in the app binary. They must therefore never appear in any Swift source, including the new bridge (which ships in every binary, section 3) and its tests.

### 10.5 Documents to update later

`THIRD_PARTY_NOTICES.md` and `iosApp/Resources/OpenSourceLicenses/README.txt` describe the current files as adapted from a third-party project. Update them when the current files are retired, not before.

## 11. Constants and timing values

| Value | Meaning | Section |
| --- | --- | --- |
| `mpv`, `.userInitiated` | Event queue label and quality of service, one serial queue per core | 5.1 |
| `warn` | mpv log level requested at creation (Debug and Release) | 6.2 |
| `v` (`VIVID_P8_TRIAL`), `warn` (otherwise) | Level the adapter sets after `initialize` | 6.4 |
| 0 | `mpv_wait_event` timeout | 6.5 |
| 0 | Reply userdata for caller observations and for the `on_preloaded` hook | 6.7, 6.2 |
| 10 distinct non-zero values | Reply userdata of the internal observers | 6.7 |
| 1, step 1 | First request number and increment, per core | 6.13.1 |
| `on_preloaded`, priority 0 | Preload hook name and priority | 6.2, 6.15 |
| `duration`, `eof-reached`, `pause`, `paused-for-cache`, `seekable`, `time-pos` | Properties delivered while backgrounded | 6.11 |
| `time-pos`, `avsync`, `demuxer-cache-state`, `demuxer-cache-duration` | Coalesced properties | 6.10 |
| `1`, `true`, `yes`, `on` (case-insensitive) | `pause` values meaning paused | 6.12 |
| 32 | Maximum node depth (root is depth 0; depth 33 converts to nil) | 6.16.2 |
| 4,096 | Node entry budget per top-level conversion | 6.16.2 |
| 16,777,216 bytes (16 MiB) | Node string and byte budget per top-level conversion | 6.16.2 |
| 16,384 | Maximum width or height (side data and display criteria) | 6.16.3 |
| 67,108,864 (64 x 1,024 x 1,024) | Maximum pixel count | 6.16.3 |
| 1.7 to 2.3, both exclusive | Measured-to-container cadence ratio meaning field output | 8.7 |
| x 2 | Presented rate for field output | 8.7 |
| 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60, 100, 119.88, 120 Hz | Nominal refresh rates, in this order (earlier wins a tie) | 8.7 |
| below 0.01 (strict) | Relative distance for snapping to a nominal rate | 8.7 |
| profile 8, compatibility 1, `smpte2084`, `bt2020`, `bt2020nc` | Profile 7 mapping and default tags | 8.8 |
| 1.0 (strict "above") | Signal peak above which EDR is wanted (iOS) and above which the base range is HDR10 (tvOS) | 8.10, 8.15 |
| 24 bytes, version 1.0, RPU and base-layer flags set | Dolby Vision configuration record | 8.11 |
| above 7 | Profile that selects `dvvC` rather than `dvcC` | 8.11 |
| 1 for profile 8, else 0 | Compatibility id when none is supplied | 8.11 |
| `seek`, `0`, `relative+exact` | Paused redraw command | 6.18 |
| `vid` = `no` / `auto` | Background and foreground video toggles | 6.18 |
| `[VividPlayerCore]` | Console tag | 10.2 |

The bridge has no timers, retry counts, polling intervals, timeouts or animation durations. The 50 ms polling, 60 second open budget, 15 second seek budget, 250 ms end confirmation, 0.25 second `avsync` publishing and 1 and 10 second diagnostic sampling all belong to the adapter.

## 12. Vivid-authored behaviour by commit

The current files arrived in the import commits `1598f91` (base and core, 15 September 2026) and `04a349d` (external display file, 16 September 2026). Everything below was written by blurbery for Vivid, either while importing or in later commits. Code blocks quote only whole lines that later Vivid commits added and that are Vivid's own expression. Lines that existed before, or that closely copy earlier lines, are replaced by `// [not quoted: ...]` placeholders and their behaviour is described in the section the text points to. Neutral structural lines (braces, conditional-compilation lines, bare returns) and generic idioms inside Vivid blocks are quoted as they are; lines that name an identifier introduced by the original import, including its lock, are placeholders. Identifiers inside the quotes are illustrative: the implementer may reuse Vivid's own code or choose different names.

### 12.1 Import-time adaptations (`1598f91`, `04a349d`)

Not quotable; behaviour only.

- The video container is mounted in the adapter's persistent host view (inserted at subview index 0) instead of the window; `initialize` takes the host view as its second argument and remembers it before anything else. When video returns from an external screen it goes back to the host view, or to the window if the host view has gone (sections 6.2 and 9.3).
- The core gained the settable `matchContentEnabled` flag (default true). When it is false the platform display write returns at once without writing or clearing (section 8.9). `749b657` corrected that early return to report "not applied".
- The initial mpv log level is `warn` in Debug and Release alike.
- Debug traces are switched off in every build.
- File headers and whole-file platform guards. `04a349d` widened the base and core guards to iOS, and `aef1726` removed the experiment flag from all three guards, giving iOS-or-tvOS for the base and core and iOS-only for the external display file (section 3).

### 12.2 `bca4095`: background hook

The core gained `onEnterBackground`, called as the very first step of the background handler, before the core marks itself backgrounded and before the Picture in Picture check (section 6.18). The adapter sets it on iOS only.

Vivid-authored (`bca4095`), the stored property:

```swift
  var onEnterBackground: (() -> Void)?
```

Vivid-authored (`bca4095`), the first statement of the background handler:

```swift
    onEnterBackground?()
```

### 12.3 `d5108a5`: debug gate and Dolby Vision conversion

- The debug trace gate became a single constant that is off in every build, so no trace string is ever built.
- Every configurable Dolby Vision conversion mode was removed, including the two process environment variables that used to be exported before the context was created. The bridge sets no environment variables (section 6.3).
- Profile 7 is now always requested as profile 8 with compatibility id 1, keeping the cached level (section 8.8).

Vivid-authored (`d5108a5`), the gate's explanation:

```swift
/// VividMPVPlayer requests verbose native events only for its diagnostic build.
/// Swift bridge traces stay disabled; native events pass through Vivid's
/// restricted diagnostic formatter rather than enabling raw logging.
```

Vivid-authored (`d5108a5`), inside the profile 7 mapping of the cached apply:

```swift
      // Vivid uses the pinned decoder's default automatic conversion.
      // Do not mutate the process environment while native decoders run.
```

### 12.4 `932e46a`: comments only

Comment rewording that removed references to the previous host app. No behaviour change. One reworded comment recorded that a caller using the (now omitted) zoom feature must restore its transform after presentation changes.

### 12.5 `f347bb7`: early display criteria and the source-transition exclusion

Behaviour (sections 8.3 to 8.6 and 8.16): the separate source-transition exclusion, the epoch and the "early snapshot wanted" flag; the start-of-file and end-of-file holds; the early snapshot at `MPV_EVENT_VIDEO_RECONFIG` with its `display-criteria-prepared` event; the switch that enables it only on tvOS with Match Content; the exclusion around the cached apply and the restart snapshot; and the debug-only `display-commit-lock`, `display-switch-started` and `display-switch-ended` events. Release note: "Started Apple TV content matching earlier while playback continues, and protected display updates when changing sources."

Vivid-authored (`f347bb7`), state:

```swift
  // Serialises source transitions with the main-thread display write.
  // [not quoted: comment line restating section 5.3 rule 2]
  private let displayCriteriaCommitLock = NSLock()
  private var displayCriteriaEpoch: UInt64 = 0
  private var initialDisplayCriteriaPending = false
```

Vivid-authored (`f347bb7`), the overridable switch on the base:

```swift
  var preparesDisplayCriteriaEarly: Bool { false }
```

Vivid-authored (`f347bb7`), the tvOS core's override of that switch:

```swift
  override var preparesDisplayCriteriaEarly: Bool {
    #if os(tvOS)
      return matchContentEnabled
    #else
      return false
    #endif
  }
```

Vivid-authored (`f347bb7`), the first statements of the cached apply:

```swift
    displayCriteriaCommitLock.lock()
    defer { displayCriteriaCommitLock.unlock() }
```

Vivid-authored (`f347bb7`), event handling:

```swift
      // [not quoted: pre-existing lines]
      holdDisplayCriteriaForSource(starting: true)
      // [not quoted: pre-existing lines]
      holdDisplayCriteriaForSource(starting: false)
    // [not quoted: pre-existing lines]
    case MPV_EVENT_VIDEO_RECONFIG:
      prepareInitialDisplayCriteria()
```

Vivid-authored (`f347bb7`), inside the restart snapshot:

```swift
      // [not quoted: pre-existing statements; see section 8.4]
      displayCriteriaCommitLock.lock()
      // [not quoted: pre-existing statements; see section 8.4]
      initialDisplayCriteriaPending = false
      // [not quoted: pre-existing statements; see section 8.4]
      displayCriteriaCommitLock.unlock()
```

Vivid-authored (`f347bb7`), the source hold:

```swift
  private func holdDisplayCriteriaForSource(starting: Bool) {
    #if VIVID_P8_TRIAL
      let requestedAt = DispatchTime.now().uptimeNanoseconds
    #endif
    displayCriteriaCommitLock.lock()
    #if VIVID_P8_TRIAL
      let acquiredAt = DispatchTime.now().uptimeNanoseconds
    #endif
    defer {
      displayCriteriaCommitLock.unlock()
      #if VIVID_P8_TRIAL
        // Capture on the event thread; main-queue delivery time is not lock wait.
        dispatchDelegateEvent(name: "display-commit-lock", data: [
          "transition": starting ? "start_file" : "end_file",
          "wait_ms": Double(acquiredAt - requestedAt) / 1_000_000,
          "held_ms": Double(DispatchTime.now().uptimeNanoseconds - acquiredAt) / 1_000_000
        ])
      #endif
    }
    // [not quoted: lines naming pre-existing internals; see section 8.3]
    displayCriteriaEpoch &+= 1
    initialDisplayCriteriaPending = starting
    // [not quoted: set the hold]
  }
```

Vivid-authored (`f347bb7`), the early snapshot:

```swift
  /// A configured decoded video output can precede audio readiness. Start
  /// matching from a complete snapshot then, without pausing either stream.
  /// Keep observer-driven updates held until PLAYBACK_RESTART reconciles the
  /// final cadence, so partial property notifications cannot clear the mode.
  private func prepareInitialDisplayCriteria() {
    guard preparesDisplayCriteriaEarly else { return }
    // [not quoted: lines naming pre-existing internals; see section 8.5]
    let epoch = displayCriteriaEpoch
    // [not quoted: lines naming pre-existing internals; see section 8.5]
    guard pending,
      // [not quoted: read the video-out-params map and the current-tracks/video map]
      let width = params["w"] as? Int64,
      let height = params["h"] as? Int64,
      // [not quoted: require the dimensions to pass the dimension check]
      // [not quoted: read container-fps, estimated-vf-fps (each finite and above 0) and deinterlace-active]
    else { return }

    // [not quoted: derive field output, the snapped rate, profile, level, peak and colour tags, and apply the profile 7 mapping (sections 8.7 and 8.8)]
    // [not quoted: lines naming pre-existing internals; see section 8.5]
    initialDisplayCriteriaPending = false
    // [not quoted: lines naming pre-existing internals; see section 8.5]
    DispatchQueue.main.async { [weak self, profile, gamma, primaries, matrix, compatibility] in
      // [not quoted: stop if the core is gone or terminal]
      self.displayCriteriaCommitLock.lock()
      defer { self.displayCriteriaCommitLock.unlock() }
      // [not quoted: lines naming pre-existing internals; see section 8.5]
      guard current else { return }
      // [not quoted: if the platform write with the derived values reports applied:]
        self.delegate?.onEvent(name: "display-criteria-prepared", data: nil)
      }
    }
  }
```

Vivid-authored (`f347bb7`), debug-only switch events in the core:

```swift
  #if os(tvOS) && VIVID_P8_TRIAL
    @objc private func traceDisplaySwitchStarted() {
      delegate?.onEvent(name: "display-switch-started", data: nil)
    }

    @objc private func traceDisplaySwitchEnded() {
      delegate?.onEvent(name: "display-switch-ended", data: nil)
    }
  #endif
```

Vivid-authored (`f347bb7`), their registration, at the start of the core's notification set-up:

```swift
    #if os(tvOS) && VIVID_P8_TRIAL
      NotificationCenter.default.addObserver(
        self, selector: #selector(traceDisplaySwitchStarted),
        name: .AVDisplayManagerModeSwitchStart, object: nil
      )
      NotificationCenter.default.addObserver(
        self, selector: #selector(traceDisplaySwitchEnded),
        name: .AVDisplayManagerModeSwitchEnd, object: nil
      )
    #endif
```

### 12.6 `a0e0e9b`: dispose completion

`dispose` and the shared teardown gained an optional `@Sendable` completion, called as the last step of the destroy step on the event queue, after the wakeup callback is cleared, mpv is destroyed and the relay is released. A second `dispose` never calls its completion (section 6.17). Release note: "Cleanup now waits for retiring players and preserves the new episode's audio session."

Vivid-authored (`a0e0e9b`), the last statement of the destroy step:

```swift
      completion?()
```

### 12.7 `128014c`: coalesced delivery

Coalescing of `time-pos`, `avsync`, `demuxer-cache-state` and `demuxer-cache-duration`, with ordered items carrying pending values ahead of themselves (section 6.10).

Vivid-authored (`128014c`), state and helpers:

```swift
  /// Properties that can change on every presented frame. While one main
  /// delivery is queued, newer values replace the pending ones instead of
  /// queuing another block, so a busy main thread receives the latest value
  /// once rather than replaying a backlog of stale ones.
  private static let coalescedProperties: Set<String> = [
    "time-pos", "avsync", "demuxer-cache-state", "demuxer-cache-duration",
  ]

  private struct PendingProperty {
    let name: String
    let value: Any?
    let sourceId: Int64?
  }

  private struct PropertyCoalescing {
    var pending: [PendingProperty] = []
    /// Identifies the one queued flush allowed to deliver `pending`.
    var scheduledFlush: UInt64?
    var nextFlush: UInt64 = 0
  }

  private let coalescingLock = NSLock()
  private var coalescing = PropertyCoalescing()

  /// Hands any pending coalesced values to the caller's delivery block and
  /// retires the queued flush. Every other delivery calls this first, so the
  /// main thread still observes properties and events in mpv's order.
  private func takePendingCoalescedProperties() -> [PendingProperty] {
    coalescingLock.lock()
    defer { coalescingLock.unlock() }
    let pending = coalescing.pending
    coalescing.pending = []
    coalescing.scheduledFlush = nil
    return pending
  }

  private func deliverPendingProperties(_ pending: [PendingProperty]) {
    for property in pending {
      // [not quoted: deliver one pending property to the delegate]
    }
  }
```

Vivid-authored (`128014c`), inside the ordered event dispatch:

```swift
    // [not quoted: pre-existing statements; see section 6.10]
    let pending = takePendingCoalescedProperties()
      // [not quoted: pre-existing statements; see section 6.10]
      self.deliverPendingProperties(pending)
      // [not quoted: pre-existing statements; see section 6.10]
```

Vivid-authored (`128014c`), the property dispatch:

```swift
    let property = PendingProperty(name: name, value: value, sourceId: sourceId)
    guard Self.coalescedProperties.contains(name) else {
      let pending = takePendingCoalescedProperties()
        // [not quoted: pre-existing statements; see section 6.10]
        self.deliverPendingProperties(pending)
        // [not quoted: pre-existing statements; see section 6.10]
      return
    }

    coalescingLock.lock()
    if let index = coalescing.pending.firstIndex(where: { $0.name == name }) {
      coalescing.pending[index] = property
    } else {
      coalescing.pending.append(property)
    }
    var flush: UInt64?
    if coalescing.scheduledFlush == nil {
      coalescing.nextFlush &+= 1
      coalescing.scheduledFlush = coalescing.nextFlush
      flush = coalescing.nextFlush
    }
    coalescingLock.unlock()

    guard let flush else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.coalescingLock.lock()
      guard self.coalescing.scheduledFlush == flush else {
        // A later delivery already carried these values in order.
        self.coalescingLock.unlock()
        return
      }
      let pending = self.coalescing.pending
      self.coalescing.pending = []
      self.coalescing.scheduledFlush = nil
      self.coalescingLock.unlock()
      // [not quoted: stop if the core is terminal]
      self.deliverPendingProperties(pending)
    }
```

### 12.8 `51630a4`: option name and call site in mpv errors

The error check gained the optional option name and the caller's file and line, so a rejected option can be identified from the log (section 10.2).

Vivid-authored (`51630a4`), the error check:

```swift
  /// Logs a failed mpv call with where it came from, and the option name
  /// when one is given, so a rejected option can be identified from the log.
  // [not quoted: the signature, as in section 4.3, and the negative-status test]
      let detail = option.map { " option=\($0)" } ?? ""
      // [not quoted: print the line described in section 10.2]
```

### 12.9 `8268108`: audio choice while preloading

The overridable preload switch and choice, registration of `on_preloaded`, handling of `MPV_EVENT_HOOK` with an unconditional continue, the list read of `track-list` and the synchronous `aid` write (sections 6.6 and 6.15). Release note: "Vivid picks the audio track your setup can play before the player jumps to your position, so it no longer seeks twice." Measured for this change alone (`docs/cores/player-engine.md`): on Apple TV 4K (3rd generation) with tvOS 27, resuming a 4K Dolby Vision MKV, file loaded to playback start fell from 5.3 to 5.8 s to 2.0 to 3.6 s.

Vivid-authored (`8268108`), the overridable hooks:

```swift
  /// Whether to choose the audio track in mpv's `on_preloaded` hook. There
  /// the file's tracks are known, but mpv has not yet made its own default
  /// pick or run the initial seek, so a resume seeks once on the chosen
  /// track. Switching after `file-loaded` makes mpv seek a second time.
  var selectsAudioWhilePreloading: Bool { false }

  /// The mpv `aid` to select while preloading, from the file's `track-list`.
  // [not quoted: doc comment line: nil keeps mpv's own pick, and the call runs on the event queue while mpv waits]
  func preloadedAudioTrackID(tracks: [[String: Any]]) -> Int64? { nil }
```

Vivid-authored (`8268108`), during context set-up, after the internal observers:

```swift
      if selectsAudioWhilePreloading {
        checkError(mpv_hook_add(mpv, 0, "on_preloaded", 0))
      }
```

Vivid-authored (`8268108`), hook events:

```swift
    case MPV_EVENT_HOOK:
      guard let hook = event.data?.assumingMemoryBound(to: mpv_event_hook.self).pointee else { break }
      // [not quoted: when the hook's decoded name is on_preloaded:]
        selectAudioWhilePreloading()
      // [not quoted: end of that test]
      // mpv waits for every hook to be continued, so always continue.
      // [not quoted: continue the hook by its id on the live handle]
```

Vivid-authored (`8268108`), the audio choice:

```swift
  /// Before mpv's default track pick, an `aid` set here is the selection mpv
  /// starts with, rather than a switch that needs another seek.
  private func selectAudioWhilePreloading() {
    guard let tracks = readListProperty("track-list"),
          let id = preloadedAudioTrackID(tracks: tracks),
          // [not quoted: copy the live handle, or return]
    checkError(mpv_set_property_string(mpv, "aid", String(id)), option: "aid")
  }
```

### 12.10 Caller-side Vivid changes that touch the bridge contract

- `1fa2081`: `PlaybackSessionRecorder` uses the role test to record whether an external screen is connected.
- `bca4095`: the adapter's Picture in Picture handler calls `externalDisplayDidChange()` and `updateFrame()`.
- `51630a4`: the adapter stopped setting an option the engine does not have.

## 13. Deliberately omitted members and paths

The current bridge contains code that nothing in Vivid reaches. The replacement omits it. Each row gives the evidence, from a repository-wide search, that it is unreached today.

Evidence used by several rows: the complete set of property names the adapter passes to `setProperty` and `setPropertyAsync` is `volume`, `pause`, `hr-seek`, `speed`, `audio-spdif`, `aid`, `sid`, `secondary-sid`, `sub-delay`, `secondary-sub-delay` and the subtitle style keys `sub-ass-override`, `secondary-sub-ass-override`, `sub-font`, `sub-font-size`, `sub-color`, `sub-border-style`, `sub-back-color`, `sub-outline-color`, `sub-outline-size`, `sub-shadow-offset`, `sub-align-y`, `sub-pos`, `sub-scale-with-window` and `sub-use-margins`. Nothing else calls the setters.

| Omitted from the current bridge **[unreached]** | Evidence | What the replacement does instead |
| --- | --- | --- |
| An unused API for waiting until an HDMI mode switch has finished, with its supporting state and its cancellation inside `dispose` | No caller. The adapter passes autoplay straight through, and `docs/cores/player-engine.md` states that playback continues through the switch with no startup pause. | Nothing. Real writes and clears only update the shared identity. |
| An unused viewer zoom (a scale transform on the video layer, with clipping on the container) | No caller. | Nothing. Never set a layer transform or container clipping. |
| The `hdr-enabled` pseudo-property and the HDR toggle behind it (which wrote `target-colorspace-hint`, re-applied EDR and re-evaluated display criteria) | No caller writes `hdr-enabled` (list above). | `hdrEnabled` is a constant `true`. The HDR-off branches do not exist: no "SDR when HDR is off" request, no HDR condition on the Dolby Vision fallback, no HDR term in the EDR decision. A write of `hdr-enabled` would now reach mpv as an ordinary property and fail. |
| Gravity changes when `panscan` or `video-aspect-override` is set through the setters | No caller writes either (list above). | They would be forwarded to mpv like any other property, with no gravity change. |
| The simulator's run-time override of `hwdec` writes | No caller writes `hwdec` at run time (list above). The start-up option is still `no` in the simulator (section 6.3). | Nothing. |
| Refusal of the renderer option names `vo`, `wid`, `gpu-api`, `gpu-context`, `avfoundation-composite-osd` and `avfoundation-pip-composite-osd` in the setters | No caller passes them (list above). The bridge's own compositing write has its own path. | Nothing. |
| A 64-bit integer property setter | No caller. | Nothing. |
| A second Picture in Picture flag | Declared but never set anywhere. | Every Picture in Picture condition tests only `isPipActive`. |
| `updateFrame` with an explicit frame | Every call passes no argument. | Keep the signature; a non-nil frame needs no particular behaviour. |
| `setVisible(false)` | The adapter only passes `true`. | Keep the signature; `false` needs no particular behaviour. |
| A second `initialize` on an initialised core | The adapter creates a new core for every load and initialises it once. | Need not be supported; returning `true` with no other effect is the simplest safe choice. |
| Getters no caller reads: cached duration, time position, video size, signal peak, Dolby Vision profile and level, container frame rate, and "has a live handle"; plus the duration and time-position caches that fed only those getters | No reference outside the current files. | No public API. The pause state, signal peak and display caches still exist internally where sections 6 and 8 use them. |
| A `DEBUG`-only hook that feeds a synthetic `pause` observation | No test calls it. | Nothing. |
| The debug trace function, its "is this a verbose level" helper and every trace message | The trace gate is a constant that is off in every build, so nothing is ever printed. | No debug output at all (section 10.2). |
| A synchronous destroy variant and its "already on the event queue" detection | Production always destroys asynchronously. | Destruction is always enqueued (section 6.17). |
| The tvOS 17 availability fallback that cleared display criteria as unavailable | The tvOS deployment target is 26.0. | Nothing. |
| The external-display scene delegate class, the scene disconnect and geometry-update handling that only it reaches, and the window value returned from adoption | `iosApp/iosApp/Info.plist` has no `UIApplicationSceneManifest`, no app delegate implements `application(_:configurationForConnecting:options:)`, and nothing names the class. | Nothing. Consequence: an adopted scene is never released (section 14.2). |
| Two unused scene helpers on the external-display type | No caller. | Nothing. |
| macOS-only code | The files compile only for iOS and tvOS. | Nothing. |
| Handling of a reply whose kind differs from its registered request | Request numbers are unique per core, so it cannot occur. | Nothing. |
| A trace on `MPV_EVENT_SHUTDOWN` | Compiled out. | The event is ignored. |

If a later change needs any of these, specify it then as new Vivid behaviour.

## 14. Known quirks reproduced deliberately

These behaviours are probably not ideal, but they are current behaviour and blurbery describes playback as perfect. Reproduce each exactly. Each is a candidate for a later, separate fix with its own testing.

### 14.1 Dispose during playback restart can clear Apple TV criteria

If `dispose` runs on main while the event queue is handling `MPV_EVENT_PLAYBACK_RESTART`, the snapshot's synchronous reads can return nothing (the handle has left the state), the snapshot then releases the hold with zero and absent values, and the cached apply it schedules can reach the platform write with zero dimensions, which clears the criteria, even when `preserveDisplayCriteria` was requested. The window is a fraction of a millisecond at teardown. It happens only because all four of these hold, so keep all four:

1. The cached apply's main block has no terminal check.
2. Disposal sets the hold under the cache guard only, without the source-transition exclusion.
3. The restart snapshot releases the hold unconditionally, even when every read failed.
4. `dispose` does not forget the remembered window, and the platform write falls back to it when the container has gone.

### 14.2 An adopted external scene is never released

Nothing handles an external scene disconnecting (section 13). If the coordinator ever adopts a scene, it keeps the scene, its window and its root view controller for the rest of the process, the external root view stays non-nil, and later attaches skip discovery. After the display is unplugged, a visible core keeps moving its container into a window on a dead scene and covers the main window with the black cover view, so the viewer sees black on the device and nothing elsewhere. The external window also stays up (black) after the player closes while the scene is adopted. Do not restore disconnect handling as part of this rewrite.

### 14.3 `vid=auto` on every return

Will-enter-foreground and iOS scene activation send `vid=auto` (unless Picture in Picture is active) even for audio-only loads that started with `vid=no`, so a file with a selectable video or cover-art track gets it back on return.

### 14.4 Dolby Vision profile 8 always uses compatibility id 1

The configuration record uses compatibility id 1 for every profile 8 stream (including 8.4, which is HLG-based) and 0 for every other profile without a supplied id. The bridge never reads the real id from mpv, although the adapter reads `dolby-vision-compatibility-id` from `track-list` for its own label.

### 14.5 Profile 7 is requested as 8.1

Profile 7 is always requested as profile 8 with compatibility 1 and PQ, BT.2020 defaults, on the assumption that the pinned decoder converts it (section 8.8).

### 14.6 Dolby Vision is requested without a display capability check

Dolby Vision sources skip `AVPlayer.availableHDRModes`; only HDR10 and HLG are filtered. The Dolby Vision fallback (when no hint can be built) uses the unfiltered base range.

### 14.7 Other parity-required behaviour

- The final-stop clear on tvOS is not gated by `matchContentEnabled` or the system setting, and clears criteria set by anyone.
- Hints use the HEVC codec type for every non-Dolby-Vision request and `dvh1` for every Dolby Vision request, whatever the real codec.
- SDR video tagged with BT.2020 primaries or matrix is requested as HDR10.
- An audio-only load clears criteria preserved from the previous video at its restart snapshot (zero size).
- A seek re-measures the cadence, so it can change field detection and the requested rate mid-stream.
- `display-criteria-prepared` is delivered while the source-transition exclusion is held. A delegate that synchronously re-entered display code would deadlock; the adapter's delegate hops through a `Task`, so it is safe today.
- On iOS the container is hidden when `initialize` returns and revealed by `setVisible(true)`; on tvOS it is never hidden.
- External screens are discovered only when a core attaches (once per load); a display connected mid-playback is used from the next load.
- If two cores are alive and visible at once, both can place their containers in the shared external root view.
- If the window passed to `initialize` has no scene, the iOS lifecycle observers receive every scene's notifications.
- While backgrounded, changes to non-critical properties (for example `track-list`) are dropped, not replayed on return.
- `observeProperty` silently ignores unknown format strings, including `int64`.
- EDR is re-applied on every host layout pass.
- With Picture in Picture off, every trip to the background and back destroys and rebuilds the engine's video output (section 6.18).
- Hook events without data are ignored without a continue (mpv never sends one).
- Width and height are truncated from `Double` to `Int32` for the platform write; an out-of-range value traps.

## 15. Parity hazards

Places where a natural rewrite would silently change behaviour.

Types and payloads:

1. `end-file`'s `reason` and `error` are Swift `Int`; every `sourceId` is `Int64`; node integers are `Int64`, flags `Bool`, fractions `Double`. A wrong type fails `as?` silently (for example, `reason` as `Int64` would stop natural end of file from ever being recognised).
2. Node arrays drop nil children (indices shift), maps drop nil values, and a map with a byte array and bad or partial dimensions becomes nil as a whole. Do not "improve" any of these.
3. For a non-null pointer, string decoding never yields nil or replacement characters: invalid UTF-8 becomes one character per byte.
4. `positionSeconds` is omitted, not set to 0, when `time-pos` is unavailable or not finite.
5. `start-file` without data forgets the remembered source id; `end-file` uses its own event id and does not clear the remembered one.

Ordering and delivery:

6. Exactly one `DispatchQueue.main.async` hop per ordered delivery. No `Task`, no second hop.
7. A replaced coalesced value keeps its original position; every ordered item delivers the pending coalesced values ahead of itself in the same main block.
8. Start-of-file and end-of-file holds happen before their delegate events. The restart snapshot schedules the display apply before dispatching `playback-restart`.
9. Completions use the inline-or-main rule exactly as in section 6.13.3; the adapter's checked continuations depend on exactly-once completion.
10. Requests reach mpv in call order; the adapter relies on a seek being queued immediately before an `audio-spdif` change.

Threads, locks and deadlocks:

11. Never hold the liveness guard across a blocking mpv call; never make main wait on the event queue; never destroy a stored context from main. The only context destroyed on main is one that set-up created but never stored (section 6.2).
12. Source-transition exclusion before cache guard; the platform write runs with the exclusion held and the cache guard released; the liveness guard is never held together with the cache or coalescing guard (section 5.3 rule 8).
13. Request registration is atomic with the liveness check; cancellation and replies both remove entries under the guard.
14. Free the command argument copies only after `mpv_command_async` returns.
15. Notification handlers run synchronously on the posting thread, and `isPipActive` is read at that moment (the adapter sets it synchronously in will-start, before the background notification of an automatic start).

Lifetime and teardown:

16. The wakeup relay holds the core weakly, is retained once, is detached before destruction, and is released only on the event queue after the wakeup callback is cleared and the handle destroyed. Releasing it earlier lets a late wakeup touch freed memory.
17. Drain, delivery, apply and early-write blocks hold the core weakly; the EDR hop keeps it alive and does not check disposal. The last release of a core can therefore happen on the event queue, in an EDR block or, for a core that was never disposed, on mpv's wakeup thread while the relay schedules a drain; `deinit` then calls `dispose`. Nothing that `dispose` enqueues may capture the core, strongly or weakly (section 6.17.2). Do not add main-thread-only work that assumes `deinit` runs on main.
18. The base has no `deinit` work; bare instances are created and released on background threads.
19. The first `dispose` calls its completion exactly once, on the event queue, even without a handle; a second `dispose` never calls its completion.
19a. A failed `initialize` keeps the remembered window and host view, so a later non-preserving `dispose` on tvOS can still clear the criteria (section 6.2).
20. The tvOS clear in `dispose` is synchronous and happens before mpv teardown is queued and before the container leaves its window.
21. UIKit teardown in `dispose` happens after the destroy step is queued, not after it runs; the engine's own reference to the layer makes this safe.

Surfaces:

22. Keep the exact nesting: layer directly in the container's layer, container directly in the host view at index 0. One new container and layer per core; never replace the host view.
23. After creation, size the layer only as section 7.5 describes. Disable implicit actions for every geometry, visibility, placement and EDR change. Write exact values only.
24. `contentsScale` comes from the container's own window's screen first, then the remembered window's screen, then the main screen; `nativeScale` if above 0, else `scale`.
25. Everything the viewer can see during moves and loads is black: container, layer background, cover view, external window and its root view. The layer is opaque.
26. When the container is already in the right superview but not at index 0, re-insert it at index 0.
27. `setPipSubtitleCompositing` sends its write on every call, not only on changes.
28. Layer recovery is `flush()` (never `flushAndRemoveImage`) and only when `requiresFlushToResumeDecoding` or `status == .failed`. The only bridge-issued seek is the paused redraw on iOS activation; do not add a seek on foreground.

Match Content:

29. Held from creation and from every start and end of file until the restart snapshot. Observers never write unavailable values; a nil `width` or `height` schedules nothing.
30. The restart snapshot overwrites everything, including absent colour tags and zero numbers.
31. Early snapshot reads `video-out-params`; restart snapshot reads `video-params`. Do not unify.
32. The early snapshot runs at most once per file, clears its flag on the event queue before hopping to main, re-checks the epoch and the hold on main under the exclusion, never writes caches and never releases the hold.
33. The two "no action" conditions (Match Content flag off, no window) win over every clearing condition; the identity is compared only after a hint is built; an identity match also needs `preferredDisplayCriteria` to be non-nil.
34. Snap the rate first, then convert to `Float`, then compare. A tiny difference such as 23.976 versus 23.9761 must not cause a new write.
35. The identity slot is process-wide, shared by every core of the selected bridge.
36. Of the two source holds, only the start-of-file hold resets the measured cadence; the end-of-file hold leaves it.

Values and flags:

37. Simulator wins over platform in option selection; the tvOS simulator never gets host presentation.
38. `pause` parsing is case-insensitive and accepts `on`.
39. Internal observers are suppressed by reply userdata, not name, so `container-fps` updates caches twice and is delivered once.
40. Backgrounding drops non-critical property deliveries and every log message, and nothing else.
41. `selectsAudioWhilePreloading` is read once, during set-up; the preload hook is always continued.
42. `keep-open=yes` must remain.
43. Never introduce the strings in section 10.4, and never add handling for mpv events, notifications, memory warnings or audio session changes that the current bridge ignores.

## 16. Test checklist

### 16.1 How the tests relate to the two bridges

- Both bridges compile in every configuration, so new unit tests should name the new types (`VividPlayerCoreBase`, `VividPlayerCore`, `VividExternalDisplay`) directly. They then run in CI with `VIVID_OWN_BRIDGE` off. Put the new coalescing and conversion tests in both test targets (`VividTests` and `VividTVTests`).
- `iosApp/Tests/MpvPropertyCoalescingTests.swift` switches to the selection aliases (section 4.5), so it tests the selected bridge. It is compiled only into the iOS test target today (`iosApp/project.yml` lists five files for `VividTVTests`), so its scenarios do not run on tvOS unless it is added there.
- Before the switch-over, run the complete iOS suite (normal and optimised builds, as `.github/workflows/player-regression.yml` does) and the tvOS suite on simulators with `VIVID_OWN_BRIDGE` added to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`. These engine-level tests drive real media through the selected bridge, via the adapter: `PlayerSurfaceLayoutTests` (section 4.1); `VividPlaybackBoundaryTests`, including `testInitialAudioOrdinalResolvesInsideTheFirstOpen` (the `on_preloaded` choice end to end) and `testEmbeddedPickerTracksRemainSelectableAfterPrimaryClears`; and `VividPlaybackStatsProjectionTests.testSimulatorPlaybackKeepsTransportWorkingThroughTelemetryUpdates` (in both test targets). With the flag off they test only the current bridge.
- `scripts/tests/playback-end-recovery-tests.py` (run by `.github/workflows/player-regression.yml` on any change under `iosApp/iosApp/**`) keeps testing the current base file while the flag is off. It extracts private code from that file by text, so it cannot test the new bridge. The switch-over change must retarget it (or replace its bridge section) so the behaviours under "Display criteria" in section 16.2 are checked against the new code. The clean side adds equivalent tests for the new code from this section; design the new code so the early snapshot, the cached apply and the holds can be exercised without a live mpv context (for example, by making the synchronous reads and the platform write replaceable in tests).
- `scripts/tests/mpv-track-tests.py` needs no change: the text of `VividMPVPlayer.stop()` stays identical.

### 16.2 Automated (unit-testable) behaviours

Construction and conversion:

- [ ] A bare base instance can be created and released on a background thread with no side effects, and `convertNode` works on it.
- [ ] `convertNode` returns `Int64` for `MPV_FORMAT_INT64`, `Bool` for `MPV_FORMAT_FLAG`, `Double` for `MPV_FORMAT_DOUBLE` (NaN passes through), `String` for `MPV_FORMAT_STRING`, and `Data` for `MPV_FORMAT_BYTE_ARRAY` (empty `Data` for size 0).
- [ ] An array with a child that converts to nil comes back shorter, in order.
- [ ] A map entry with a null key or a nil value is omitted; a duplicate key keeps the last value.
- [ ] Depth 32 converts; depth 33 is nil. A container whose count exceeds the remaining entries is nil; a string or byte array larger than the remaining bytes is nil; budgets are per top-level call.
- [ ] A map containing a byte array with `w` 16,384 and `h` 4,096 converts; with `w` 16,385, `w` 0, only `w`, or `w` 2.5 (a non-integral double) it is nil; with integral double dimensions it converts. A map without a byte array converts whatever its dimensions.
- [ ] Invalid UTF-8 decodes byte for byte as Latin-1, in property names, values, log text and node strings.

Delivery and payloads:

- [ ] The three coalescing scenarios in section 6.10 (the existing tests) pass unchanged.
- [ ] `dispatchDelegateEvent` with a source id and nil data delivers `["sourceId": Int64]`; without a source id it delivers the data unchanged (possibly nil).
- [ ] `end-file` after a natural end has `reason` 0 as `Int`; after a load failure, `reason` 4, `error` as a negative `Int` and `message` as `String`; `sourceId` is `Int64`.
- [ ] `playback-restart` carries `positionSeconds` as `Double` when `time-pos` is readable, and omits it otherwise.
- [ ] `log-message` carries `prefix`, `level` and `text` as `String`, empty when null, and no `sourceId`.
- [ ] While backgrounded, `time-pos` and `pause` still arrive, `track-list` and `log-message` do not, and events still arrive.
- [ ] Internal observations (`width`, `height`, the `video-params/*` sub-properties, the Dolby Vision sub-properties, `deinterlace-active`) never reach the delegate through their internal registration; `container-fps`, also observed by the adapter, reaches it once per change.
- [ ] After `beginDisposal()`, nothing further is delivered, including pending coalesced values.

Requests:

- [ ] `setPropertyAsync` and `getPropertyAsync` on a disposed core, called on main, complete with the not-available error before returning.
- [ ] `commandAsync([])` completes with success and nil inline on main, even on a terminal core.
- [ ] A `loadfile` command completes with an `Int64` id equal to the `sourceId` that the loaded file's events carry; any other command completes with nil.
- [ ] A command or set that mpv rejects completes with an mpv error carrying the negative status and mpv's message, asynchronously on main.
- [ ] `getPropertyAsync("display-fps")` returns a numeric string; an unavailable property completes with an mpv error.
- [ ] Requests pending at `dispose` complete exactly once with the disposed error.
- [ ] A core released without an explicit `dispose` (so its `deinit` disposes) does not crash: nothing disposal enqueues refers to the core.
- [ ] Every completion runs exactly once in every path (wrap them in checked continuations in the tests).

Pause cache (section 6.12):

- [ ] Every row of the scenario table, including that `pause` with `ON` or `on` means paused and that a failing request reverts the displayed value.
- [ ] Scene activation issues the paused redraw only when the displayed value is paused.

Display criteria (restating the bridge assertions of the current CI harness as behaviour). Default fixture: early snapshot enabled; decoded output 1920 x 1080 with transfer `bt.1886`; empty track map; container 24 fps and measured 24 fps; deinterlace flag false; "early snapshot wanted" and the hold both set; core live.

- [ ] 1. The early snapshot does not perform the platform write synchronously; the write is dispatched to main.
- [ ] 2. After main runs, exactly one write happens, at 24 Hz: matching starts from the decoded cadence before playback restart.
- [ ] 3. The hold is still set after the early write, so partial observer updates stay held until the restart snapshot.
- [ ] 4. A successful early write emits exactly one `display-criteria-prepared`.
- [ ] 5. A second early snapshot after a successful write does not write again.
- [ ] 6. There is no write, and "early snapshot wanted" stays set, when any of these holds: early snapshot disabled; output parameters missing; width 0; track map missing; container rate missing; container rate NaN; measured rate 0; measured rate infinite; deinterlace flag missing.
- [ ] 7. After an incomplete snapshot, a later complete one writes exactly once.
- [ ] 8. There is no write if, after the event-queue part but before main runs, the epoch advances, the hold is released, or the core becomes terminal.
- [ ] 9. Container 25 with measured 50 writes 50 Hz.
- [ ] 10. Container 25 with measured 25 and the deinterlacer active writes 50 Hz.
- [ ] 11. Dolby Vision profile 7 with no transfer writes profile 8, compatibility 1 and transfer `smpte2084`.
- [ ] 12. A transfer of `smpte2084` passes through unchanged.
- [ ] 13. When the platform write reports failure, no `display-criteria-prepared` is sent.
- [ ] 14. During the early platform write the source-transition exclusion is held and the cache guard is not.
- [ ] 15. During the cached apply's platform write the exclusion is held and the cache guard is not; it writes once and clears the "apply scheduled" mark.
- [ ] 16. After an end-of-file hold, a queued cached apply writes nothing; the same after a start-of-file hold.
- [ ] 17. The cached apply's early return while held releases the exclusion.
- [ ] 18. In `VIVID_P8_TRIAL` builds, an end-of-file hold then a start-of-file hold report `display-commit-lock` with transitions `end_file` then `start_file`, and non-negative `wait_ms` and `held_ms`.

The harness assumes the dimension check accepts sizes from 1 to 16,384 and that snapping maps 24 to 24 and 50 to 50.

Cadence and snapping:

- [ ] Field output: (container 25, measured 50) true; (25, 25) false; (20, 34.2) true (1.71); (20, 45.8) true (2.29); (25, 42.5) false (exactly 1.7); (10, 23) false (exactly 2.3); (0, 50) false.
- [ ] Snapping: 23.9 to 23.976; 59.9 to 59.94; 47.9 to 48; 23.5 stays 23.5; 45 stays 45; 0 and NaN give 0.

tvOS platform write (testable with an injected display manager or on a device):

- [ ] Each outcome row of section 8.9, including that the Match Content flag being off or no window never clears, and that an identity match with nil current criteria writes again.
- [ ] The configuration record bytes for profile 8 level 6 (compatibility 1), profile 5 (compatibility 0, `dvcC`) and profile 7 (requested as 8 with compatibility 1, `dvvC`).
- [ ] The range table in section 8.16, including BT.2020-tagged SDR as HDR10 and HLG falling back to SDR when unavailable.

Lifecycle:

- [ ] A failed `initialize` leaves no layer or container in the host view, and a later non-preserving `dispose` on tvOS still clears the criteria through the remembered window.
- [ ] `initialize` returns true; the `wid` layer is `sampleBufferDisplayLayer`; the layer's grandparent layer is the host view's layer; on iOS the container is hidden until `setVisible(true)`.
- [ ] `dispose` calls its completion exactly once, off main, after the context is destroyed; a second `dispose` is a no-op; `dispose` after a failed set-up still calls its completion.
- [ ] Two cores (one disposing, one loading) run side by side with independent queues, requests and caches; a preserving dispose followed by an identical commit from the new core does not write again.
- [ ] Console output in normal playback is empty except, in a build that still links the third-party package without the old driver rebuild, the `MPV error: option not found` lines described in section 6.19.
- [ ] The app binary does not contain `first start recovery after` or `trace edge %s` from Swift sources (search the built product when the engine slice is unpatched).

### 16.3 Device tests

Record for each: device, OS, source (codec, range, frame rate, container), route, build and bridge (flag on or off). Compare the current and new bridges side by side where possible.

Apple TV, with Match Dynamic Range and Match Frame Rate on:

- [ ] HDR10 23.976 film: one switch to HDR10 at 23.976 Hz early in start-up; playback continues through the TV's blackout; no second switch at the first frame. In a trace build, `display-criteria-prepared` before `playback-restart` and exactly one `display-switch-started` and `display-switch-ended` pair.
- [ ] Dolby Vision profile 8.1 MKV: Dolby Vision at the film's rate, with normal brightness and colour.
- [ ] Dolby Vision profile 5 file: Dolby Vision mode with correct colours.
- [ ] Dolby Vision profile 7 (dual-layer remux): Dolby Vision mode; diagnostics label profile 8.1.
- [ ] HLG clip: HLG on an HLG-capable TV, SDR otherwise.
- [ ] SDR 25 and 29.97 fps episodes: 25 Hz and 29.97 Hz.
- [ ] Interlaced 1080i50 and 1080i59.94: 50 Hz and 59.94 Hz, not 25 or 29.97.
- [ ] A file whose declared rate is slightly off nominal (for example 23.9 or 59.9) requests the nominal rate; a 12.5 fps file requests 12.5.
- [ ] Two consecutive episodes of the same format, through Next Up and through Play Now: no renegotiation between them.
- [ ] An HDR10 episode followed by an SDR episode: one switch to SDR early in the second episode, with no clear in between.
- [ ] Close the player: the TV returns to its default mode promptly; no film rate lingers on the Home screen.
- [ ] Seek several times in a 23.976 film: no mode switches; the last frame stays on screen during each seek.
- [ ] Press Home during playback and return: video comes back (the engine rebuilds its video output), the HDMI mode is unchanged and there is no extra switch. Note any brief black frame and compare the two bridges.
- [ ] Start a title that fails to load straight after one that played (for example a damaged file), then close the player: the TV returns to its default mode.
- [ ] Match Content setting by load path (section 8.14): a server-plan load started with the setting off never writes or clears; a direct-without-options or offline load started with it off clears instead of writing, and turning it on mid-play switches at the next re-evaluation (for example after a seek); any load started with it on clears at the next re-evaluation after turning it off.
- [ ] An audio-only item after a video item clears the criteria at the audio item's start.
- [ ] Resume a 4K Dolby Vision title with a planned audio track: only one seek, and the planned track plays. Start Over and resume prompts behave as before. Loading never stalls when there is no plan or the plan cannot be matched.
- [ ] Embedded ASS and PGS subtitles over HDR10 and Dolby Vision, without dimming the video.
- [ ] AirPlay audio to HomePod while video plays on the TV: picture and sound in sync after start, pause, resume and seeks.
- [ ] A long session (two hours or more, 4K Dolby Vision): no drift, no growing stutter, steady memory.

iPhone and iPad:

- [ ] HDR10 and Dolby Vision on an HDR-capable device: highlights brighter than UI white; SDR not boosted. On iOS 26 the layer's preferred dynamic range follows; on iOS 18 to 25 the EDR flag does.
- [ ] Rotation, iPad split-view resizing, preview to full-screen transitions and the Next Up mini player: video snaps to size with no stretch animation or black flash; the same layer stays; subtitles reposition after each resize.
- [ ] Picture in Picture from the button and automatically on swiping home: subtitles burned in; play, pause and skip work; returning restores the separate subtitle layer; a paused video shows the right frame.
- [ ] Picture in Picture across Next Up: the window stays and switches to the new episode.
- [ ] Background with background playback on and Picture in Picture off: audio continues and video is disabled; on return video comes back, and a paused video shows its frame again.
- [ ] Background with background playback off: playback pauses.
- [ ] Lock and unlock while paused and while playing.
- [ ] Control Centre pull-down and release while paused: one paused redraw (a brief seeking state), picture unchanged.
- [ ] AirPlay audio route change during playback: audio moves, video stays on the device.
- [ ] External display with an HDMI adapter, and with AirPlay Screen Mirroring: record whether video moves to the external screen (with a black device screen) or mirrors, and the latest-playback report's `externalScreen` value. Unplug during playback and record what each bridge shows (section 14.2).
- [ ] Simulator: software decoding works.

## 17. Amendments after implementation

Recorded after the first implementation and its reviews, as behaviour and decisions. Where this section differs from an earlier one, this section wins.

### 17.1 Extra files for internal components

Coordinator decision: the implementation may add internal top-level types prefixed `VividPlayer`, in extra files, to split the bridge into a centre plus outer components (video surface, display criteria, external display, lifecycle observation). This overrides the top-level rule in section 3 in that respect only. Everything else in that rule still applies: no top-level functions, variables or constants, no extensions on system types, no explicit `@objc(...)` runtime names, and no clash with the current files.

### 17.2 Wakeup callback and guard nesting

The wakeup callback is installed while the liveness guard is held (section 6.2), and mpv may call it synchronously on the calling thread, so the relay guard can be taken while the liveness guard is held. This nesting is allowed (the current bridge does the same), provided nothing ever takes the liveness guard while holding the relay guard. This amends section 5.3 rules 7 and 8.

### 17.3 Last-resort screen on tvOS

When choosing the screen for `contentsScale` (section 7.5), the last resort on tvOS may be the screen of the first connected window scene instead of `UIScreen.main`. On Apple TV they are the same screen.

### 17.4 Answers to the implementer's questions

- The pause state (section 6.12) may use its own leaf lock (one under which no other guard is ever taken) instead of the cache guard.
- In a map that carries a byte array (section 6.16.3), `width` and `w` count as one axis and the last occurrence of either key wins; `height` and `h` likewise.
- A non-nil `width` or `height` value that is not a `Double` schedules a cached apply but is not stored; only a `Double` is stored (section 6.9).
- A property change whose name pointer is null is ignored (section 6.6).
- A reply whose kind does not match its pending request removes that request, and the request's completion is never called (section 6.13.1; this replaces the corresponding row of section 13).
- A second `initialize` on an initialised core remembers the newly passed host view and returns `true` with no other effect (this replaces the corresponding row of section 13).
- The default Dolby Vision compatibility id (1 for profile 8, otherwise 0) is chosen from the full profile value, not the 8-bit truncated one; the `dvvC` or `dvcC` choice still uses the truncated profile (section 8.11).
- The layer's geometry (`bounds`, `position` and `contentsScale`) may be written only when it changes, because the engine ignores unchanged values (sections 7.2 and 7.5).
- The deprecated layer calls the bridge uses (such as `requiresFlushToResumeDecoding`, `status` and `flush()` on `AVSampleBufferDisplayLayer`) and `AVPlayer.availableHDRModes` stay for parity, despite deprecation warnings.

### 17.5 Console locations of the start-up checks

The bridge's own start-up checks (the log level request, `wid`, each bridge option and `mpv_hook_add`) must each report a distinct console location in the ` at <file>:<line>` part, so a failure identifies the option. They still pass no option name, so their lines carry no ` option=` detail (section 10.2).

### 17.6 Registration order of the internal observations

The ten internal observations (section 6.7) are registered in this order: `video-params/sig-peak`, `width`, `height`, `current-tracks/video/dolby-vision-profile`, `current-tracks/video/dolby-vision-level`, `container-fps`, `deinterlace-active`, `video-params/gamma`, `video-params/primaries`, `video-params/colormatrix`. This replaces the statement in section 6.7 that the order is not significant.

### 17.7 Audio-output option meanings

Corrections from the engine specification, applied to the section 6.19 table and its closing paragraph:

- `ao-avfoundation-compressed-first-start-grace` applies to the first start of each audio output instance, until that instance's clock first moves, not only to a title's first start. On an AC-3 or E-AC-3 track every speed change across 1x creates a new instance, so the shorter grace applies again after each one; on other tracks a crossing keeps the same instance, and the compressed sink is not used at all (section 17.11). It is capped at `ao-avfoundation-compressed-start-grace`.
- With `ao-avfoundation-manage-audio-session=no`, the output sets no category or mode and never activates or deactivates the session, but it still declares multichannel content (passthrough, or more than two channels) and still sets the preferred output channel count for decoded audio. Vivid's session recorder reads both.
- `ao-avfoundation-compressed-start-grace` is also the deadline between the recovery and the fallback to decoded audio, extended by the same amount each time a slow source delivers more.
- `audio-exclusive` has no effect on this audio output.
- Every `ao-avfoundation-*` option belongs to Vivid's own engine and is accepted by every build that links it. Only a build that still links the third-party package without the old driver rebuild rejects them, with the console lines described in section 6.19.

### 17.8 Zoom, pan and scale options and subtitles

The engine never re-renders, scales or moves the picture for `video-zoom`, `video-pan-x`, `video-pan-y`, `video-scale-x` or `video-scale-y`, but mpv still applies them to the rectangle that separate-layer subtitles are placed against, so setting them would move subtitles away from the picture. The rule that the bridge never sets them is unchanged; the reason in section 7.2 is corrected.

### 17.9 Main-thread wait after a subtitle-layer resynchronisation

The engine also waits synchronously for the main thread on the first frame it draws after any subtitle-layer resynchronisation (after a reconfiguration, an option or `panscan` change, a real resize, or a switch of subtitle compositing), when it re-reads the layer geometry. This is added to the list in section 7.2. The bridge rule is unchanged: the main thread never blocks waiting on mpv.

### 17.10 Video output for cover art

An audio-only load also gets a video output whenever `vid=auto` selects embedded cover art (mpv's default `audio-display` is `embedded-first`). The bridge writes `vid=auto` on every return to the foreground and every iOS activation, with no audio-only check (section 14.3), so this can happen at those moments. The layer must be in its parent then too, which the guarantee in section 7.2 already requires; its reason now says so.

### 17.11 Speed changes and the audio output

Correction from the engine specification (its sections 1.7 and 3.1), applied to the `ao-avfoundation-compressed-first-start-grace` row in section 6.19 and its bullet in section 17.7, which said that every speed change across 1x creates a new audio output instance.

A speed change across 1x replaces the audio output only on an AC-3 or E-AC-3 track. There the adapter's `audio-spdif` write swaps passthrough for decoded PCM or back, so mpv closes the audio output and opens a new one, which starts from scratch. On any other track (DTS, TrueHD, AAC and the rest, decoded to PCM at every speed), the crossing still changes `audio-spdif`, so mpv rebuilds its audio decoder and filters, but it keeps the same audio output: no new instance, no reset and no fresh sink. If mpv's queued audio runs out before the rebuilt chain refills it, mpv starts that same output again. Those tracks never use the compressed sink, so the option does not apply to them; the earlier wording would only have led a tester to expect output replacements that never happen.

Nothing changes for the bridge: it sets no audio option, and the adapter's speed and `audio-spdif` writes (section 6.19) are as before.
