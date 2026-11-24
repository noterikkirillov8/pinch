import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Deterministic stand-ins for what people actually optimise: UI screenshots, camera photos, a GIF,
/// a screen recording and a PDF with a large picture. Used by scripts/bench.sh and the tests.
extension Samples {
    private struct Rng {
        var s: UInt64
        mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((s >> 33) % 100_000) / 100_000 }
    }

    private static func draw(_ c: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func text(_ s: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, color: NSColor, mono: Bool = false, weight: NSFont.Weight = .regular) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: CGPoint(x: x, y: y))
    }

    private static func context(_ w: Int, _ h: Int, p3: Bool) -> CGContext {
        let space = p3 ? CGColorSpace(name: CGColorSpace.displayP3)! : CGColorSpace(name: CGColorSpace.sRGB)!
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setShouldSmoothFonts(true); c.setAllowsFontSmoothing(true)
        return c
    }

    private static func shadowedPanel(_ c: CGContext, _ r: CGRect, fill: CGColor, radius: CGFloat = 18) {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: CGColor(gray: 0, alpha: 0.35))
        c.setFillColor(fill)
        c.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); c.fillPath()
        c.restoreGState()
    }

    /// Dark analytics window on a flat desktop, retina size. `p3` tags it Display P3 like a real Mac screenshot.
    static func uiDashboard(p3: Bool = false) -> CGImage {
        let w = 2400, h = 1500
        let c = context(w, h, p3: p3)
        c.setFillColor(CGColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 420, height: h))
        var rng = Rng(s: 7)
        draw(c) {
            text("orbit", 56, CGFloat(h) - 96, size: 44, color: .white, weight: .semibold)
            for (i, item) in ["Overview", "Traffic", "Revenue", "Customers", "Experiments", "Reports", "Settings"].enumerated() {
                let y = CGFloat(h) - 220 - CGFloat(i) * 92
                if i == 0 { c.setFillColor(CGColor(red: 0.22, green: 0.24, blue: 0.3, alpha: 1)); c.fill(CGRect(x: 28, y: y - 24, width: 364, height: 76)) }
                text(item, 72, y, size: 32, color: i == 0 ? .white : NSColor(white: 0.7, alpha: 1))
            }
            text("Overview", 500, CGFloat(h) - 120, size: 56, color: .white, weight: .bold)
            text("Last 30 days, all regions", 500, CGFloat(h) - 176, size: 28, color: NSColor(white: 0.6, alpha: 1))
        }
        let accents: [CGColor] = [CGColor(red: 0.35, green: 0.55, blue: 1, alpha: 1), CGColor(red: 0.3, green: 0.8, blue: 0.55, alpha: 1), CGColor(red: 1, green: 0.65, blue: 0.3, alpha: 1)]
        for k in 0 ..< 3 {
            let r = CGRect(x: 500 + CGFloat(k) * 600, y: CGFloat(h) - 460, width: 560, height: 220)
            shadowedPanel(c, r, fill: CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1))
            c.setFillColor(accents[k]); c.fill(CGRect(x: r.minX + 36, y: r.minY + 36, width: 10, height: 148))
            draw(c) {
                text(["Visitors", "Revenue", "Conversion"][k], r.minX + 70, r.maxY - 70, size: 28, color: NSColor(white: 0.62, alpha: 1))
                text(["48,203", "$92,410", "3.8%"][k], r.minX + 70, r.maxY - 150, size: 64, color: .white, weight: .semibold)
            }
        }
        let chart = CGRect(x: 500, y: 140, width: 1800, height: 780)
        shadowedPanel(c, chart, fill: CGColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1))
        for i in 0 ..< 30 {
            let bh = 120 + rng.next() * 520
            c.setFillColor(accents[i % 3]); c.fill(CGRect(x: chart.minX + 50 + CGFloat(i) * 56, y: chart.minY + 60, width: 38, height: bh))
        }
        return c.makeImage()!
    }

    /// Light code editor: lots of small text in a few colours.
    static func uiEditor() -> CGImage {
        let w = 2200, h = 1400
        let c = context(w, h, p3: false)
        c.setFillColor(CGColor(gray: 0.98, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(CGColor(gray: 0.93, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 360, height: h)); c.fill(CGRect(x: 0, y: CGFloat(h) - 90, width: CGFloat(w), height: 90))
        let code = ["import Foundation", "", "struct Invoice: Codable {", "    let id: UUID", "    var lines: [Line]", "    var currency = \"EUR\"", "", "    var total: Decimal {", "        lines.reduce(0) { $0 + $1.price * Decimal($1.quantity) }", "    }", "}", "", "func send(_ invoice: Invoice, to client: Client) async throws {", "    let body = try JSONEncoder().encode(invoice)", "    var request = URLRequest(url: client.endpoint)", "    request.httpMethod = \"POST\"", "    request.httpBody = body", "    let (_, response) = try await URLSession.shared.data(for: request)", "    guard (response as? HTTPURLResponse)?.statusCode == 200 else {", "        throw RelayError.rejected", "    }", "}"]
        let kw = NSColor(red: 0.7, green: 0.15, blue: 0.55, alpha: 1), plain = NSColor(white: 0.15, alpha: 1), str = NSColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1)
        draw(c) {
            text("relay / Invoice.swift", 400, CGFloat(h) - 62, size: 30, color: NSColor(white: 0.3, alpha: 1), weight: .medium)
            for (i, line) in code.enumerated() {
                let y = CGFloat(h) - 190 - CGFloat(i) * 52
                text("\(i + 1)", 400, y, size: 28, color: NSColor(white: 0.65, alpha: 1), mono: true)
                let first = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
                let color = ["import", "struct", "func", "var", "let", "guard", "throw", "try"].contains(first) ? kw : (line.contains("\"") ? str : plain)
                text(line, 500, y, size: 30, color: color, mono: true)
            }
            for (i, f) in ["Sources", "Invoice.swift", "Client.swift", "RelayError.swift", "Tests"].enumerated() { text(f, 48, CGFloat(h) - 190 - CGFloat(i) * 64, size: 30, color: NSColor(white: 0.25, alpha: 1)) }
        }
        return c.makeImage()!
    }

    /// A settings window with a soft drop shadow over a wallpaper made of a few large flat zones.
    static func uiSettings() -> CGImage {
        let w = 2000, h = 1300
        let c = context(w, h, p3: false)
        for (i, col) in [CGColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1), CGColor(red: 0.25, green: 0.45, blue: 0.7, alpha: 1), CGColor(red: 0.15, green: 0.28, blue: 0.5, alpha: 1)].enumerated() {
            c.setFillColor(col); c.fill(CGRect(x: 0, y: CGFloat(i) * CGFloat(h) / 3, width: CGFloat(w), height: CGFloat(h) / 3 + 1))
        }
        let win = CGRect(x: 260, y: 140, width: 1480, height: 1020)
        shadowedPanel(c, win, fill: CGColor(gray: 0.97, alpha: 1), radius: 22)
        draw(c) {
            text("Notifications", win.minX + 60, win.maxY - 90, size: 44, color: NSColor(white: 0.1, alpha: 1), weight: .semibold)
            for (i, row) in ["Allow notifications", "Show previews", "Badge app icon", "Play sound for new mail", "Group by thread", "Mute while sharing screen"].enumerated() {
                let y = win.maxY - 220 - CGFloat(i) * 130
                text(row, win.minX + 60, y, size: 34, color: NSColor(white: 0.15, alpha: 1))
                text("Applies to all accounts on this Mac", win.minX + 60, y - 42, size: 24, color: NSColor(white: 0.5, alpha: 1))
            }
        }
        for i in 0 ..< 6 {
            let y = win.maxY - 232 - CGFloat(i) * 130
            c.setFillColor(i % 3 == 1 ? CGColor(gray: 0.8, alpha: 1) : CGColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 1))
            c.addPath(CGPath(roundedRect: CGRect(x: win.maxX - 190, y: y, width: 110, height: 62), cornerWidth: 31, cornerHeight: 31, transform: nil)); c.fillPath()
        }
        return c.makeImage()!
    }

    /// Smooth sky, hills and foliage with mild sensor grain: compresses like a camera JPEG.
    static func photoNatural(_ w: Int, _ h: Int, seed: UInt64) -> CGImage {
        let c = context(w, h, p3: false)
        var rng = Rng(s: seed)
        let sky = [CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1), CGColor(red: 0.85, green: 0.78, blue: 0.7, alpha: 1)] as CFArray
        c.drawLinearGradient(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sky, locations: [0, 1])!, start: CGPoint(x: 0, y: CGFloat(h)), end: CGPoint(x: 0, y: CGFloat(h) * 0.4), options: [.drawsAfterEndLocation])
        for layer in 0 ..< 5 {
            let base = CGFloat(h) * (0.1 + 0.12 * CGFloat(layer)), amp = CGFloat(h) * (0.05 + 0.02 * CGFloat(layer))
            let phase = rng.next() * 6, freq = 2 + rng.next() * 3
            c.setFillColor(CGColor(red: 0.12 + 0.07 * CGFloat(layer), green: 0.25 + 0.08 * CGFloat(layer), blue: 0.15 + 0.05 * CGFloat(layer), alpha: 1))
            c.move(to: CGPoint(x: 0, y: 0))
            for x in stride(from: 0, through: w, by: 8) {
                let t = CGFloat(x) / CGFloat(w)
                c.addLine(to: CGPoint(x: CGFloat(x), y: base + amp * sin(t * freq * 3.14 + phase) + amp * 0.4 * sin(t * 17 + phase)))
            }
            c.addLine(to: CGPoint(x: CGFloat(w), y: 0)); c.fillPath()
        }
        for _ in 0 ..< 1800 {
            let s = 8 + rng.next() * 40
            c.setFillColor(CGColor(red: 0.1 + rng.next() * 0.2, green: 0.3 + rng.next() * 0.3, blue: 0.1 + rng.next() * 0.15, alpha: 0.25))
            c.fillEllipse(in: CGRect(x: rng.next() * CGFloat(w), y: rng.next() * CGFloat(h) * 0.45, width: s, height: s * 0.8))
        }
        for _ in 0 ..< w * h / 5 {
            c.setFillColor(CGColor(gray: rng.next(), alpha: 0.02))
            c.fill(CGRect(x: rng.next() * CGFloat(w), y: rng.next() * CGFloat(h), width: 1, height: 1))
        }
        return c.makeImage()!
    }

    static func saveJPEG(_ image: CGImage, _ url: URL, quality: Double, gps: Bool) {
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 7.8804, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 98.3923, kCGImagePropertyGPSLongitudeRef: "E"]
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifUserComment: "field test", kCGImagePropertyExifDateTimeOriginal: "2026:11:20 14:03:21"]
            props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Orbit", kCGImagePropertyTIFFModel: "Cam 1"]
        }
        let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, props as CFDictionary)
        CGImageDestinationFinalize(d)
    }

    /// PDF with real text, vector shapes and one 400 dpi photo.
    static func reportPDF(to url: URL, photo: CGImage) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in 0 ..< 2 {
            c.beginPDFPage(nil)
            draw(c) {
                text("Field report \(page + 1)", 56, 720, size: 28, color: .black, weight: .bold)
                for i in 0 ..< 18 { text("Observation \(i + 1): the ridge line held steady through the afternoon and the light moved west.", 56, 680 - CGFloat(i) * 16, size: 11, color: .darkGray) }
            }
            c.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)); c.fill(CGRect(x: 56, y: 330, width: 500, height: 6))
            c.draw(photo, in: CGRect(x: 56, y: 56, width: 500, height: 260))
            c.endPDFPage()
        }
        c.closePDF()
    }

    static func makeBench(in dir: URL) {
        // Regenerated files must not inherit the optimised marker of an earlier run.
        for n in ["ui-dashboard.png", "ui-p3.png", "ui-editor.png", "ui-settings.png", "photo-a.jpg", "photo-b.jpg", "report.pdf", "anim.gif", "recording.mov"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(n)) }
        func put(_ img: CGImage, _ name: String) { save(img, dir.appendingPathComponent(name), .png) }
        put(uiDashboard(), "ui-dashboard.png")
        put(uiDashboard(p3: true), "ui-p3.png")
        put(uiEditor(), "ui-editor.png")
        put(uiSettings(), "ui-settings.png")
        saveJPEG(photoNatural(3000, 2000, seed: 11), dir.appendingPathComponent("photo-a.jpg"), quality: 0.92, gps: true)
        saveJPEG(photoNatural(2400, 1600, seed: 23), dir.appendingPathComponent("photo-b.jpg"), quality: 0.88, gps: true)
        reportPDF(to: dir.appendingPathComponent("report.pdf"), photo: photoNatural(2000, 1040, seed: 5))
        _ = try? runTool(.ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=480x270:rate=15", "-t", "3", dir.appendingPathComponent("anim.gif").path])
        _ = try? runTool(.ffmpeg, ["-y", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=30", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "4",
                                   "-c:v", "libx264", "-crf", "14", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", dir.appendingPathComponent("recording.mov").path])
    }
}
