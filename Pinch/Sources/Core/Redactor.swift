import CoreGraphics
import Foundation
import Vision

struct BlurCategories: OptionSet, Sendable {
    let rawValue: Int
    static let email = BlurCategories(rawValue: 1)
    static let keys = BlurCategories(rawValue: 2)
    static let phone = BlurCategories(rawValue: 4)
    static let card = BlurCategories(rawValue: 8)
    static let all: BlurCategories = [.email, .keys, .phone, .card]
}

/// Finds private text (emails, keys, phones, card numbers) with Vision OCR and pixelates it.
enum Redactor {
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let keyPatterns = [
        rx(#"sk-ant-[A-Za-z0-9_\-]{8,}"#), rx(#"sk-[A-Za-z0-9_\-]{16,}"#),
        rx(#"gh[pousr]_[A-Za-z0-9]{20,}"#), rx(#"github_pat_[A-Za-z0-9_]{20,}"#),
        rx(#"AKIA[0-9A-Z]{16}"#), rx(#"xox[bp]-[A-Za-z0-9\-]{10,}"#),
        rx(#"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#),
        rx(#"\b[0-9a-fA-F]{32,}\b"#),
    ]
    private static let base64 = rx(#"[A-Za-z0-9+/_\-]{32,}={0,2}"#)
    private static let email = rx(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)
    private static let digits = rx(#"\+?\d[\d \-().]{6,}\d"#)
    private static let dateLike = rx(#"\d{4}-\d{2}-\d{2}|\d{1,2}[:.]\d{2}[:.]\d{2}"#)

    /// Ranges of private text in one line, most specific category first, no overlaps.
    static func find(in s: String, _ cats: BlurCategories) -> [Range<String.Index>] {
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [NSRange] = []
        func add(_ r: NSRange) { if !found.contains(where: { NSIntersectionRange($0, r).length > 0 }) { found.append(r) } }
        if cats.contains(.keys) {
            for p in keyPatterns { for m in p.matches(in: s, range: full) { add(m.range) } }
            for m in base64.matches(in: s, range: full) {
                let t = ns.substring(with: m.range)
                if t.contains(where: \.isNumber), t.contains(where: \.isLetter) { add(m.range) }
            }
        }
        if cats.contains(.email) { for m in email.matches(in: s, range: full) { add(m.range) } }
        if cats.contains(.card) || cats.contains(.phone) {
            for m in digits.matches(in: s, range: full) {
                let t = ns.substring(with: m.range)
                let n = t.filter(\.isNumber).count
                let plus = t.contains("+")
                if dateLike.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil { continue }
                if (13 ... 19).contains(n), !plus, !t.contains("(") {
                    if cats.contains(.card) { add(m.range) }
                } else if cats.contains(.phone), plus ? (8 ... 15).contains(n) : (10 ... 15).contains(n) {
                    add(m.range)
                }
            }
        }
        return found.compactMap { Range($0, in: s) }
    }

    struct Line: @unchecked Sendable {
        let text: String
        let obs: VNRecognizedText
        let box: CGRect   // normalised, bottom-left origin
    }

    static func recognise(_ image: CGImage) -> [Line] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        let lines = (req.results ?? []).compactMap { o -> Line? in
            guard let c = o.topCandidates(1).first else { return nil }
            return Line(text: c.string, obs: c, box: o.boundingBox)
        }
        return lines.sorted { abs($0.box.midY - $1.box.midY) > 0.01 ? $0.box.midY > $1.box.midY : $0.box.minX < $1.box.minX }
    }

    /// Pixelated copy of `image` and the number of regions hidden, or nil when nothing matched.
    static func redact(_ image: CGImage, _ cats: BlurCategories) -> (CGImage, Int)? {
        guard !cats.isEmpty else { return nil }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        var rects: [CGRect] = []
        for line in recognise(image) {
            for r in find(in: line.text, cats) {
                guard let box = try? line.obs.boundingBox(for: r) else { continue }
                let b = box.boundingBox
                rects.append(CGRect(x: b.minX * W, y: b.minY * H, width: b.width * W, height: b.height * H)
                    .insetBy(dx: -4, dy: -4).intersection(CGRect(x: 0, y: 0, width: W, height: H)))
            }
        }
        guard !rects.isEmpty else { return nil }
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = bitmap(image.width, image.height, space) ?? bitmap(image.width, image.height, CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        for rect in rects {
            let crop = CGRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height).integral
            guard let piece = image.cropping(to: crop) else { continue }
            let block = max(6, rect.height / 2)
            let sw = max(1, Int((rect.width / block).rounded(.up))), sh = max(1, Int((rect.height / block).rounded(.up)))
            guard let small = bitmap(sw, sh, space) else { continue }
            small.interpolationQuality = .high
            small.draw(piece, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let tiny = small.makeImage() else { continue }
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.interpolationQuality = .none
            ctx.draw(tiny, in: rect)
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage() else { return nil }
        return (out, rects.count)
    }

    private static func bitmap(_ w: Int, _ h: Int, _ space: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Plain text lines of an image. With `hide`, private matches become •••.
    static func text(of image: CGImage, hide: BlurCategories) -> [String] {
        recognise(image).map { line in
            guard !hide.isEmpty else { return line.text }
            var s = line.text
            for r in find(in: s, hide).sorted(by: { $0.lowerBound > $1.lowerBound }) { s.replaceSubrange(r, with: "•••") }
            return s
        }
    }
}
