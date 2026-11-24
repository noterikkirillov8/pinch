import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Headless entry points used by scripts/test-engine.sh and scripts/bench.sh:
///   Pinch -optimise <file> [-preset name] [-ssim 0.97] [-aggressive] [-blur] [-keep-metadata]   in place (original kept in the backups folder)
///   Pinch -make-samples <dir>                            generate the sample set (UI screenshots, photos, GIF, recording, PDF)
///   Pinch -selftest <dir>                                search, SSIM gate, presets, blur, metadata, auto-name checks
/// plus the public `pinch` command (Command.swift).
enum CLI {
    static func runIfAsked() -> Int32? {
        let a = CommandLine.arguments
        if let code = Command.runIfAsked() { return code }
        if let i = a.firstIndex(of: "-optimise"), i + 1 < a.count { return optimise(URL(fileURLWithPath: a[i + 1]), a) }
        if let i = a.firstIndex(of: "-make-samples"), i + 1 < a.count { Samples.make(in: URL(fileURLWithPath: a[i + 1], isDirectory: true)); return 0 }
        if let i = a.firstIndex(of: "-selftest"), i + 1 < a.count { return SelfTest.run(in: URL(fileURLWithPath: a[i + 1], isDirectory: true)) }
        return nil
    }

    static func optimise(_ url: URL, _ a: [String]) -> Int32 {
        if a.contains("-blur") && !Prefs.blurOn { print("ERROR Enable experimental blur in Settings > Privacy first"); return 1 }
        guard let backup = Backup.make(url) else { print("ERROR cannot read \(url.path)"); return 1 }
        var o = Options.fromPrefs(blur: a.contains("-blur"))
        if let i = a.firstIndex(of: "-preset"), i + 1 < a.count, let p = Preset(name: a[i + 1]) { o.preset = p } else if a.contains("-ai") { o.preset = .ai }
        o.aggressive = a.contains("-aggressive")
        if a.contains("-keep-metadata") { o.strip = false }
        if let i = a.firstIndex(of: "-ssim"), i + 1 < a.count, let t = Double(a[i + 1]) { o.ssimTarget = t }
        do {
            let start = Date()
            let r = try Engine.process(input: backup, output: url, opts: o)
            print("OK \(r.oldBytes) \(r.newBytes) hidden=\(r.hidden) ssim=\(r.ssim.map { String(format: "%.4f", $0) } ?? "-") seconds=\(String(format: "%.2f", Date().timeIntervalSince(start))) file=\(r.url?.lastPathComponent ?? "")")
            return 0
        } catch Failure.alreadyOptimised {
            print("UNCHANGED \(fileSize(url))"); return 2
        } catch {
            print("ERROR \((error as? LocalizedError)?.errorDescription ?? "\(error)")"); return 1
        }
    }
}

enum Samples {
    nonisolated(unsafe) static let font = NSFont(name: "Helvetica", size: 34) ?? .systemFont(ofSize: 34)
    static let lines = ["Contact: robin.vale@example.com", "Token: sk-ant-api03-Zx9Qm4LpRt2VbNc5KdWq8", "Meeting notes for Monday morning standup"]
    static let lineH: CGFloat = 80, margin: CGFloat = 40, width = 1300, height = 420

    static func ctx(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func attrs() -> [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: NSColor.black] }

    /// White image with the lines of text drawn at known positions.
    static func secrets(_ texts: [String] = lines) -> CGImage {
        let c = ctx(width, height)
        c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        for (i, t) in texts.enumerated() {
            NSAttributedString(string: t, attributes: attrs()).draw(at: CGPoint(x: margin, y: CGFloat(height) - margin - CGFloat(i + 1) * lineH + 20))
        }
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()!
    }

    /// Pixel rect (top-left origin) of `part` inside line `i`.
    static func rect(line i: Int, part: String) -> CGRect {
        let text = lines[i]
        let before = (text as NSString).substring(to: (text as NSString).range(of: part).location)
        let x = margin + NSAttributedString(string: before, attributes: attrs()).size().width
        let w = NSAttributedString(string: part, attributes: attrs()).size().width
        return CGRect(x: x, y: margin + CGFloat(i) * lineH + 8, width: w, height: 44)
    }

    /// Soft coloured blobs plus fine noise: compresses like a photo.
    static func photo(_ w: Int, _ h: Int) -> CGImage {
        let c = ctx(w, h)
        var seed: UInt64 = 42
        func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((seed >> 33) % 10000) / 10000 }
        c.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0 ..< 260 {
            c.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 0.35))
            let s = 60 + rnd() * 420
            c.fillEllipse(in: CGRect(x: rnd() * CGFloat(w) - s / 2, y: rnd() * CGFloat(h) - s / 2, width: s, height: s))
        }
        for _ in 0 ..< w * h / 14 {
            c.setFillColor(CGColor(gray: rnd(), alpha: 0.10))
            c.fill(CGRect(x: rnd() * CGFloat(w), y: rnd() * CGFloat(h), width: 2, height: 2))
        }
        return c.makeImage()!
    }

    static func save(_ img: CGImage, _ url: URL, _ type: UTType, quality: Double = 1) {
        let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    static func make(in dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = photo(1600, 1000)
        save(p, dir.appendingPathComponent("photo.png"), .png)
        save(p, dir.appendingPathComponent("photo.jpg"), .jpeg, quality: 1)
        save(photo(3000, 2000), dir.appendingPathComponent("big.png"), .png)
        save(secrets(), dir.appendingPathComponent("secrets.png"), .png)
        save(secrets(["Hello world, nothing private here", "Just a normal sentence about lunch", "Meeting notes for Monday morning standup"]), dir.appendingPathComponent("plain.png"), .png)
        makeBench(in: dir)
    }
}

enum SelfTest {
    nonisolated(unsafe) static var failures = 0
    static func check(_ name: String, _ ok: Bool, _ why: @autoclosure () -> String = "") {
        print(ok ? "PASS \(name)" : "FAIL \(name) \(why())")
        if !ok { failures += 1 }
    }

    /// Fraction of pixels that differ between two images inside a top-left-origin rect.
    static func changed(_ a: CGImage, _ b: CGImage, _ r: CGRect) -> Double {
        func px(_ i: CGImage) -> [UInt8] {
            let c = Samples.ctx(i.width, i.height)
            c.draw(i, in: CGRect(x: 0, y: 0, width: i.width, height: i.height))
            let d = c.data!.assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: d, count: c.bytesPerRow * i.height))
        }
        let pa = px(a), pb = px(b), bpr = Samples.ctx(a.width, 1).bytesPerRow
        var diff = 0, total = 0
        for y in Int(r.minY) ..< Int(r.maxY) {
            let row = y * bpr
            for x in Int(r.minX) ..< Int(r.maxX) {
                total += 1
                let o = row + x * 4
                if pa[o] != pb[o] || pa[o + 1] != pb[o + 1] || pa[o + 2] != pb[o + 2] { diff += 1 }
            }
        }
        return total == 0 ? 0 : Double(diff) / Double(total)
    }

    static func run(in dir: URL) -> Int32 {
        Samples.make(in: dir)
        introFlowChecks { check($1, $0) }
        // Blur
        let img = Samples.secrets()
        if let (out, n) = Redactor.redact(img, .all) {
            let email = Samples.rect(line: 0, part: "robin.vale@example.com"), key = Samples.rect(line: 1, part: "sk-ant-api03-Zx9Qm4LpRt2VbNc5KdWq8")
            check("blur: email region changed", changed(img, out, email) > 0.15, "\(changed(img, out, email))")
            check("blur: sk-ant key region changed", changed(img, out, key) > 0.15, "\(changed(img, out, key))")
            check("blur: text elsewhere unchanged (line 3)", changed(img, out, CGRect(x: 0, y: 200, width: 1300, height: 90)) == 0)
            check("blur: 'Contact:' label unchanged", changed(img, out, CGRect(x: Samples.margin, y: Samples.margin + 8, width: Samples.rect(line: 0, part: "robin").minX - Samples.margin - 12, height: 44)) == 0)
            check("blur: 2 regions hidden", n == 2, "\(n)")
        } else { check("blur: found private text", false, "nothing matched") }
        check("blur: nothing matched, nothing blurred", Redactor.redact(Samples.secrets(["Hello world, nothing private here", "Just a normal sentence", "Lunch at noon"]), .all) == nil)
        // Patterns
        func hit(_ s: String, _ c: BlurCategories = .all) -> Bool { !Redactor.find(in: s, c).isEmpty }
        check("find: email", hit("mail a.b+c@mail.example.org now"))
        check("find: keys", hit("sk-ant-api03-abcdefgh1234") && hit("ghp_abcdefghijklmnopqrstuvwxyz0123") && hit("github_pat_11ABCDEFG0abcdefghijklmn") && hit("AKIAIOSFODNN7EXAMPLE") && hit("xoxb-1234567890-abcdef") && hit("eyJhbGciOi.eyJzdWIiOiIx.SflKxwRJSMeKKF2QT4"))
        check("find: long hex and base64", hit("a3f5c9d1e7b24680a3f5c9d1e7b24680") && hit("QWxhZGRpbjpvcGVuIHNlc2FtZTEyMzQ1Njc4OTA="))
        check("find: phone", hit("call +66 81 234 5678 today") && hit("(415) 555-0132"))
        check("find: card", hit("4242 4242 4242 4242") && hit("4111111111111111"))
        check("find: no false positives", !hit("2026-11-20 14.03.21") && !hit("Meeting notes for Monday morning standup") && !hit("version 1.2.3 build 456"))
        check("find: categories respected", !hit("a@b.com", [.keys]) && hit("a@b.com", [.email]))
        // Drag out
        let dragPNG = dir.appendingPathComponent("photo.png")
        let di = Drag.pasteboardItem(dragPNG)
        check("drag: file url + png + tiff", di.types.contains(.fileURL) && di.types.contains(.png) && di.types.contains(.tiff), "\(di.types)")
        check("drag: file url points at the file", di.string(forType: .fileURL).flatMap { URL(string: $0) }?.path == dragPNG.path)
        check("drag: png data is the file bytes", di.data(forType: .png) == (try? Data(contentsOf: dragPNG)))
        check("drag: tiff decodes", di.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0) } != nil)
        let dragJPG = dir.appendingPathComponent("photo.jpg")
        let dj = Drag.pasteboardItem(dragJPG)
        check("drag: jpeg keeps jpeg, adds png and tiff", dj.types.contains(NSPasteboard.PasteboardType("public.jpeg")) && dj.data(forType: .png).flatMap { NSBitmapImageRep(data: $0) } != nil && dj.types.contains(.tiff))
        let clipItem = MainActor.assumeIsolated { Item(name: "Shot", ext: "png", source: .clipboard) }
        let clipFile = dir.appendingPathComponent("clip-\(UUID().uuidString)/abc.png")
        try? FileManager.default.createDirectory(at: clipFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: dragPNG, to: clipFile)
        MainActor.assumeIsolated { clipItem.dest = clipFile }
        let staged = MainActor.assumeIsolated { Drag.file(for: clipItem) }
        check("drag: clipboard result staged as drag/Shot.png", staged?.deletingLastPathComponent().lastPathComponent == "drag" && staged?.lastPathComponent == "Shot.png" && (staged.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: dragPNG))), "\(String(describing: staged))")
        if let staged { try? FileManager.default.removeItem(at: staged) }
        let dd = dir.appendingPathComponent("dragclean", isDirectory: true)
        try? FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
        let oldF = dd.appendingPathComponent("old.png"), newF = dd.appendingPathComponent("new.png")
        for f in [oldF, newF] { FileManager.default.createFile(atPath: f.path, contents: Data([1])) }
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90000)], ofItemAtPath: oldF.path)
        Drag.cleanup(in: dd)
        check("drag: cleanup trashes files older than a day, keeps new", !FileManager.default.fileExists(atPath: oldF.path) && FileManager.default.fileExists(atPath: newF.path))
        EngineTests.run(in: dir)
        let small = dir.appendingPathComponent("photo.png")
        // Auto-name
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 20; c.hour = 14; c.minute = 3; c.second = 21
        let date = Calendar.current.date(from: c)!
        check("auto-name: format", AutoName.format(app: "Safari", date: date, ext: "png") == "Safari 2026-11-20 at 14.03.21.png", AutoName.format(app: "Safari", date: date, ext: "png"))
        let nd = dir.appendingPathComponent("names", isDirectory: true)
        try? FileManager.default.removeItem(at: nd); try? FileManager.default.createDirectory(at: nd, withIntermediateDirectories: true)
        let name = AutoName.format(app: "Safari", date: date, ext: "png")
        var got: [String] = []
        for _ in 0 ..< 3 { let u = AutoName.unique(in: nd, name: name); got.append(u.lastPathComponent); FileManager.default.createFile(atPath: u.path, contents: Data()) }
        check("auto-name: clashes get 2 and 3", got == ["Safari 2026-11-20 at 14.03.21.png", "Safari 2026-11-20 at 14.03.21 2.png", "Safari 2026-11-20 at 14.03.21 3.png"], "\(got)")
        var ledger = Ledger()
        for _ in 0..<55 {
            ledger.add(Receipt(id: UUID(), date: date, name: "survey.png", before: 1000, after: 200, output: small, original: small))
        }
        check("history: daily savings include evicted receipts", ledger.recent.count == 50 && ledger.saved == 44_000 && ledger.input == 55_000)
        let id = ledger.recent[0].id
        ledger.add(Receipt(id: id, date: date, name: "survey.png", before: 1000, after: 100, output: small, original: small))
        check("history: repeated job replaces previous savings", ledger.recent.count == 50 && ledger.saved == 44_100 && ledger.input == 55_000)
        let roundTrip = try? JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        check("history: persisted order and total survive reload", roundTrip?.recent.map(\.id) == ledger.recent.map(\.id) && roundTrip?.saved == ledger.saved)
        ledger.roll(to: Calendar.current.date(byAdding: .day, value: 1, to: date)!)
        check("history: midnight resets totals, not results", ledger.saved == 0 && ledger.input == 0 && ledger.recent.count == 50)
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }
}
