import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Drag a result out of Pinch: one file URL plus image data, so file targets (Finder, upload fields,
/// chats, Ledge) and image targets both accept it.
enum Drag {
    static var dir: URL { Paths.sub("drag") }

    /// Pasteboard types for a file: the file URL, then the image as its own format, PNG and TIFF.
    static func types(_ url: URL) -> [NSPasteboard.PasteboardType] {
        var t: [NSPasteboard.PasteboardType] = [.fileURL]
        guard Kind.of(url)?.isImage == true else { return t }
        if let own = UTType(filenameExtension: url.pathExtension.lowercased()), own != .png { t.append(NSPasteboard.PasteboardType(own.identifier)) }
        return t + [.png, .tiff]
    }

    static func data(_ url: URL, _ type: NSPasteboard.PasteboardType) -> Data? {
        if type == .fileURL { return url.dataRepresentation }
        guard let raw = try? Data(contentsOf: url) else { return nil }
        if type == .png, url.pathExtension.lowercased() == "png" { return raw }
        if type.rawValue == UTType(filenameExtension: url.pathExtension.lowercased())?.identifier, type != .png, type != .tiff { return raw }
        guard let rep = NSBitmapImageRep(data: raw) else { return nil }
        return rep.representation(using: type == .png ? .png : .tiff, properties: [:])
    }

    static func pasteboardItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        for t in types(url) { if let d = data(url, t) { item.setData(d, forType: t) } }
        return item
    }

    /// Lazy provider for SwiftUI's onDrag: data is read only when the target asks for it.
    static func provider(_ url: URL) -> NSItemProvider {
        let p = NSItemProvider()
        for t in types(url) {
            p.registerDataRepresentation(forTypeIdentifier: t.rawValue, visibility: .all) { done in done(data(url, t), nil); return nil }
        }
        p.suggestedName = url.deletingPathExtension().lastPathComponent
        return p
    }

    /// The file to drag. Clipboard results live in an id-named cache folder; copy them to
    /// `drag/<name>.<ext>` so the dropped file has the readable name.
    @MainActor static func file(for item: Item) -> URL? {
        guard let dest = item.dest, FileManager.default.fileExists(atPath: dest.path) else { return nil }
        guard item.source == .clipboard else { return dest }
        let ext = dest.pathExtension
        let name = (item.name.isEmpty ? "Pinch" : item.name).replacingOccurrences(of: "/", with: "-")
        let out = dir.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
        if out == dest { return dest }
        try? FileManager.default.removeItem(at: out)
        return (try? FileManager.default.copyItem(at: dest, to: out)) != nil ? out : dest
    }

    /// On launch: move staged drag files older than a day to the Trash.
    static func cleanup(in folder: URL? = nil, olderThan age: TimeInterval = 86400, now: Date = Date()) {
        let fm = FileManager.default, d = folder ?? dir
        for u in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, now.timeIntervalSince(m) > age {
                try? fm.trashItem(at: u, resultingItemURL: nil)
            }
        }
    }
}

/// The drag image: the thumbnail at 60% size with the size figure.
struct DragPreview: View {
    let image: NSImage?
    let size: String
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) } else { KitColor.well }
            Text(size).font(KitFont.figure(12, .semibold)).foregroundStyle(KitColor.text)
                .padding(.horizontal, 6).padding(.vertical, 2).background(KitColor.window, in: RoundedRectangle(cornerRadius: 4)).padding(4)
        }.frame(width: 170, height: 65).clipShape(RoundedRectangle(cornerRadius: 4)).environment(\.colorScheme, .dark)
    }
}

extension View {
    /// Makes the view a drag source for `file` (a click still passes through to tap gestures).
    @ViewBuilder func dragOut(_ on: Bool, image: NSImage?, size: String, file: @escaping () -> URL?) -> some View {
        if on { onDrag { file().map(Drag.provider) ?? NSItemProvider() } preview: { DragPreview(image: image, size: size) } } else { self }
    }
}
