import CoreGraphics
import Foundation
import ImageIO

/// Structural similarity between two renderings of the same picture, on the three colour channels
/// at no more than `workSide` pixels on the long side. 8x8 windows every 4 px.
enum SSIM {
    static let workSide = 4096
    /// Worst windows may not fall below this, so a few ruined lines of text cannot hide in a
    /// large flat background.
    static let floorMinimum = 0.7

    struct Score: Sendable {
        var mean: Double
        var floor: Double
        func passes(_ target: Double) -> Bool { mean >= target && floor >= floorMinimum }
    }

    /// The original rendered once at working size; candidates are drawn at the same size.
    struct Reference: @unchecked Sendable {
        let w: Int, h: Int
        let pixels: [UInt8]
    }

    static func size(for image: CGImage) -> (Int, Int) {
        let f = min(1, Double(workSide) / Double(max(image.width, image.height)))
        return (max(8, Int((Double(image.width) * f).rounded())), max(8, Int((Double(image.height) * f).rounded())))
    }

    static func render(_ image: CGImage, w: Int, h: Int) -> [UInt8] {
        var data = [UInt8](repeating: 255, count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            c.interpolationQuality = .high
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    static func reference(_ image: CGImage) -> Reference {
        let (w, h) = size(for: image)
        return Reference(w: w, h: h, pixels: render(image, w: w, h: h))
    }

    static func score(_ ref: Reference, _ candidate: CGImage) -> Score {
        score(ref.pixels, render(candidate, w: ref.w, h: ref.h), w: ref.w, h: ref.h)
    }

    @_optimize(speed)
    static func score(_ a: [UInt8], _ b: [UInt8], w: Int, h: Int) -> Score {
        let c1 = 6.5025, c2 = 58.5225, n = 64.0
        var scores: [Double] = []
        scores.reserveCapacity((w / 4) * (h / 4))
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                var y = 0
                while y + 8 <= h {
                    var x = 0
                    while x + 8 <= w {
                        var total = 0.0
                        for ch in 0 ..< 3 {
                            var sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0
                            for j in 0 ..< 8 {
                                var o = ((y + j) * w + x) * 4 + ch
                                for _ in 0 ..< 8 {
                                    let p = Int(pa[o]), q = Int(pb[o])
                                    sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                                    o += 4
                                }
                            }
                            let ma = Double(sa) / n, mb = Double(sb) / n
                            let va = Double(saa) / n - ma * ma, vb = Double(sbb) / n - mb * mb, cov = Double(sab) / n - ma * mb
                            total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                        }
                        scores.append(total / 3)
                        x += 4
                    }
                    y += 4
                }
            }
        }
        guard !scores.isEmpty else { return Score(mean: a == b ? 1 : 0, floor: a == b ? 1 : 0) }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let worst = scores.sorted().prefix(max(1, scores.count / 50))
        return Score(mean: min(1, mean), floor: min(1, worst.reduce(0, +) / Double(worst.count)))
    }

    /// Score of two files, the second drawn at the first's working size. Nil when either cannot be read.
    static func score(original: URL, candidate: URL) -> Score? {
        guard let a = Pixels.decode(original), let b = Pixels.decode(candidate) else { return nil }
        return score(reference(a), b)
    }
}
