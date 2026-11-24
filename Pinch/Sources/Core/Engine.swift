import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Kind: String, Sendable {
    case png, jpeg, gif, webp, avif, heic, video, pdf
    static func of(_ url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "gif": .gif
        case "webp": .webp
        case "avif": .avif
        case "heic", "heif": .heic
        case "mov", "mp4", "m4v": .video
        case "pdf": .pdf
        default: nil
        }
    }
    var isImage: Bool { self != .video && self != .pdf }
    var format: ImageFormat? {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .gif: .gif
        case .webp: .webp
        case .avif: .avif
        case .heic: .heic
        default: nil
        }
    }
}

struct Options: Sendable {
    var preset: Preset = .identical
    /// "Optimise harder": the SSIM target drops by 0.02 (never below 0.95); Lossless becomes Visually identical.
    var aggressive = false
    var downscale: Double?
    var blur = false
    var shouldBlur: Bool { blur && Prefs.blurOn }
    var blurCats: BlurCategories = []
    var strip = true
    var preserveDates = true
    var videoCompat = false
    var capFPS = true
    var targetFPS = 60
    var removeAudio = false
    var silentAudio = true
    /// Explicit format (command line, Shortcuts, the convert keys). Always honoured.
    var convert: ImageFormat?
    /// Lets a preset change the format (chat, web). False for screenshots and the clipboard.
    var allowConvert = false
    var webFallback = false
    var ssimTarget: Double?
    /// Process even files Pinch already optimised (explicit actions on a card, `pinch --force`).
    var force = false

    var effective: Preset { aggressive && preset == .lossless ? .identical : preset }
    func target(transformed: Bool) -> Double {
        if let ssimTarget { return ssimTarget }
        let p = effective
        if p == .lossless { return transformed ? 0.99 : 1 }
        return max(0.95, p.ssim - (aggressive ? 0.02 : 0))
    }

    /// Options from the current settings.
    static func fromPrefs(preset: Preset? = nil, blur: Bool = false) -> Options {
        Options(preset: preset ?? Prefs.preset, blur: blur && Prefs.blurOn, blurCats: Prefs.blurCategories,
                strip: Prefs.stripMetadata, preserveDates: Prefs.preserveDates, videoCompat: Prefs.videoCompat,
                capFPS: Prefs.capFPS, targetFPS: Prefs.targetFPS, removeAudio: Prefs.removeAudio, silentAudio: Prefs.silentAudio,
                webFallback: Prefs.webFallback)
    }
}

struct Output: Sendable {
    var oldBytes = 0, newBytes = 0
    var oldSize: CGSize?, newSize: CGSize?
    var hidden = 0
    /// SSIM of the written file against the original (1 for lossless results).
    var ssim: Double?
    /// The file that was written. Differs from the requested output when the format changed.
    var url: URL?
}

/// One finished encode that is ready to be chosen.
struct Candidate: @unchecked Sendable {
    var url: URL
    var bytes: Int
    var ssim: Double
    var passed: Bool
    /// Nil means the format of the input.
    var format: ImageFormat?
    /// The quality setting that produced it.
    var knob = 0
}

enum Engine {
    /// A result must be at least this much smaller than the original, otherwise the original stays.
    static let minimumGain = 0.97

    static func imageSize(_ url: URL) -> CGSize? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    static func decode(_ url: URL, maxPixel: Int? = nil) -> CGImage? {
        guard let full = Pixels.decode(url) else { return nil }
        guard let m = maxPixel, max(full.width, full.height) > m else { return full }
        let f = Double(m) / Double(max(full.width, full.height))
        return Pixels.resized(full, width: max(1, Int(Double(full.width) * f)), height: max(1, Int(Double(full.height) * f)))
    }

    static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw Failure.other("Could not write this file") }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw Failure.other("Could not write this file") }
    }

    /// Reads `input` (never touched), writes the optimised result next to `output` (same name, or the
    /// converted extension). Throws `.alreadyOptimised` when nothing was gained and nothing was transformed.
    static func process(input: URL, output: URL, opts: Options, job: Job? = nil) throws -> Output {
        guard let kind = Kind.of(input) else { throw Failure.unsupported }
        if !opts.force, XAttr.has(XAttr.status, input) { throw Failure.alreadyOptimised }
        let fm = FileManager.default
        let work = Paths.work.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        var out = Output(oldBytes: fileSize(input), oldSize: imageSize(input))
        let chosen: Candidate
        switch kind {
        case .video: chosen = try VideoEngine.run(input: input, work: work, opts: opts, job: job, out: &out)
        case .pdf: chosen = try PDFEngine.run(input: input, work: work, opts: opts, job: job)
        default: chosen = try ImageEngine.run(kind, input: input, work: work, opts: opts, job: job, out: &out)
        }
        let final = chosen.format == nil || chosen.format == kind.format ? output : output.deletingPathExtension().appendingPathExtension(chosen.format!.ext)
        try? fm.removeItem(at: final)
        do { try fm.moveItem(at: chosen.url, to: final) } catch { throw Failure.other("Could not write this file") }
        XAttr.copyAll(from: input, to: final)
        XAttr.set(XAttr.status, "true", final)
        if opts.preserveDates, let a = try? fm.attributesOfItem(atPath: input.path) {
            var keep: [FileAttributeKey: Any] = [:]
            keep[.modificationDate] = a[.modificationDate]; keep[.creationDate] = a[.creationDate]
            try? fm.setAttributes(keep.compactMapValues { $0 }, ofItemAtPath: final.path)
        }
        out.newBytes = fileSize(final)
        out.ssim = chosen.ssim >= 0 ? chosen.ssim : nil
        out.url = final
        if out.newSize == nil { out.newSize = imageSize(final) }
        return out
    }

    /// Image encoders that may take several minutes should not outlive their time budget.
    static func budget(pixels: Int) -> Date {
        let scale = Double(ProcessInfo.processInfo.environment["PINCH_TIME_SCALE"] ?? "") ?? 1
        return Date().addingTimeInterval(scale * min(10, 2 + Double(pixels) / 1_000_000 * 0.8))
    }
}

/// A copy of the original kept in the cache, so "Restore original" always works.
enum Backup {
    static func make(_ url: URL) -> URL? {
        let dest = Paths.backups.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
        do { try FileManager.default.copyItem(at: url, to: dest); return dest } catch { return nil }
    }
}
