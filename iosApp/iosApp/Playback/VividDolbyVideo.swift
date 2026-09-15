// SPDX-License-Identifier: GPL-3.0-only
// Additional permission: LICENSE-APPLE-EXCEPTION at the repository root.
import Foundation

/// Stream classification and narrow Dolby format adapters. KSPlayer owns playback.
struct VividDolbyVideo {
    enum Format: String {
        case sdr, hdr10, hlg, unknown
        case profile5 = "dv_p5", profile7 = "dv_p7", profile8 = "dv_p8", unknownDV = "dv_unknown"
    }

    let format: Format
    let profile: UInt8?
    let level: UInt8?
    let compatibility: UInt8?
    let baseLayerPresent: Bool
    let enhancementLayerPresent: Bool
    let rpuPresent: Bool
    let baseFormat: Format

    init(profile: UInt8?, level: UInt8?, compatibility: UInt8?, baseLayerPresent: Bool,
         enhancementLayerPresent: Bool, rpuPresent: Bool, baseFormat: Format) {
        self.profile = profile
        self.level = level
        self.compatibility = compatibility
        self.baseLayerPresent = baseLayerPresent
        self.enhancementLayerPresent = enhancementLayerPresent
        self.rpuPresent = rpuPresent
        self.baseFormat = baseFormat
        switch profile {
        case nil: format = baseFormat
        case 5: format = .profile5
        case 7: format = .profile7
        case 8: format = .profile8
        default: format = .unknownDV
        }
    }

    /// Preserve the existing trial admission policy until native Dolby output is validated.
    var allowsBaselinePlayback: Bool {
        guard let profile else { return true }
        guard baseLayerPresent else { return false }
        return (profile == 7 && compatibility == 6) ||
            (profile == 8 && [UInt8(1), 2, 4].contains(compatibility ?? 0))
    }

    var isProfile8Candidate: Bool {
        profile == 8 && baseLayerPresent && rpuPresent && !enhancementLayerPresent &&
            [UInt8(1), 2, 4].contains(compatibility ?? 0)
    }

    /// Initial native trial is limited to the verified P8.1/PQ case.
    var isNativeProfile81Candidate: Bool {
        isProfile8Candidate && compatibility == 1 && baseFormat == .hdr10 &&
            (level.map { (1...63).contains($0) } ?? false)
    }

    /// ISO Dolby configuration payload, not per-frame RPU data. Reserved bytes remain zero.
    /// The stream's version is supplied by the public FFmpeg metadata record.
    func profile81Configuration(versionMajor: UInt8, versionMinor: UInt8) -> Data? {
        guard isNativeProfile81Candidate, versionMajor == 1, versionMinor == 0,
              let profile, let level, let compatibility else { return nil }
        let fields = (UInt16(profile) << 9) | (UInt16(level) << 3) | 0x05
        return Data([versionMajor, versionMinor, UInt8(fields >> 8), UInt8(fields & 0xff),
                     compatibility << 4] + Array(repeating: UInt8(0), count: 19))
    }

    var isNativeProfile5Candidate: Bool {
        profile == 5 && compatibility == 0 && baseLayerPresent && rpuPresent &&
            !enhancementLayerPresent && (level.map { (1...63).contains($0) } ?? false)
    }

    func profile5Configuration(versionMajor: UInt8, versionMinor: UInt8) -> Data? {
        guard isNativeProfile5Candidate, versionMajor == 1, versionMinor == 0,
              let level else { return nil }
        let fields = (UInt16(5) << 9) | (UInt16(level) << 3) | 0x05
        return Data([versionMajor, versionMinor, UInt8(fields >> 8), UInt8(fields & 0xff), 0] +
                    Array(repeating: UInt8(0), count: 19))
    }

    var diagnosticFields: String {
        "format=\(format.rawValue) profile=\(profile.map(String.init) ?? "none") " +
        "level=\(level.map(String.init) ?? "none") compatibility=\(compatibility.map(String.init) ?? "none") " +
        "bl=\(baseLayerPresent) el=\(enhancementLayerPresent) rpu=\(rpuPresent) " +
        "base_format=\(baseFormat.rawValue) p8_candidate=\(isProfile8Candidate) native_dv_verified=false"
    }
}

#if os(tvOS)
import AVFoundation
import KSPlayer

extension VividDolbyVideo {
    /// Preserve HEVC extradata, colour properties and source RPU packets. No conversion.
    static func profile81Format(track: FFmpegAssetTrack) -> CMFormatDescription? {
        let metadata = VividDolbyVideo(track: track)
        guard #available(tvOS 17.0, *), let dv = track.dovi,
              let payload = metadata.profile81Configuration(versionMajor: dv.dv_version_major,
                                                             versionMinor: dv.dv_version_minor),
              let base = track.formatDescription,
              CMFormatDescriptionGetMediaSubType(base) == kCMVideoCodecType_HEVC,
              var extensions = CMFormatDescriptionGetExtensions(base) as? [String: Any],
              var atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
              let hevc = atoms["hvcC"] as? Data, hevc.count >= 23 else { return nil }
        // P8 uses a backwards-compatible HEVC sample entry plus the dvvC record.
        // Do not retag P8 as P5, fabricate RPU data, or change transfer characteristics.
        atoms["dvvC"] = payload
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
        let dimensions = CMVideoFormatDescriptionGetDimensions(base)
        var result: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC, width: dimensions.width, height: dimensions.height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &result)
        return status == noErr ? result : nil
    }

    /// P5 has no HDR-compatible colour base. Ask Apple's Dolby decoder to interpret it.
    /// Apple's HDR metadata specification uses dvh1, dvcC and unspecified colour indices.
    static func profile5Format(track: FFmpegAssetTrack) -> CMFormatDescription? {
        let metadata = VividDolbyVideo(track: track)
        guard #available(tvOS 17.0, *), let dv = track.dovi,
              let payload = metadata.profile5Configuration(versionMajor: dv.dv_version_major,
                                                            versionMinor: dv.dv_version_minor),
              let base = track.formatDescription,
              [kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC].contains(CMFormatDescriptionGetMediaSubType(base)),
              var extensions = CMFormatDescriptionGetExtensions(base) as? [String: Any],
              var atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any],
              let hevc = atoms["hvcC"] as? Data, hevc.count >= 23 else { return nil }
        atoms["dvcC"] = payload
        // The source profile is P5. Do not leave an incompatible profile record or guessed PQ tags.
        atoms.removeValue(forKey: "dvvC")
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey,
                    kCVImageBufferYCbCrMatrixKey, kCMFormatDescriptionExtension_ColorPrimaries,
                    kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            extensions.removeValue(forKey: key as String)
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(base)
        var result: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_DolbyVisionHEVC, width: dimensions.width, height: dimensions.height,
            extensions: extensions as CFDictionary, formatDescriptionOut: &result)
        return status == noErr ? result : nil
    }

    init(track: some MediaPlayerTrack) {
        let baseFormat: Format
        if let description = track.formatDescription {
            // Transfer characteristics distinguish HDR from SDR; ten-bit alone is not HDR.
            let transfer = description.transferFunction
            if transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String {
                baseFormat = .hdr10
            } else if transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String {
                baseFormat = .hlg
            } else if transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String ||
                        transfer == kCVImageBufferTransferFunction_sRGB as String {
                baseFormat = .sdr
            } else {
                baseFormat = .unknown
            }
        } else {
            baseFormat = .unknown
        }
        let dv = track.dovi
        self.init(profile: dv?.dv_profile, level: dv?.dv_level,
                  compatibility: dv?.dv_bl_signal_compatibility_id,
                  baseLayerPresent: dv.map { $0.bl_present_flag != 0 } ?? false,
                  enhancementLayerPresent: dv.map { $0.el_present_flag != 0 } ?? false,
                  rpuPresent: dv.map { $0.rpu_present_flag != 0 } ?? false,
                  baseFormat: baseFormat)
    }
}
#endif
