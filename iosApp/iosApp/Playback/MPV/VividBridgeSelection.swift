// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
#if os(iOS) || os(tvOS)
// Both Lucid bridges are compiled into every build. These names pick the one
// the app uses: Vivid's own with `VIVID_OWN_BRIDGE`, otherwise the current one.
#if VIVID_OWN_BRIDGE
typealias VividBridgeCoreBase = VividPlayerCoreBase
typealias VividBridgeCore = VividPlayerCore
typealias VividBridgeCoreDelegate = VividPlayerCoreDelegate
typealias VividBridgeSampleBufferLayer = VividSampleBufferLayer
#if os(iOS)
typealias VividBridgeExternalDisplay = VividExternalDisplay
#endif
#else
typealias VividBridgeCoreBase = MpvPlayerCoreBase
typealias VividBridgeCore = MpvPlayerCore
typealias VividBridgeCoreDelegate = MpvPlayerDelegate
typealias VividBridgeSampleBufferLayer = MpvVideoLayer
#if os(iOS)
typealias VividBridgeExternalDisplay = ExternalDisplayManager
#endif
#endif
#endif
