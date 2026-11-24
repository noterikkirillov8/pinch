import CoreGraphics
import Foundation

/// Video: hardware HEVC (or H.264 for compatibility) with the quality knob searched against the
/// SSIM of three sampled frames. Long clips are searched on an eight second excerpt.
enum VideoEngine {
    struct Info {
        var duration = 0.0, fps = 30.0, size = CGSize.zero, hasAudio = false
    }

    static func probe(_ url: URL, job: Job? = nil) -> Info? {
        guard let log = try? runTool(.ffprobe, ["-v", "error", "-show_entries", "stream=codec_type,r_frame_rate,width,height:format=duration", "-of", "json", url.path], job: job),
              let start = log.firstIndex(of: "{"), let obj = try? JSONSerialization.jsonObject(with: Data(log[start...].utf8)) as? [String: Any] else { return nil }
        var info = Info()
        info.duration = Double((obj["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        for s in obj["streams"] as? [[String: Any]] ?? [] {
            if s["codec_type"] as? String == "audio" { info.hasAudio = true }
            if s["codec_type"] as? String == "video", info.size == .zero {
                info.size = CGSize(width: s["width"] as? Double ?? 0, height: s["height"] as? Double ?? 0)
                let parts = (s["r_frame_rate"] as? String ?? "30/1").split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { info.fps = parts[0] / parts[1] }
            }
        }
        return info.duration > 0 ? info : nil
    }

    /// True when the audio track never gets louder than -60 dB.
    static func isSilent(_ url: URL, job: Job?) -> Bool {
        guard let log = try? runTool(.ffmpeg, ["-hide_banner", "-nostats", "-i", url.path, "-vn", "-af", "volumedetect", "-f", "null", "-"], job: job),
              let r = log.range(of: "max_volume: ") else { return false }
        let value = log[r.upperBound...].prefix { !$0.isWhitespace }
        return Double(value).map { $0 < -60 } ?? false
    }

    static func frame(_ url: URL, at t: Double, to out: URL, job: Job?) -> CGImage? {
        guard (try? runTool(.ffmpeg, ["-y", "-v", "error", "-ss", String(format: "%.3f", t), "-i", url.path, "-frames:v", "1", "-vf", "scale='min(1024,iw)':-2", out.path], job: job)) != nil else { return nil }
        return Pixels.decode(out)
    }

    static func run(input: URL, work: URL, opts: Options, job: Job?, out: inout Output) throws -> Candidate {
        let preset = opts.effective
        guard preset.lossy else { throw Failure.alreadyOptimised }
        let tools = job?.tools ?? .shared
        _ = try tools.executable(.ffmpeg)
        _ = try tools.executable(.ffprobe)
        guard let info = probe(input, job: job) else { throw Failure.other("Could not read this file") }
        out.oldSize = info.size; out.newSize = info.size
        let target = opts.target(transformed: false)
        let excerpt = info.duration > 20
        let start = excerpt ? max(0, info.duration / 2 - 4) : 0
        let length = excerpt ? 8.0 : info.duration
        let times = excerpt ? [1.0, 4.0, 7.0] : [0.1, 0.5, 0.9].map { $0 * info.duration }
        let refs: [SSIM.Reference] = times.enumerated().compactMap { i, t in
            frame(input, at: excerpt ? start + t : t, to: work.appendingPathComponent("ref\(i).png"), job: job).map { SSIM.reference($0) }
        }
        guard refs.count == times.count else { throw Failure.other("Could not read this file") }
        let dropAudio = opts.removeAudio || (info.hasAudio && opts.silentAudio && isSilent(input, job: job))
        let codec = opts.videoCompat ? ("h264_videotoolbox", "avc1") : ("hevc_videotoolbox", "hvc1")
        let ext = input.pathExtension.lowercased()
        var n = 0
        func file(_ e: String) -> URL { n += 1; return work.appendingPathComponent("v\(n).\(e)") }
        func args(_ q: Int, _ output: URL, whole: Bool) -> [String] {
            var a = ["-y", "-v", "error"]
            if !whole { a += ["-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", length)] }
            a += ["-i", input.path, "-map", "0:v:0"]
            if dropAudio { a += ["-an"] } else if info.hasAudio { a += ["-map", "0:a:0?", "-c:a", "copy"] }
            if opts.capFPS, info.fps > Double(opts.targetFPS) + 0.5 { a += ["-vf", "fps=\(opts.targetFPS)"] }
            a += ["-c:v", codec.0, "-q:v", "\(q)", "-tag:v", codec.1, "-allow_sw", "1"]
            if opts.strip { a += ["-map_metadata", "-1"] }
            a += ["-movflags", "+faststart"]
            return a + [output.path]
        }
        let measure: (URL) -> SSIM.Score? = { url in
            var worst: SSIM.Score?
            for (i, t) in times.enumerated() {
                guard let img = frame(url, at: t, to: work.appendingPathComponent("cand\(UUID().uuidString.prefix(6)).png"), job: job) else { return nil }
                let s = SSIM.score(refs[i], img)
                if worst == nil || s.mean < worst!.mean { worst = s }
            }
            return worst
        }
        let deadline = Date().addingTimeInterval(max(8, info.duration * 1.5))
        let lock = NSLock()
        guard var best = ImageEngine.searchCore(target: target, deadline: deadline, job: job, tmp: { e in lock.lock(); defer { lock.unlock() }; return file(e) }, ext: ext, format: nil, lo: 30, hi: 90, start: 55, steps: 6,
                                               encode: { q, url in try runTool(.ffmpeg, args(q, url, whole: !excerpt), job: job) }, measure: measure), best.passed else { throw Failure.alreadyOptimised }
        if excerpt {
            let whole = file(ext)
            try runTool(.ffmpeg, args(best.knob, whole, whole: true), job: job)
            best.url = whole; best.bytes = fileSize(whole)
        }
        if Double(best.bytes) > Double(out.oldBytes) * Engine.minimumGain { throw Failure.alreadyOptimised }
        return best
    }
}

enum PDFEngine {
    static func run(input: URL, work: URL, opts: Options, job: Job?) throws -> Candidate {
        let preset = opts.effective
        let out = work.appendingPathComponent("out.pdf")
        var a = ["-q", "-dNOPAUSE", "-dBATCH", "-dSAFER", "-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.6", "-dDetectDuplicateImages=true",
                 "-dCompressFonts=true", "-dSubsetFonts=true", "-dAutoRotatePages=/None"]
        if let dpi = preset.pdfDPI {
            for kind in ["Color", "Gray"] {
                a += ["-dDownsample\(kind)Images=true", "-d\(kind)ImageResolution=\(dpi)", "-d\(kind)ImageDownsampleType=/Bicubic", "-d\(kind)ImageDownsampleThreshold=1.0"]
            }
            a += ["-dDownsampleMonoImages=true", "-dMonoImageResolution=\(min(600, dpi * 2))", "-dAutoFilterColorImages=false", "-dColorImageFilter=/DCTEncode", "-dAutoFilterGrayImages=false", "-dGrayImageFilter=/DCTEncode"]
        } else {
            a += ["-dDownsampleColorImages=false", "-dDownsampleGrayImages=false", "-dDownsampleMonoImages=false"]
        }
        a += ["-sOutputFile=\(out.path)"]
        var code = ""
        if preset.pdfDPI != nil {
            let dict = "<< /QFactor \(preset.pdfQFactor) /Blend 1 /ColorTransform 1 /HSamples [1 1 1 1] /VSamples [1 1 1 1] >>"
            code += "<< /ColorACSImageDict \(dict) /GrayACSImageDict \(dict) >> setdistillerparams "
        }
        if opts.strip { code += "[ /Title () /Author () /Subject () /Keywords () /Creator () /DOCINFO pdfmark" }
        if !code.isEmpty { a += ["-c", code] }
        a += ["-f", input.path]
        try runTool(.gs, a, job: job)
        let bytes = fileSize(out)
        guard bytes > 0, Double(bytes) <= Double(fileSize(input)) * Engine.minimumGain else { throw Failure.alreadyOptimised }
        return Candidate(url: out, bytes: bytes, ssim: -1, passed: true, format: nil)
    }
}
