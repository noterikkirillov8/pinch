// Draws Pinch's flat app icon (no gradients) into the asset catalog.  swiftc -O scripts/make-icon.swift -o /tmp/mk && /tmp/mk
import AppKit

let set = "Pinch/Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    NSColor(srgbRed: 0.27, green: 0.28, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s).fill()
    NSColor(srgbRed: 0.14, green: 0.15, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 118*s, y: 118*s, width: 788*s, height: 788*s), xRadius: 170*s, yRadius: 170*s).fill()
    NSColor(srgbRed: 0.90, green: 0.90, blue: 0.88, alpha: 1).setStroke()
    func arrow(from a: CGPoint, to b: CGPoint, head: CGPoint, head2: CGPoint) {
        let p = NSBezierPath()
        p.lineWidth = 78 * s; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: CGPoint(x: a.x * s, y: a.y * s)); p.line(to: CGPoint(x: b.x * s, y: b.y * s))
        p.move(to: CGPoint(x: head.x * s, y: head.y * s)); p.line(to: CGPoint(x: b.x * s, y: b.y * s)); p.line(to: CGPoint(x: head2.x * s, y: head2.y * s))
        p.stroke()
    }
    // Two arrows pressing toward the centre.
    arrow(from: CGPoint(x: 300, y: 724), to: CGPoint(x: 462, y: 562), head: CGPoint(x: 340, y: 562), head2: CGPoint(x: 462, y: 684))
    NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1).setStroke()
    arrow(from: CGPoint(x: 724, y: 300), to: CGPoint(x: 562, y: 462), head: CGPoint(x: 684, y: 462), head2: CGPoint(x: 562, y: 340))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(pt)x\(pt)@\(scale)x.png"
    try! draw(pt * scale).write(to: URL(fileURLWithPath: "\(set)/\(name)"))
    images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(set)/Contents.json"))
try! #"{"info":{"version":1,"author":"xcode"}}"#.write(toFile: "Pinch/Resources/Assets.xcassets/Contents.json", atomically: true, encoding: .utf8)
