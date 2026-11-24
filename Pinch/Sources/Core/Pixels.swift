import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO helpers shared by the engine, the SSIM gate and the compare view.
enum Pixels {
    /// Full-size image with the EXIF orientation applied, nil when unreadable.
    static func decode(_ url: URL, index: Int = 0) -> CGImage? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), index < CGImageSourceGetCount(s) else { return nil }
        if index == 0, let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
            return CGImageSourceCreateThumbnailAtIndex(s, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: max(w, h)] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(s, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func frameCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map { CGImageSourceGetCount($0) } ?? 0
    }

    static func orientation(_ url: URL) -> Int {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return 1 }
        return p[kCGImagePropertyOrientation] as? Int ?? 1
    }

    /// True when any pixel is not fully opaque.
    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return true }
        var i = 3
        while i < data.count { if data[i] != 255 { return true }; i += 4 }
        return false
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let ctxSpace = space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: ctxSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        c.interpolationQuality = .high
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return c.makeImage() ?? image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw Failure.other("Could not write a temporary file") }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw Failure.other("Could not write a temporary file") }
    }

    static func isSRGB(_ image: CGImage) -> Bool {
        guard let name = image.colorSpace?.name else { return image.colorSpace == nil }
        return (name as String) == (CGColorSpace.sRGB as String)
    }

    static func toSRGB(_ image: CGImage) -> CGImage {
        guard !isSRGB(image), let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return c.makeImage() ?? image
    }

    static func icc(_ image: CGImage) -> Data? {
        guard !isSRGB(image), let space = image.colorSpace else { return nil }
        return space.copyICCData() as Data?
    }
}
