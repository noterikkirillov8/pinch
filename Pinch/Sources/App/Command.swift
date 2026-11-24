import Foundation

/// The `pinch` command line: `pinch optimise <files or folders> [--preset chat] [--to webp] [--out dir]`.
/// Runs without any window, so it works from a terminal, a script or a symlink in ~/.local/bin.
enum Command {
    static let usage = """
    pinch: optimise images, videos, GIFs and PDFs on this Mac.

      pinch optimise <files or folders> [options]
      pinch presets
      pinch --version

    Options
      --preset <name>   identical (default), chat, ai, web, lossless
      --to <format>     convert images: png, jpg, webp, avif, jxl, heic; GIFs: mp4 (the original stays)
      --out <dir>       write results into <dir>; without it files are replaced in place
                        and the original is kept in ~/Library/Caches/Pinch/backups
      --ssim <0.9-1>    custom SSIM target
      --blur            blur matching private info (requires opt-in in Settings > Privacy)
      --keep-metadata   do not strip metadata
      --force           process files Pinch already optimised
      --quiet           print only errors

    """

    static func runIfAsked() -> Int32? {
        let a = Array(CommandLine.arguments.dropFirst())
        guard let verb = a.first else { return nil }
        switch verb {
        case "optimise", "optimize", "optimise-files": return optimise(Array(a.dropFirst()))
        case "presets":
            for p in Preset.allCases { print("\(p.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(p.title): \(p.detail)") }
            return 0
        case "--version", "-v": print("pinch 1.0"); return 0
        case "--help", "-h", "help": print(usage, terminator: ""); return 0
        default: return nil
        }
    }

    struct Request {
        var inputs: [URL] = []
        var opts = Options.fromPrefs()
        var out: URL?
        var quiet = false
        var gifToMP4 = false
    }

    static func parse(_ args: [String]) -> Request? {
        var r = Request()
        var i = 0
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--preset", "-p":
                guard let v = value(), let p = Preset(name: v) else { fputs("pinch: unknown preset\n", stderr); return nil }
                r.opts.preset = p
            case "--to", "-t":
                if i + 1 < args.count, args[i + 1].lowercased() == "mp4" { r.gifToMP4 = true; i += 2; continue }
                guard let v = value(), let f = ImageFormat(name: v) else { fputs("pinch: unknown format\n", stderr); return nil }
                r.opts.convert = f
            case "--out", "-o":
                guard let v = value() else { return nil }
                r.out = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
            case "--ssim":
                guard let v = value(), let d = Double(v), (0.9 ... 1).contains(d) else { fputs("pinch: --ssim takes 0.9 to 1\n", stderr); return nil }
                r.opts.ssimTarget = d
            case "--blur": r.opts.blur = true; r.opts.blurCats = .all
            case "--keep-metadata": r.opts.strip = false
            case "--force": r.opts.force = true
            case "--quiet", "-q": r.quiet = true
            default:
                if args[i].hasPrefix("-") { fputs("pinch: unknown option \(args[i])\n", stderr); return nil }
                r.inputs.append(URL(fileURLWithPath: (args[i] as NSString).expandingTildeInPath))
            }
            i += 1
        }
        return r
    }

    /// Files and, recursively, the supported files inside folders.
    static func expand(_ urls: [URL], quiet: Bool = false) -> [URL] {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { if !quiet { fputs("pinch: \(u.path): no such file\n", stderr) }; continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL { if Kind.of(f) != nil { files.append(f) } }
            } else if Kind.of(u) != nil { files.append(u) } else if !quiet { fputs("pinch: \(u.lastPathComponent): unsupported file type\n", stderr) }
        }
        return files
    }

    static func optimise(_ args: [String]) -> Int32 {
        guard let r = parse(args) else { return 64 }
        let files = expand(r.inputs)
        guard !files.isEmpty else { fputs("pinch: nothing to optimise\n", stderr); return 64 }
        var before = 0, after = 0, failed = 0
        for file in files {
            let start = Date()
            switch process(file, r) {
            case let .done(o):
                before += o.oldBytes; after += o.newBytes
                if !r.quiet {
                    let pct = o.oldBytes > 0 ? Int((100 * Double(o.oldBytes - o.newBytes) / Double(o.oldBytes)).rounded()) : 0
                    let same = o.ssim.map { String(format: "%.1f%% identical", $0 * 100) } ?? ""
                    print("\(o.url?.lastPathComponent ?? file.lastPathComponent)  \(o.oldBytes.humanSize) to \(o.newBytes.humanSize)  -\(pct)%  \(same)  \(String(format: "%.1f s", Date().timeIntervalSince(start)))")
                }
            case let .unchanged(bytes):
                before += bytes; after += bytes
                if !r.quiet { print("\(file.lastPathComponent)  \(bytes.humanSize), already as small as it gets") }
            case let .failed(message):
                failed += 1; fputs("pinch: \(file.lastPathComponent): \(message)\n", stderr)
            }
        }
        if !r.quiet, files.count > 1 { print("Total  \(before.humanSize) to \(after.humanSize)  saved \(max(0, before - after).humanSize)") }
        return failed == 0 ? 0 : 1
    }

    enum Result { case done(Output), unchanged(Int), failed(String) }

    /// One file, in place (original backed up) or into `--out`.
    static func process(_ file: URL, _ r: Request) -> Result {
        if r.opts.blur && !Prefs.blurOn { return .failed("Enable experimental blur in Settings > Privacy first") }
        let dest: URL
        let source: URL
        if let out = r.out {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            dest = out.appendingPathComponent(file.lastPathComponent); source = file
        } else {
            guard let backup = Backup.make(file) else { return .failed("cannot read this file") }
            dest = file; source = backup
        }
        do {
            var o = r.opts
            if Kind.of(file) == .gif, r.gifToMP4 { return .done(try Engine.convertGIF(file, into: r.out ?? file.deletingLastPathComponent())) }
            o.blur = o.blur && Kind.of(file)?.isImage == true && Kind.of(file) != .gif
            return .done(try Engine.process(input: source, output: dest, opts: o))
        } catch Failure.alreadyOptimised {
            if r.out != nil { try? FileManager.default.removeItem(at: dest); try? FileManager.default.copyItem(at: file, to: dest) }
            return .unchanged(fileSize(file))
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }
}
