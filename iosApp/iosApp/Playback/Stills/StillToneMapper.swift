import Foundation

/// Turns a small 16-bit HDR picture into 8-bit sRGB for a scrub preview.
///
/// Each pixel goes through four steps:
///
/// 1. Linearise. PQ (SMPTE ST 2084) code values give absolute light:
///    `L = 10000 * (max(p - c1, 0) / (c2 - c3 * p)) ^ (1 / m1)` nits, with
///    `p = E ^ (1 / m2)`. HLG (BT.2100) code values give scene light,
///    `E^2 / 3` up to a half and `(exp((E - c) / a) + b) / 12` above it,
///    which a nominal 1000 nit display shows as `1000 * Y^0.2 * E`, where
///    `Y` is the pixel's luminance.
/// 2. Move from the source's primaries to BT.709 with a 3 by 3 matrix, and
///    drop what falls below zero.
/// 3. Roll off. With `x` the light in units of 100 nits, the SDR reference
///    white, `y = x * (1 + x / 100) / (1 + x)`. Dark tones stay close to
///    where they were, HDR diffuse white (203 nits) lands at about 0.68 and
///    1000 nits reaches exactly 1.
/// 4. Encode as sRGB.
///
/// Steps 1 and 4 come from tables, so a 320 pixel wide picture takes a
/// fraction of a millisecond.
enum StillToneMapper {
    enum Transfer: Sendable {
        case sdr, pq, hlg
    }

    enum Primaries: Sendable {
        case bt709, bt2020, p3
    }

    static let referenceWhiteNits = 100.0
    static let peakNits = 1000.0

    private static let tableSize = 4096

    /// PQ code (12 bits) to light in units of the SDR reference white.
    private static let pqTable: [Float] = (0..<tableSize).map { step in
        let m1 = 2610.0 / 16384.0
        let m2 = 2523.0 / 4096.0 * 128.0
        let c1 = 3424.0 / 4096.0
        let c2 = 2413.0 / 4096.0 * 32.0
        let c3 = 2392.0 / 4096.0 * 32.0
        let power = pow(Double(step) / Double(tableSize - 1), 1.0 / m2)
        let nits = 10000.0 * pow(max(power - c1, 0) / (c2 - c3 * power), 1.0 / m1)
        return Float(nits / referenceWhiteNits)
    }

    /// HLG code (12 bits) to scene light, 0 to 1.
    private static let hlgTable: [Float] = (0..<tableSize).map { step in
        let a = 0.17883277
        let b = 0.28466892
        let c = 0.55991073
        let signal = Double(step) / Double(tableSize - 1)
        return Float(signal <= 0.5 ? signal * signal / 3.0 : (exp((signal - c) / a) + b) / 12.0)
    }

    /// Scene luminance (12 bits) to what scene light is multiplied by to
    /// get display light in units of the SDR reference white.
    private static let hlgGainTable: [Float] = (0..<tableSize).map { step in
        let luminance = Double(step) / Double(tableSize - 1)
        return Float(peakNits / referenceWhiteNits * pow(luminance, 0.2))
    }

    /// Linear light (12 bits, 0 to 1) to an sRGB byte.
    private static let srgbTable: [UInt8] = (0..<tableSize).map { step in
        let linear = Double(step) / Double(tableSize - 1)
        let encoded = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1.0 / 2.4) - 0.055
        return UInt8(max(0, min(255, (encoded * 255.0).rounded())))
    }

    private static func matrix(for primaries: Primaries) -> [Float] {
        switch primaries {
        case .bt709:
            [1, 0, 0, 0, 1, 0, 0, 0, 1]
        case .bt2020:
            [1.6605, -0.5876, -0.0728, -0.1246, 1.1329, -0.0083, -0.0182, -0.1006, 1.1187]
        case .p3:
            [1.2249, -0.2247, 0, -0.0420, 1.0419, 0, -0.0197, -0.0786, 1.0979]
        }
    }

    /// Maps rows of native-endian 16-bit RGBA to tightly packed 8-bit RGBA
    /// with a filled alpha byte. SDR input is only narrowed to 8 bits. Nil
    /// when the buffer is too small for the size given.
    static func map(rgba16 source: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int,
                    transfer: Transfer, primaries: Primaries) -> [UInt8]? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, bytesPerRow >= width * 8,
              let base = source.baseAddress
        else { return nil }
        // Worked so that no stride, however large, can overflow the sum.
        let (rows, overflowed) = bytesPerRow.multipliedReportingOverflow(by: height - 1)
        guard !overflowed, rows <= source.count - width * 8 else { return nil }
        var output = [UInt8](repeating: 255, count: width * height * 4)
        let m = matrix(for: primaries)
        let last = tableSize - 1
        let top = Float(last)
        // The roll-off's white point: the peak in units of reference white.
        let whiteSquared = Float((peakNits / referenceWhiteNits) * (peakNits / referenceWhiteNits))

        output.withUnsafeMutableBufferPointer { out in
            pqTable.withUnsafeBufferPointer { pq in
                hlgTable.withUnsafeBufferPointer { hlg in
                    hlgGainTable.withUnsafeBufferPointer { gain in
                        srgbTable.withUnsafeBufferPointer { srgb in
                            for row in 0..<height {
                                let line = (base + row * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                                var target = row * width * 4
                                for column in 0..<width {
                                    let red = Int(line[column * 4]), green = Int(line[column * 4 + 1]), blue = Int(line[column * 4 + 2])
                                    if transfer == .sdr {
                                        out[target] = UInt8((red * 255 + 32767) / 65535)
                                        out[target + 1] = UInt8((green * 255 + 32767) / 65535)
                                        out[target + 2] = UInt8((blue * 255 + 32767) / 65535)
                                        target += 4
                                        continue
                                    }
                                    // 16 bits down to the tables' 12, rounded.
                                    let ri = min((red + 8) >> 4, last), gi = min((green + 8) >> 4, last), bi = min((blue + 8) >> 4, last)
                                    var r: Float, g: Float, b: Float
                                    if transfer == .pq {
                                        r = pq[ri]; g = pq[gi]; b = pq[bi]
                                    } else {
                                        r = hlg[ri]; g = hlg[gi]; b = hlg[bi]
                                        // BT.2100's luminance weights for BT.2020 primaries.
                                        let luminance = 0.2627 * r + 0.6780 * g + 0.0593 * b
                                        let scale = gain[min(Int(luminance * top + 0.5), last)]
                                        r *= scale; g *= scale; b *= scale
                                    }
                                    let lr = max(m[0] * r + m[1] * g + m[2] * b, 0)
                                    let lg = max(m[3] * r + m[4] * g + m[5] * b, 0)
                                    let lb = max(m[6] * r + m[7] * g + m[8] * b, 0)
                                    let sr = min(lr * (1 + lr / whiteSquared) / (1 + lr), 1)
                                    let sg = min(lg * (1 + lg / whiteSquared) / (1 + lg), 1)
                                    let sb = min(lb * (1 + lb / whiteSquared) / (1 + lb), 1)
                                    out[target] = srgb[Int(sr * top + 0.5)]
                                    out[target + 1] = srgb[Int(sg * top + 0.5)]
                                    out[target + 2] = srgb[Int(sb * top + 0.5)]
                                    target += 4
                                }
                            }
                        }
                    }
                }
            }
        }
        return output
    }
}
