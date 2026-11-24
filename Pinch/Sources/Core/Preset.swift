import Foundation

enum ImageFormat: String, CaseIterable, Sendable {
    case png, jpeg, webp, avif, heic, jxl, gif
    var ext: String { self == .jpeg ? "jpg" : rawValue }
    init?(name: String) {
        switch name.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        default: self.init(rawValue: name.lowercased())
        }
    }
}

/// What "good enough" means for one job: the SSIM floor the search must respect, the size cap and
/// whether the file may change format.
enum Preset: String, CaseIterable, Identifiable, Sendable {
    case identical, chat, ai, web, lossless
    var id: String { rawValue }

    var title: String {
        switch self {
        case .identical: "Visually identical"
        case .chat: "For chat"
        case .ai: "For AI"
        case .web: "For the web"
        case .lossless: "Lossless"
        }
    }
    var chip: String {
        switch self {
        case .identical: "Identical"
        case .chat: "Chat"
        case .ai: "AI"
        case .web: "Web"
        case .lossless: "Lossless"
        }
    }
    var detail: String {
        switch self {
        case .identical: "Smallest file you cannot tell apart"
        case .chat: "1600 px, WebP when allowed"
        case .ai: "1568 px, PNG or JPEG only"
        case .web: "AVIF or WebP, 98% identical"
        case .lossless: "Same pixels, smaller file"
        }
    }
    /// SSIM the result must reach against the original (1 means bit-exact only).
    var ssim: Double {
        switch self {
        case .identical: 0.985
        case .chat, .ai: 0.97
        case .web: 0.98
        case .lossless: 1
        }
    }
    var maxSide: Int? { self == .chat ? 1600 : self == .ai ? 1568 : nil }
    var lossy: Bool { self != .lossless }
    /// Format change this preset asks for when the caller allows converting.
    func conversion(webFallback: Bool) -> ImageFormat? {
        switch self {
        case .chat: .webp
        case .web: webFallback ? .webp : .avif
        default: nil
        }
    }
    /// Ghostscript image resolution; nil keeps the images as they are.
    var pdfDPI: Int? {
        switch self {
        case .identical: 300
        case .chat, .ai: 150
        case .web: 96
        case .lossless: nil
        }
    }
    /// Quality factor handed to Ghostscript's JPEG encoder (lower is better quality).
    var pdfQFactor: Double { self == .identical ? 0.15 : self == .web ? 0.5 : 0.35 }

    init?(name: String) {
        let n = name.lowercased()
        guard let p = Preset.allCases.first(where: { $0.rawValue == n || $0.chip.lowercased() == n || $0.title.lowercased() == n }) else { return nil }
        self = p
    }
}
