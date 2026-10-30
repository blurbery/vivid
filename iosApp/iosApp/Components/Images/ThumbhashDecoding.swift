import Foundation

// The decode below follows Evan Wallace's public ThumbHash reference
// implementation (MIT licence, github.com/evanw/thumbhash, revision
// a652ce6ed691242f459f468f0a8756cda3b90a82). Vivid adds strict input checks
// and sizes the image from the luminance grid after each side is raised to 3.

extension ThumbhashImage {
    /// Straight (not premultiplied) RGBA, 4 bytes per pixel, rows top to bottom.
    struct DecodedPixels: Equatable {
        let width: Int
        let height: Int
        let rgba: [UInt8]
    }

    /// Nil unless the text is a complete, well-formed hash.
    nonisolated static func decodePixels(_ hash: String) -> DecodedPixels? {
        let text = hash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let data = Data(base64Encoded: text) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return nil }

        let hasAlpha = bytes[2] & 0x80 != 0
        let encodedCount = Int(bytes[3] & 7)
        let isLandscape = bytes[4] & 0x80 != 0
        guard encodedCount != 0 else { return nil }
        guard !hasAlpha || bytes.count >= 6 else { return nil }

        let fixedSide = hasAlpha ? 5 : 7
        let lx = max(3, isLandscape ? fixedSide : encodedCount)
        let ly = max(3, isLandscape ? encodedCount : fixedSide)

        let start = hasAlpha ? 6 : 5
        let coefficientCount = storedCoefficients(lx, ly)
            + 2 * storedCoefficients(3, 3)
            + (hasAlpha ? storedCoefficients(5, 5) : 0)
        guard bytes.count == start + (coefficientCount + 1) / 2 else { return nil }

        let header24 = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16
        let header16 = UInt32(bytes[3]) | UInt32(bytes[4]) << 8
        let lDC = Float(header24 & 63) / 63
        let pDC = Float((header24 >> 6) & 63) / 31.5 - 1
        let qDC = Float((header24 >> 12) & 63) / 31.5 - 1
        let lScale = Float((header24 >> 18) & 31) / 31
        let pScale = Float((header16 >> 3) & 63) / 63
        let qScale = Float((header16 >> 9) & 63) / 63
        let aDC: Float = hasAlpha ? Float(bytes[5] & 15) / 15 : 1
        let aScale: Float = hasAlpha ? Float(bytes[5] >> 4) / 15 : 0

        var nibbleIndex = 0
        func channel(_ nx: Int, _ ny: Int, scale: Float) -> [Float] {
            var values: [Float] = []
            for cy in 0..<ny {
                var cx = cy == 0 ? 1 : 0
                while cx * ny < nx * (ny - cy) {
                    let byte = bytes[start + (nibbleIndex >> 1)]
                    let nibble = (byte >> UInt8((nibbleIndex & 1) << 2)) & 15
                    values.append((Float(nibble) / 7.5 - 1) * scale)
                    nibbleIndex += 1
                    cx += 1
                }
            }
            return values
        }
        let lAC = channel(lx, ly, scale: lScale)
        // Chroma is boosted to make up for quantisation, as in the reference.
        let pAC = channel(3, 3, scale: pScale * 1.25)
        let qAC = channel(3, 3, scale: qScale * 1.25)
        let aAC = hasAlpha ? channel(5, 5, scale: aScale) : []

        let ratio = Float(lx) / Float(ly)
        let width = Int((ratio > 1 ? 32 : 32 * ratio).rounded())
        let height = Int((ratio > 1 ? 32 / ratio : 32).rounded())
        guard width > 0, height > 0 else { return nil }

        let columns = max(lx, hasAlpha ? 5 : 3)
        let rows = max(ly, hasAlpha ? 5 : 3)
        var fx = [Float](repeating: 0, count: columns)
        var fy = [Float](repeating: 0, count: rows)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        for y in 0..<height {
            for cy in 0..<rows {
                fy[cy] = cos(Float.pi / Float(height) * (Float(y) + 0.5) * Float(cy))
            }
            for x in 0..<width {
                for cx in 0..<columns {
                    fx[cx] = cos(Float.pi / Float(width) * (Float(x) + 0.5) * Float(cx))
                }
                var l = lDC, p = pDC, q = qDC, a = aDC

                var j = 0
                for cy in 0..<ly {
                    let fy2 = fy[cy] * 2
                    var cx = cy == 0 ? 1 : 0
                    while cx * ly < lx * (ly - cy) {
                        l += lAC[j] * fx[cx] * fy2
                        j += 1
                        cx += 1
                    }
                }

                j = 0
                for cy in 0..<3 {
                    let fy2 = fy[cy] * 2
                    var cx = cy == 0 ? 1 : 0
                    while cx < 3 - cy {
                        let f = fx[cx] * fy2
                        p += pAC[j] * f
                        q += qAC[j] * f
                        j += 1
                        cx += 1
                    }
                }

                if hasAlpha {
                    j = 0
                    for cy in 0..<5 {
                        let fy2 = fy[cy] * 2
                        var cx = cy == 0 ? 1 : 0
                        while cx < 5 - cy {
                            a += aAC[j] * fx[cx] * fy2
                            j += 1
                            cx += 1
                        }
                    }
                }

                let b = l - 2 / 3 * p
                let r = (3 * l - b + q) / 2
                let g = r - q
                rgba[offset] = channelByte(r)
                rgba[offset + 1] = channelByte(g)
                rgba[offset + 2] = channelByte(b)
                rgba[offset + 3] = channelByte(a)
                offset += 4
            }
        }
        return DecodedPixels(width: width, height: height, rgba: rgba)
    }

    /// The coefficients the reference stores for an nx by ny grid: a
    /// triangle that leaves out the constant term.
    private nonisolated static func storedCoefficients(_ nx: Int, _ ny: Int) -> Int {
        var count = 0
        for cy in 0..<ny {
            var cx = cy == 0 ? 1 : 0
            while cx * ny < nx * (ny - cy) {
                count += 1
                cx += 1
            }
        }
        return count
    }

    private nonisolated static func channelByte(_ value: Float) -> UInt8 {
        UInt8(min(1, max(0, value)) * 255)
    }
}
