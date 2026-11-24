import AppKit
import AVFoundation
import ImageIO
import PDFKit

struct Boxed<T>: @unchecked Sendable { let v: T }

enum Thumbs {
    static let size = CGSize(width: 300, height: 220)

    /// Thumbnail of an image, video or PDF, about 300x220 at 2x.
    static func make(_ url: URL) async -> Boxed<NSImage>? {
        switch Kind.of(url) {
        case .png, .jpeg, .gif, .webp, .avif, .heic:
            guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary) else { return nil }
            return Boxed(v: NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2)))
        case .video:
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 600, height: 600)
            guard let r = try? await gen.image(at: .zero) else { return nil }
            return Boxed(v: NSImage(cgImage: r.image, size: NSSize(width: r.image.width / 2, height: r.image.height / 2)))
        case .pdf:
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return Boxed(v: page.thumbnail(of: CGSize(width: 400, height: 300), for: .mediaBox))
        case nil: return nil
        }
    }
}
