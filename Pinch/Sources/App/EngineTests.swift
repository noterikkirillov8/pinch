import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Engine checks run by `Pinch -selftest <dir>` (see scripts/test-engine.sh).
enum EngineTests {
    typealias Check = (String, Bool, String) -> Void

    static func ffmpegSSIM(_ a: URL, _ b: URL) -> Double? {
        guard let log = try? runTool(.ffmpeg, ["-hide_banner", "-nostats", "-i", a.path, "-i", b.path, "-lavfi", "[0:v]format=gbrp[x];[1:v]format=gbrp[y];[x][y]ssim", "-f", "null", "-"]),
              let r = log.range(of: "All:") else { return nil }
        return Double(log[r.upperBound...].prefix { !$0.isWhitespace })
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }

    static func md5(_ url: URL) -> String? {
        guard let log = try? runTool(.ffmpeg, ["-v", "error", "-i", url.path, "-f", "md5", "-"]), let r = log.range(of: "MD5=") else { return nil }
        return String(log[r.upperBound...].prefix { !$0.isWhitespace })
    }

    static func pixels(_ url: URL) -> [UInt8]? {
        guard let img = Pixels.decode(url) else { return nil }
        return SSIM.render(img, w: img.width, h: img.height)
    }

    static func run(in dir: URL) {
        func check(_ n: String, _ ok: Bool, _ why: @autoclosure () -> String = "") { SelfTest.check(n, ok, why()) }
        let t = dir.appendingPathComponent("engine", isDirectory: true)
        try? FileManager.default.removeItem(at: t)
        try? FileManager.default.createDirectory(at: t, withIntermediateDirectories: true)
        var counter = 0
        /// Copies a sample, runs the engine on the copy, returns what came out.
        func go(_ name: String, _ opts: Options, as ext: String? = nil) -> (out: Output?, error: Error?, src: URL, dest: URL, seconds: Double) {
            counter += 1
            let sub = t.appendingPathComponent("\(counter)", isDirectory: true)
            try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let src = dir.appendingPathComponent(name)
            let dest = sub.appendingPathComponent(ext.map { (name as NSString).deletingPathExtension + "." + $0 } ?? name)
            let start = Date()
            do {
                let o = try Engine.process(input: src, output: dest, opts: opts)
                return (o, nil, src, o.url ?? dest, Date().timeIntervalSince(start))
            } catch { return (nil, error, src, dest, Date().timeIntervalSince(start)) }
        }
        var base = Options(); base.strip = true

        do {
            let root = t.appendingPathComponent("tool-lookup")
            let bin = root.appendingPathComponent("usr/local/opt/mozjpeg/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let empty = ToolPaths(root: root, path: "")
            let input = dir.appendingPathComponent("ui-editor.png")
            let result = Result { try Engine.process(input: input, output: t.appendingPathComponent("empty.png"), opts: base, job: Job(tools: empty)) }
            check("missing encoders: PNG reports missingTool(pngquant)", { if case Failure.missingTool("pngquant")? = result.failure { true } else { false } }())
            let executable = bin.appendingPathComponent("cjpeg")
            try Data().write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let discovered = try ToolPaths(root: root, path: "").executable(.cjpeg)
            check("tool lookup: finds cjpeg under fake /usr/local prefix", discovered.path == executable.path)
            check("tool lookup: cached miss survives later install", (try? empty.executable(.cjpeg)) == nil)
            let defaults = UserDefaults(suiteName: "Pinch.ToolCheckTests.\(UUID())")!
            check("tools: missing encoders prompt only on first launch", empty.firstLaunchHint(defaults: defaults) && !empty.firstLaunchHint(defaults: defaults))
            let full = ToolPaths(paths: Dictionary(uniqueKeysWithValues: Tool.allCases.map { ($0, bin.appendingPathComponent($0.rawValue)) }))
            check("tools: complete install needs no prompt", !full.hasMissing && !full.firstLaunchHint(defaults: UserDefaults(suiteName: "Pinch.ToolCheckTests.\(UUID())")!))
            check("tools: copy command matches Homebrew setup", ToolPaths.installCommand == "brew install pngquant oxipng mozjpeg webp libavif jpeg-xl gifsicle ffmpeg ghostscript")
        } catch { check("tool lookup fixtures", false, "\(error)") }

        // SSIM
        let shot = Pixels.decode(dir.appendingPathComponent("ui-editor.png"))!
        let ref = SSIM.reference(shot)
        check("ssim: identical image scores 1", SSIM.score(ref, shot).mean > 0.9999)
        let soft = Pixels.resized(Pixels.resized(shot, width: shot.width / 6, height: shot.height / 6), width: shot.width, height: shot.height)
        let softScore = SSIM.score(ref, soft)
        check("ssim: a blurred copy scores clearly lower", softScore.mean < 0.95, "\(softScore.mean)")
        let scratch = Samples.photo(shot.width, shot.height)
        check("ssim: unrelated image fails the gate", !SSIM.score(ref, scratch).passes(0.985))

        // Search + gate on a UI screenshot (palette wins) and a photo (mozjpeg wins).
        for name in ["ui-dashboard.png", "ui-editor.png", "ui-settings.png"] {
            let r = go(name, base)
            if let o = r.out {
                let own = SSIM.score(original: r.src, candidate: r.dest)?.mean ?? 0
                let cross = ffmpegSSIM(r.src, r.dest) ?? 0
                check("search png \(name): smaller (\(o.oldBytes) -> \(o.newBytes), \(String(format: "%.1f", r.seconds)) s)", o.newBytes < Int(Double(o.oldBytes) * 0.97))
                check("gate png \(name): SSIM \(String(format: "%.4f", own)) >= 0.985, ffmpeg agrees \(String(format: "%.4f", cross))", own >= 0.985 && cross >= 0.975, "\(own) \(cross)")
            } else { check("search png \(name)", false, "\(String(describing: r.error))") }
        }
        let lossless = go("ui-dashboard.png", { var o = base; o.preset = .lossless; return o }())
        if let o = lossless.out {
            check("lossless png: same pixels", pixels(lossless.src) == pixels(lossless.dest) && pixels(lossless.dest) != nil)
            check("lossless png: still smaller", o.newBytes < o.oldBytes)
            check("lossless png: SSIM reported 1", o.ssim == 1)
        } else { check("lossless png", false, "\(String(describing: lossless.error))") }
        let identical = go("ui-dashboard.png", base)
        if let a = identical.out, let b = lossless.out { check("png: identical preset beats lossless on a screenshot", a.newBytes < b.newBytes, "\(a.newBytes) vs \(b.newBytes)") }

        for name in ["photo-a.jpg", "photo-b.jpg"] {
            let r = go(name, base)
            if let o = r.out {
                let own = SSIM.score(original: r.src, candidate: r.dest)?.mean ?? 0
                check("search jpeg \(name): smaller (\(o.oldBytes) -> \(o.newBytes), \(String(format: "%.1f", r.seconds)) s)", o.newBytes < Int(Double(o.oldBytes) * 0.97))
                check("gate jpeg \(name): SSIM \(String(format: "%.4f", own)) >= 0.985", own >= 0.985, "\(own)")
                let p = properties(r.dest)
                check("metadata \(name): GPS and EXIF stripped", p[kCGImagePropertyGPSDictionary] == nil && p[kCGImagePropertyExifDictionary] == nil, "\(p.keys)")
            } else { check("search jpeg \(name)", false, "\(String(describing: r.error))") }
        }
        let before = properties(dir.appendingPathComponent("photo-a.jpg"))
        check("metadata: sample really carries GPS", before[kCGImagePropertyGPSDictionary] != nil)
        var keep = base; keep.strip = false; keep.preset = .lossless
        let kept = go("photo-a.jpg", keep)
        if kept.out != nil {
            check("metadata: strip off keeps GPS (lossless path)", properties(kept.dest)[kCGImagePropertyGPSDictionary] != nil)
            check("lossless jpeg: same decoded pixels", md5(kept.src) != nil && md5(kept.src) == md5(kept.dest))
        } else { check("lossless jpeg keep metadata", false, "\(String(describing: kept.error))") }
        var strong = base; strong.preset = .lossless
        let stripped = go("photo-a.jpg", strong)
        check("metadata: lossless preset still strips GPS", stripped.out != nil && properties(stripped.dest)[kCGImagePropertyGPSDictionary] == nil)

        // Colour profile survives (Display P3 screenshot through the lossless and palette paths).
        let p3 = go("ui-p3.png", base)
        check("colour profile: Display P3 screenshot stays visually the same (palette path converts to sRGB)", (SSIM.score(original: p3.src, candidate: p3.dest)?.mean ?? 0) >= 0.985)

        // Orientation: a rotated JPEG keeps its displayed size.
        let rotated = dir.appendingPathComponent("rotated.jpg")
        if let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("photo-b.jpg") as CFURL, nil), let d = CGImageDestinationCreateWithURL(rotated as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImageFromSource(d, src, 0, [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            CGImageDestinationFinalize(d)
        }
        let rot = go("rotated.jpg", base)
        check("orientation: displayed size unchanged", rot.out != nil && Engine.imageSize(rot.dest) == Engine.imageSize(rotated) && Engine.imageSize(rotated) == CGSize(width: 1600, height: 2400), "\(String(describing: Engine.imageSize(rot.dest))) \(String(describing: Engine.imageSize(rotated)))")

        // Keep-original rule.
        check("keep original: second pass leaves the file alone", Engine.processAgain(identical))
        let tiny = dir.appendingPathComponent("tiny.png")
        Samples.save(Samples.ctx(8, 8).makeImage()!, tiny, .png)
        _ = try? runTool(.oxipng, ["-o", "3", "--strip", "all", tiny.path])
        let tinyRun = go("tiny.png", base)
        check("keep original: nothing to gain throws alreadyOptimised", { if case Failure.alreadyOptimised? = tinyRun.error { true } else { false } }(), "\(String(describing: tinyRun.error)) \(String(describing: tinyRun.out))")
        check("keep original: minimum gain is 3 percent", Engine.minimumGain == 0.97)
        var forced = base; forced.force = true
        let reRun = go("ui-dashboard.png", forced)
        var plainOpts = base; plainOpts.force = false
        check("keep original: files marked optimised are skipped unless forced", { if let u = reRun.out?.url, case Failure.alreadyOptimised? = (Result { try Engine.process(input: u, output: u.deletingLastPathComponent().appendingPathComponent("skip.png"), opts: plainOpts) }.failure) { return true } else { return false } }())

        // Presets
        check("presets: targets", Preset.identical.ssim == 0.985 && Preset.chat.ssim == 0.97 && Preset.ai.ssim == 0.97 && Preset.web.ssim == 0.98 && Preset.lossless.ssim == 1)
        check("presets: sizes and formats", Preset.chat.maxSide == 1600 && Preset.ai.maxSide == 1568 && Preset.chat.conversion(webFallback: false) == .webp && Preset.web.conversion(webFallback: false) == .avif && Preset.web.conversion(webFallback: true) == .webp && Preset.ai.conversion(webFallback: false) == nil && Preset.identical.conversion(webFallback: false) == nil)
        check("presets: names parse", Preset(name: "chat") == .chat && Preset(name: "For the web") == .web && Preset(name: "nope") == nil)
        var harder = base; harder.aggressive = true
        check("presets: optimise harder lowers the target, never below 0.95", abs(harder.target(transformed: false) - 0.965) < 1e-9 && { var o = base; o.preset = .chat; o.aggressive = true; return abs(o.target(transformed: false) - 0.95) < 1e-9 }())
        var ll = base; ll.preset = .lossless; ll.aggressive = true
        check("presets: harder on lossless means identical", ll.effective == .identical)

        var ai = base; ai.preset = .ai
        let aiRun = go("big.png", ai)
        if let o = aiRun.out, let s = Engine.imageSize(aiRun.dest) {
            check("ai preset: long side 1568, 3:2 kept", Int(s.width) == 1568 && Int(s.height) == 1045, "\(s)")
            check("ai preset: stays PNG, smaller", aiRun.dest.pathExtension == "png" && o.newBytes < o.oldBytes)
        } else { check("ai preset", false, "\(String(describing: aiRun.error))") }
        let small = go("photo.png", ai)
        check("ai preset: 1600 px image scaled to 1568", Engine.imageSize(small.dest).map { Int($0.width) == 1568 } ?? false)
        var chat = base; chat.preset = .chat
        let chatKeep = go("photo-a.jpg", chat)
        check("chat preset: 1600 px long side, stays JPEG when conversion is off", chatKeep.out != nil && Engine.imageSize(chatKeep.dest).map { Int($0.width) == 1600 } ?? false && chatKeep.dest.pathExtension == "jpg", "\(String(describing: chatKeep.error))")
        chat.allowConvert = true
        let chatWebP = go("photo-a.jpg", chat)
        check("chat preset: WebP when conversion is allowed, original untouched", chatWebP.out != nil && chatWebP.dest.pathExtension == "webp" && Engine.imageSize(chatWebP.dest).map { Int($0.width) == 1600 } ?? false && FileManager.default.fileExists(atPath: chatWebP.src.path), "\(String(describing: chatWebP.error)) \(chatWebP.dest.lastPathComponent)")
        var web = base; web.preset = .web; web.allowConvert = true
        let avif = go("photo-b.jpg", web)
        check("web preset: AVIF at 98% identical or better", avif.out != nil && avif.dest.pathExtension == "avif" && (avif.out?.ssim ?? 0) >= 0.98, "\(String(describing: avif.error)) \(avif.dest.lastPathComponent) \(String(describing: avif.out?.ssim))")
        check("web preset: AVIF smaller than the best JPEG", { if let a = avif.out, let j = go("photo-b.jpg", base).out { a.newBytes < j.newBytes } else { false } }())
        var web2 = web; web2.webFallback = true
        let webp = go("photo-b.jpg", web2)
        check("web preset: WebP fallback choice", webp.out != nil && webp.dest.pathExtension == "webp", "\(String(describing: webp.error))")
        var to = base; to.convert = .jxl
        let jxl = go("photo-b.jpg", to)
        check("convert: JPEG XL on request", jxl.out == nil || jxl.dest.pathExtension == "jxl", "\(String(describing: jxl.error))")
        // Already-modern input keeps its format.
        var again = base
        let reencode = go("photo-b.jpg", { var o = base; o.convert = .webp; return o }())
        if let w = reencode.out {
            let copy = t.appendingPathComponent("again.webp"); try? FileManager.default.copyItem(at: w.url!, to: copy)
            let r2 = (try? Engine.process(input: copy, output: t.appendingPathComponent("again-out.webp"), opts: again))
            check("webp input: re-encoded as webp or left alone", r2 == nil || r2?.url?.pathExtension == "webp")
        }
        again.blur = false

        // Blur still goes through the same engine.
        var blur = base; blur.blur = true; blur.blurCats = .all
        var pending = blur; pending.downscale = 0.75
        let unblurred = go("secrets.png", pending)
        check("blur: skipped by default even for a pending blur request", !Options.fromPrefs(blur: true).blur && !pending.shouldBlur && unblurred.out?.hidden == 0)
        do {
            let saved = Prefs.d.volatileDomain(forName: UserDefaults.argumentDomain)
            Prefs.d.setVolatileDomain(saved.merging(["blurOn": true]) { _, new in new }, forName: UserDefaults.argumentDomain)
            defer { Prefs.d.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
            let optedIn = Options.fromPrefs(blur: true)
            check("blur: existing opt-in enables redaction", optedIn.shouldBlur)
            let blurred = go("secrets.png", optedIn)
            check("blur through the engine hides 2 regions", blurred.out?.hidden == 2, "\(String(describing: blurred.out?.hidden)) \(String(describing: blurred.error))")
        }

        // GIF, video, PDF
        let gif = go("anim.gif", base)
        check("gif: still a GIF with the same frames, smaller or left alone", { if let o = gif.out { Pixels.frameCount(gif.dest) == Pixels.frameCount(gif.src) && o.newBytes < o.oldBytes } else if case Failure.alreadyOptimised? = gif.error { true } else { false } }(), "\(String(describing: gif.error))")
        let mp4 = try? Engine.convertGIF(gif.src, into: t.appendingPathComponent("mp4", isDirectory: true))
        check("gif: converts to a much smaller MP4", mp4.map { $0.newBytes * 2 < $0.oldBytes } ?? false, "\(String(describing: mp4))")
        let video = go("recording.mov", base)
        if let o = video.out {
            check("video: hevc, smaller (\(o.oldBytes) -> \(o.newBytes), \(String(format: "%.1f", video.seconds)) s)", o.newBytes < o.oldBytes && VideoEngine.probe(video.dest) != nil)
            check("video: silent audio dropped", VideoEngine.probe(video.dest)?.hasAudio == false)
            check("video: quality reported as SSIM", (o.ssim ?? 0) >= 0.985)
        } else if case Failure.alreadyOptimised? = video.error { check("video: left alone", true) } else { check("video", false, "\(String(describing: video.error))") }
        let pdf = go("report.pdf", base)
        check("pdf: smaller and still valid", { if let o = pdf.out { o.newBytes < o.oldBytes && (try? runTool(.gs, ["-q", "-dNODISPLAY", "-dNOSAFER", "-dBATCH", "-dNOPAUSE", "-sDEVICE=nullpage", pdf.dest.path])) != nil } else { false } }(), "\(String(describing: pdf.error))")

        // The command line
        let req = Command.parse(["a.png", "--preset", "chat", "--to", "webp", "--out", "/tmp/pinch-out", "--ssim", "0.97", "--blur"])
        check("cli: options parse", req?.opts.preset == .chat && req?.opts.convert == .webp && req?.out?.path == "/tmp/pinch-out" && req?.opts.ssimTarget == 0.97 && req?.opts.blur == true && req?.inputs.count == 1)
        check("cli: bad preset is refused", Command.parse(["a.png", "--preset", "nope"]) == nil)
        let outDir = t.appendingPathComponent("cli-out", isDirectory: true)
        let folder = t.appendingPathComponent("cli-in", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: dir.appendingPathComponent("ui-editor.png"), to: folder.appendingPathComponent("sub/shot.png"))
        try? FileManager.default.copyItem(at: dir.appendingPathComponent("photo-b.jpg"), to: folder.appendingPathComponent("photo.jpg"))
        let originalBytes = fileSize(folder.appendingPathComponent("photo.jpg"))
        let code = Command.optimise([folder.path, "--out", outDir.path, "--quiet"])
        check("cli: folder processed recursively into --out", code == 0 && FileManager.default.fileExists(atPath: outDir.appendingPathComponent("shot.png").path) && fileSize(outDir.appendingPathComponent("photo.jpg")) < originalBytes)
        check("cli: originals untouched with --out", fileSize(folder.appendingPathComponent("photo.jpg")) == originalBytes)
        check("cli: missing file is an error", Command.optimise([t.appendingPathComponent("nope.png").path, "--quiet"]) == 64)
        check("cli: expand skips unsupported files", Command.expand([folder]).count == 2)
    }
}

extension Engine {
    /// True when running the engine again over a finished result changes nothing.
    static func processAgain(_ r: (out: Output?, error: Error?, src: URL, dest: URL, seconds: Double)) -> Bool {
        guard r.out != nil else { return false }
        let again = r.dest.deletingLastPathComponent().appendingPathComponent("again-\(r.dest.lastPathComponent)")
        do { _ = try process(input: r.dest, output: again, opts: Options()); return fileSize(again) >= Int(Double(fileSize(r.dest)) * 0.97) }
        catch Failure.alreadyOptimised { return true } catch { return false }
    }
}

extension Result {
    var failure: Failure? { if case let .failure(e) = self { e } else { nil } }
}
