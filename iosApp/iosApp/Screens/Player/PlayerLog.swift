//
//  PlayerLog.swift
//  Vivid (iOS + tvOS)
//
//  Single emission point for `[CMP-…]` player-pipeline trace lines.
//
//  Live player traces remain available through the Xcode console.

import Foundation

@inline(__always)
func cmpLog(_ message: @autoclosure () -> String, verbose: Bool = false) {
    let rendered = message()
    print(rendered)
    #if os(iOS) || os(tvOS)
    // Development builds also write redacted essential lines to the local Apple log.
    DiagTrace.log(
        verbose ? .verbose : .essential,
        level: .info,
        category: .playback,
        tag: "CMP",
        message: rendered
    )
    #endif
}
