import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Quality-targeted image optimisation: every encoder runs as a candidate, each searches its own
/// quality knob for the smallest file that still reaches the SSIM target, the smallest passing
/// candidate wins.
enum ImageEngine {
    /// Everything one job's candidates share.
    final class Context: @unchecked Sendable {
        let input: URL, work: URL, opts: Options, job: Job?
        let image: CGImage, reference: SSIM.Reference
        let transformed: Bool, hasAlpha: Bool, orientation: Int
        let target: Double, deadline: Date
        private let lock = NSLock()
        private var pngFile: URL?
        private var srgbFile: URL?
        private var iccFile: URL?
        private var counter = 0

        init(input: URL, work: URL, opts: Options, job: Job?, image: CGImage, transformed: Bool, hasAlpha: Bool, orientation: Int) {
            self.input = input; self.work = work; self.opts = opts; self.job = job
            self.image = image; self.transformed = transformed; self.hasAlpha = hasAlpha; self.orientation = orientation
            reference = SSIM.reference(image)
            target = opts.target(transformed: transformed)
            deadline = Engine.budget(pixels: image.width * image.height)
        }

        func tmp(_ ext: String) -> URL {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            return work.appendingPathComponent("c\(counter).\(ext)")
        }
        /// The (resized, redacted) pixels as a PNG, for encoders that read PNG.
        func pixelFile() throws -> URL {
            lock.lock(); defer { lock.unlock() }
            if let pngFile { return pngFile }
            let u = work.appendingPathComponent("pixels.png")
            try Pixels.writePNG(image, to: u)
            pngFile = u; return u
        }
        /// Same pixels converted to sRGB: pngquant drops colour profiles.
        func srgbPixelFile() throws -> URL {
            if Pixels.isSRGB(image) { return try pixelFile() }
            lock.lock(); defer { lock.unlock() }
            if let srgbFile { return srgbFile }
            let u = work.appendingPathComponent("srgb.png")
            try Pixels.writePNG(Pixels.toSRGB(image), to: u)
            srgbFile = u; return u
        }
        func profileFile() -> URL? {
            guard let data = Pixels.icc(image) else { return nil }
            lock.lock(); defer { lock.unlock() }
            if let iccFile { return iccFile }
            let u = work.appendingPathComponent("profile.icc")
            guard (try? data.write(to: u)) != nil else { return nil }
            iccFile = u; return u
        }
        func measure(_ url: URL) -> SSIM.Score? {
            Pixels.decode(url).map { SSIM.score(reference, $0) }
        }
        var timeLeft: Bool { Date() < deadline }
    }

    /// Smallest passing encode over the quality range `lo...hi` (higher is better quality). It starts at a
    /// typical value, walks up or down in growing strides until it has one failing and one passing
    /// encode, then interpolates the SSIM curve between them. At most `limit` encodes (6 by default),
    /// fewer when the time budget runs out. Returns a failing top-quality encode when nothing passes.
    static func search(_ c: Context, ext: String, format: ImageFormat?, lo: Int, hi: Int, start: Int, encode: (Int, URL) throws -> Void) -> Candidate? {
        searchCore(target: c.target, deadline: c.deadline, job: c.job, tmp: c.tmp, ext: ext, format: format, lo: lo, hi: hi, start: start, encode: encode, measure: c.measure)
    }

    /// `PINCH_DEBUG=1` prints every encode the search tries.
    static let debug = ProcessInfo.processInfo.environment["PINCH_DEBUG"] != nil

    static func searchCore(target: Double, deadline: Date, job: Job?, tmp: (String) -> URL, ext: String, format: ImageFormat?, lo: Int, hi: Int, start: Int, steps limit: Int = 6,
                           encode: (Int, URL) throws -> Void, measure: (URL) -> SSIM.Score?) -> Candidate? {
        var best: Candidate?        // smallest passing encode
        var top: Candidate?         // highest-quality failing encode, the fallback
        var steps = 0
        var pass: (q: Int, s: Double)?, fail: (q: Int, s: Double)?
        func drop(_ x: Candidate?) { if let x { try? FileManager.default.removeItem(at: x.url) } }
        /// Encodes at `q` and files the result; false when the encoder failed.
        func evaluate(_ q: Int) -> Bool {
            steps += 1
            let url = tmp(ext)
            do { try encode(q, url) } catch { try? FileManager.default.removeItem(at: url); return false }
            let bytes = fileSize(url)
            guard bytes > 0, let s = measure(url) else { try? FileManager.default.removeItem(at: url); return false }
            if debug { fputs("[search] \(ext) q\(q): \(bytes) bytes, ssim \(String(format: "%.4f", s.mean)), floor \(String(format: "%.3f", s.floor)), target \(target)\n", stderr) }
            let cand = Candidate(url: url, bytes: bytes, ssim: s.mean, passed: s.passes(target), format: format, knob: q)
            if cand.passed {
                if pass == nil || q < pass!.q { pass = (q, s.mean) }
                if best == nil || cand.bytes < best!.bytes { drop(best); best = cand } else { drop(cand) }
            } else {
                // Score used for interpolation: the gate also looks at the worst windows.
                if fail == nil || q > fail!.q { fail = (q, min(s.mean, s.floor > SSIM.floorMinimum ? s.mean : target - 0.001)) }
                if top == nil || q > top!.knob { drop(top); top = cand } else { drop(cand) }
            }
            return true
        }
        func live() -> Bool { steps < limit && Date() < deadline && job?.cancelled != true }

        var q = min(max(start, lo), hi)
        var stride = max(3, (hi - lo) / 8)
        guard evaluate(q) else { return nil }
        // Bracket: find a failing and a passing quality.
        while live(), pass == nil || fail == nil {
            if pass == nil {
                guard q < hi else { break }
                let hopeless = (fail?.s ?? 1) < target - 0.03
                q = hopeless ? hi : min(hi, fail!.q + stride)
            } else {
                guard q > lo else { break }
                q = max(lo, pass!.q - stride)
            }
            stride *= 2
            guard evaluate(q) else { break }
        }
        // Squeeze the bracket by interpolating the SSIM curve.
        while live(), let f = fail, let p = pass, p.q - f.q > 1 {
            let t = p.s > f.s ? (target - f.s) / (p.s - f.s) : 0.5
            let next = min(p.q - 1, max(f.q + 1, f.q + Int((t * Double(p.q - f.q)).rounded())))
            guard evaluate(next) else { break }
        }
        if best != nil { drop(top); return best }
        return top
    }

    // MARK: still images

    static func run(_ kind: Kind, input: URL, work: URL, opts: Options, job: Job?, out: inout Output) throws -> Candidate {
        if kind == .gif { return try gif(input: input, work: work, opts: opts, job: job, out: &out) }
        guard Pixels.frameCount(input) <= 1 else { throw Failure.alreadyOptimised }   // animated WebP/APNG: leave alone
        guard var image = Pixels.decode(input) else { throw Failure.other("Could not read this file") }
        var transformed = false
        if opts.shouldBlur, let (redacted, n) = Redactor.redact(image, opts.blurCats), n > 0 { image = redacted; out.hidden = n; transformed = true }
        let preset = opts.effective
        let longSide = max(image.width, image.height)
        var factor = 1.0
        if let d = opts.downscale { factor = d } else if let m = preset.maxSide, longSide > m { factor = Double(m) / Double(longSide) }
        if factor < 1 {
            image = Pixels.resized(image, width: max(1, Int((Double(image.width) * factor).rounded())), height: max(1, Int((Double(image.height) * factor).rounded())))
            transformed = true
        }
        out.newSize = CGSize(width: image.width, height: image.height)
        let c = Context(input: input, work: work, opts: opts, job: job, image: image, transformed: transformed,
                        hasAlpha: Pixels.hasAlpha(image), orientation: Pixels.orientation(input))
        let own = kind.format!
        var convertTo = opts.convert ?? (opts.allowConvert ? preset.conversion(webFallback: opts.webFallback) : nil)
        if convertTo == own || (convertTo == .jpeg && c.hasAlpha) { convertTo = nil }
        let formats = [own] + (convertTo.map { [$0] } ?? [])

        let tools = job?.tools ?? .shared
        var jobs: [() -> Candidate?] = []
        var missing: [ImageFormat: Tool] = [:]
        for f in formats {
            for (tool, produce) in producers(f, kind: kind, c) {
                if let tool, (try? tools.executable(tool)) == nil {
                    if missing[f] == nil { missing[f] = tool }
                } else { jobs.append(produce) }
            }
        }
        let results = Results()
        let work = JobList(items: jobs)
        DispatchQueue.concurrentPerform(iterations: work.items.count) { i in
            if let cand = work.items[i]() { results.add(cand) }
        }
        if job?.cancelled == true { throw Failure.cancelled }
        let all = results.all
        let old = out.oldBytes
        func smallest(_ list: [Candidate]) -> Candidate? { list.min { $0.bytes < $1.bytes } }
        let passing = all.filter(\.passed)
        let explicit = opts.convert != nil
        let convertedWin = convertTo.flatMap { t in smallest(passing.filter { $0.format == t && (explicit || Double($0.bytes) <= Double(old) * Engine.minimumGain) }) }
        let same = passing.filter { $0.format == own }
        let pick = convertedWin ?? smallest(same) ?? (transformed ? smallest(passing) ?? smallest(all) : nil)
        if explicit, convertedWin == nil, let convertTo, let tool = missing[convertTo] { throw Failure.missingTool(tool.rawValue) }
        guard var chosen = pick, transformed || convertedWin != nil || Double(chosen.bytes) <= Double(old) * Engine.minimumGain else {
            if let tool = formats.compactMap({ missing[$0] }).first { throw Failure.missingTool(tool.rawValue) }
            throw Failure.alreadyOptimised
        }
        if chosen.format == own { chosen.format = nil }
        for other in all where other.url != chosen.url { try? FileManager.default.removeItem(at: other.url) }
        return chosen
    }

    struct JobList: @unchecked Sendable { let items: [() -> Candidate?] }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [Candidate] = []
        func add(_ c: Candidate) { lock.lock(); list.append(c); lock.unlock() }
        var all: [Candidate] { lock.lock(); defer { lock.unlock() }; return list }
    }

    private static func lossless(_ c: Context, _ ext: String, _ format: ImageFormat, _ make: (URL) throws -> Void) -> Candidate? {
        let url = c.tmp(ext)
        do { try make(url) } catch { try? FileManager.default.removeItem(at: url); return nil }
        let bytes = fileSize(url)
        guard bytes > 0 else { return nil }
        return Candidate(url: url, bytes: bytes, ssim: 1, passed: true, format: format)
    }

    private typealias Producer = (Tool?, () -> Candidate?)

    private static func producers(_ f: ImageFormat, kind: Kind, _ c: Context) -> [Producer] {
        let lossy = c.opts.effective.lossy || c.transformed
        let job = c.job
        switch f {
        case .png:
            var list: [Producer] = [(.oxipng, {
                lossless(c, "png", .png) { out in
                    let base = (c.transformed || kind != .png) ? try c.pixelFile() : c.input
                    try runTool(.oxipng, ["-o", "3", "--strip", c.opts.strip ? "safe" : "none", "--out", out.path, base.path], job: job)
                }
            })]
            if lossy, c.opts.strip {
                list.insert((.pngquant, {
                    guard let src = try? c.srgbPixelFile() else { return nil }
                    guard var best = search(c, ext: "png", format: .png, lo: 35, hi: 100, start: 85, encode: { q, out in
                        try runTool(.pngquant, ["--quality", "0-\(q)", "--speed", "3", "--strip", "--force", "--output", out.path, src.path], job: job)
                    }), best.passed else { return nil }
                    let squeezed = c.tmp("png")
                    if (try? runTool(.oxipng, ["-o", "3", "--strip", "safe", "--out", squeezed.path, best.url.path], job: job)) != nil, fileSize(squeezed) > 0, fileSize(squeezed) < best.bytes {
                        try? FileManager.default.removeItem(at: best.url); best.url = squeezed; best.bytes = fileSize(squeezed)
                    }
                    return best
                }), at: 0)
            }
            return list
        case .jpeg:
            var list: [Producer] = []
            if kind == .jpeg, !c.transformed, c.orientation == 1 {
                list.append((.jpegtran, { lossless(c, "jpg", .jpeg) { out in
                    try runTool(.jpegtran, ["-optimize", "-progressive", "-copy", c.opts.strip ? "icc" : "all", "-outfile", out.path, c.input.path], job: job)
                } }))
            }
            if kind == .jpeg, lossy, !c.transformed, c.orientation == 1 {
                // Requantising the DCT coefficients of a JPEG avoids the second rounding a decode and
                // re-encode adds, so it often reaches the SSIM target at a smaller size.
                list.append((.jpegoptim, {
                    search(c, ext: "jpg", format: .jpeg, lo: 40, hi: 97, start: 85, encode: { q, out in
                        try FileManager.default.copyItem(at: c.input, to: out)
                        try runTool(.jpegoptim, ["-q", "-m\(q)", "--all-progressive"] + (c.opts.strip ? ["--strip-com", "--strip-exif", "--strip-iptc", "--strip-xmp"] : []) + [out.path], job: job)
                    })
                }))
            }
            if lossy, c.opts.strip || c.transformed || kind != .jpeg {
                // mozjpeg switches from 4:2:0 to 4:4:4 at quality 90, which makes size jump by half;
                // pinning the subsampling keeps the quality curve smooth. Both variants compete.
                for (sample, lo, start) in [("2x2", 40, 85), ("1x1", 60, 88)] {
                    list.append((.cjpeg, {
                        guard let src = try? c.pixelFile() else { return nil }
                        let profile = c.profileFile()
                        return search(c, ext: "jpg", format: .jpeg, lo: lo, hi: 97, start: start, encode: { q, out in
                            try runTool(.cjpeg, ["-quality", "\(q)", "-sample", sample] + (profile.map { ["-icc", $0.path] } ?? []) + ["-outfile", out.path, src.path], job: job)
                        })
                    }))
                }
            }
            return list
        case .webp:
            guard lossy || kind != .webp else { return [] }
            return [(.cwebp, {
                guard let src = try? c.pixelFile() else { return nil }
                let keep = c.profileFile() != nil
                return search(c, ext: "webp", format: .webp, lo: 40, hi: 97, start: 80, encode: { q, out in
                    try runTool(.cwebp, ["-quiet", "-q", "\(q)", "-m", "5", "-alpha_q", "100", "-metadata", keep ? "icc" : "none", src.path, "-o", out.path], job: job)
                })
            })]
        case .avif:
            guard lossy || kind != .avif else { return [] }
            return [(.avifenc, {
                guard let src = try? c.pixelFile() else { return nil }
                return search(c, ext: "avif", format: .avif, lo: 25, hi: 90, start: 55, encode: { q, out in
                    try runTool(.avifenc, ["-q", "\(q)", "--qalpha", "90", "-s", "7", "-j", "2", src.path, out.path], job: job)
                })
            })]
        case .heic:
            guard lossy else { return [] }
            return [(nil, {
                search(c, ext: "heic", format: .heic, lo: 30, hi: 95, start: 65, encode: { q, out in
                    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw Failure.other("HEIC unavailable") }
                    CGImageDestinationAddImage(d, c.image, [kCGImageDestinationLossyCompressionQuality: Double(q) / 100] as CFDictionary)
                    guard CGImageDestinationFinalize(d) else { throw Failure.other("HEIC unavailable") }
                })
            })]
        case .jxl:
            return [(.cjxl, {
                guard let src = try? c.pixelFile() else { return nil }
                return search(c, ext: "jxl", format: .jxl, lo: 40, hi: 96, start: 85, encode: { q, out in
                    try runTool(.cjxl, ["--quiet", "-q", "\(q)", "-e", "5", src.path, out.path], job: job)
                })
            })]
        case .gif: return []
        }
    }

    // MARK: GIF

    private static func gif(input: URL, work: URL, opts: Options, job: Job?, out: inout Output) throws -> Candidate {
        let preset = opts.effective
        guard let first = Pixels.decode(input) else { throw Failure.other("Could not read this file") }
        let count = Pixels.frameCount(input)
        var factor = 1.0
        if let d = opts.downscale { factor = d } else if let m = preset.maxSide, max(first.width, first.height) > m { factor = Double(m) / Double(max(first.width, first.height)) }
        let w = max(1, Int((Double(first.width) * factor).rounded())), h = max(1, Int((Double(first.height) * factor).rounded()))
        out.newSize = CGSize(width: w, height: h)
        let indexes = Array(Set([0, count / 2, count - 1])).sorted()
        let refs: [SSIM.Reference] = indexes.compactMap { i in Pixels.decode(input, index: i).map { SSIM.reference(factor < 1 ? Pixels.resized($0, width: w, height: h) : $0) } }
        let target = opts.target(transformed: factor < 1)
        let resize = factor < 1 ? ["--resize", "\(w)x\(h)"] : []
        let strip = opts.strip ? ["--no-comments", "--no-names", "--no-extensions"] : []
        var n = 0
        let lock = NSLock()
        func tmp() -> URL { lock.lock(); defer { lock.unlock() }; n += 1; return work.appendingPathComponent("g\(n).gif") }
        /// `quality` runs 10 to 150 like every other knob (higher is better), gifsicle's lossiness is the inverse.
        func encode(_ quality: Int, _ url: URL) throws {
            let lossy = quality >= 160 ? 0 : 160 - quality
            try runTool(.gifsicle, ["-O3"] + (lossy > 0 ? ["--lossy=\(lossy)"] : []) + strip + resize + ["-o", url.path, input.path], job: job)
        }
        func measure(_ url: URL) -> SSIM.Score? {
            var worst: SSIM.Score?
            for (k, i) in indexes.enumerated() where k < refs.count {
                guard let img = Pixels.decode(url, index: i) else { return nil }
                let s = SSIM.score(refs[k], img)
                if worst == nil || s.mean < worst!.mean { worst = s }
            }
            return worst
        }
        let plain = tmp()
        try encode(160, plain)
        var best = Candidate(url: plain, bytes: fileSize(plain), ssim: 1, passed: true, format: nil)
        if preset.lossy {
            let deadline = Engine.budget(pixels: first.width * first.height * max(1, count / 4))
            let lossy = searchCore(target: target, deadline: deadline, job: job, tmp: { _ in tmp() }, ext: "gif", format: nil, lo: 10, hi: 150, start: 95, encode: encode, measure: measure)
            if let lossy, lossy.passed, lossy.bytes < best.bytes { try? FileManager.default.removeItem(at: best.url); best = lossy }
            else if let lossy { try? FileManager.default.removeItem(at: lossy.url) }
        }
        if factor == 1, Double(best.bytes) > Double(out.oldBytes) * Engine.minimumGain { throw Failure.alreadyOptimised }
        return best
    }
}

extension Engine {
    /// GIF to MP4 next to the original (the GIF stays). Typically 5 to 20 times smaller.
    static func convertGIF(_ url: URL, into dir: URL, job: Job? = nil) throws -> Output {
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        try runTool(.ffmpeg, ["-y", "-v", "error", "-i", url.path, "-an", "-c:v", "libx264", "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                              "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", out.path], job: job)
        return Output(oldBytes: fileSize(url), newBytes: fileSize(out), oldSize: imageSize(url), newSize: imageSize(url), url: out)
    }
}
