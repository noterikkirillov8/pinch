import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor @Observable
final class CompareModel {
    var before: NSImage?
    var after: NSImage?
    var oldBytes = 0
    var newBytes = 0
    var ssim: Double?
    var title = ""
    var split = 0.5
}

/// Before and after with a draggable split line: the original on the left, the result on the right.
struct CompareView: View {
    var model: CompareModel
    var onClose: () -> Void = {}
    @State private var dragging = false
    private let accent = Color(hex: 0xD97757)

    private var saved: Int { max(0, 100 - Int((100 * Double(model.newBytes) / Double(max(1, model.oldBytes))).rounded())) }

    var body: some View {
        VStack(spacing: 12) {
            header
            stage
            HStack {
                Text("Hold Space to compare. Drag the line.").font(KitFont.detail).foregroundStyle(KitColor.text3)
                Spacer()
                if let ssim = model.ssim {
                    KitBadge(text: String(format: "%.1f%% identical", ssim * 100), color: accent)
                }
            }
        }
        .padding(16).frame(width: 760, height: 560).background(KitColor.window)
        .foregroundStyle(KitColor.text).kitAccent(accent)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Original").font(KitFont.detail).foregroundStyle(KitColor.text2)
                Text(MenuView.bytes(model.oldBytes)).font(KitFont.figure(22, .semibold)).kitRollingNumber(model.oldBytes)
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(model.title).font(KitFont.bodyMedium).lineLimit(1).truncationMode(.middle)
                Text(saved > 0 ? "\(saved)% smaller" : "Same size").font(KitFont.detail).foregroundStyle(KitColor.text2)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("Pinch").font(KitFont.detail).foregroundStyle(accent)
                Text(MenuView.bytes(model.newBytes)).font(KitFont.figure(22, .semibold)).kitRollingNumber(model.newBytes)
            }
            KitIconButton(symbol: "xmark", help: "Close compare", action: onClose).padding(.leading, 4)
        }
    }

    private var stage: some View {
        GeometryReader { geo in
            let w = geo.size.width, x = w * model.split
            ZStack(alignment: .leading) {
                KitColor.well
                if let before = model.before { Image(nsImage: before).resizable().aspectRatio(contentMode: .fit).frame(width: w, height: geo.size.height) }
                if let after = model.after {
                    Image(nsImage: after).resizable().aspectRatio(contentMode: .fit).frame(width: w, height: geo.size.height)
                        .mask(alignment: .trailing) { Rectangle().frame(width: max(0, w - x)) }
                }
                Rectangle().fill(KitColor.text).frame(width: 1).offset(x: x)
                handle.offset(x: x - 14)
                label("Original").position(x: 46, y: 18).opacity(x > 100 ? 1 : 0)
                label("Pinch").position(x: w - 38, y: 18).opacity(w - x > 90 ? 1 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(KitColor.line, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                dragging = true
                model.split = min(1, max(0, v.location.x / max(1, w)))
            }.onEnded { _ in dragging = false })
        }
    }

    private var handle: some View {
        HStack(spacing: 2) { ForEach(0 ..< 3, id: \.self) { _ in Rectangle().frame(width: 1, height: 10) } }
            .foregroundStyle(KitColor.text2)
            .frame(width: 28, height: 28)
            .background(KitColor.raised, in: RoundedRectangle(cornerRadius: KitSpace.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(KitColor.line, lineWidth: 1))
            .scaleEffect(dragging ? 0.94 : 1).animation(KitMotion.snap, value: dragging)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(KitFont.detail).padding(.horizontal, 8).padding(.vertical, 3)
            .background(KitColor.window, in: Capsule())
    }
}

/// Holds the compare panel and the Space key. Space is only claimed while the pointer is over a
/// finished image result (a card or a menu row), so nothing else loses it.
@MainActor
final class Compare {
    static let shared = Compare()
    private static let keyID: UInt32 = 20
    let model = CompareModel()
    private var panel: NSPanel?
    private var target: (src: URL, dest: URL, ssim: Double?)?
    private var pressedAt = Date.distantPast
    private(set) var visible = false

    func hover(src: URL?, dest: URL?, ssim: Double?, on: Bool) {
        if on, let src, let dest, Kind.of(dest)?.isImage == true, Kind.of(src)?.isImage == true {
            target = (src, dest, ssim)
            HotKeys.shared.register(Self.keyID, .init(keyCode: UInt32(kVK_Space), modifiers: 0), release: { Compare.shared.released() }) { Compare.shared.pressed() }
        } else if !on {
            target = nil
            if !visible { HotKeys.shared.unregister(Self.keyID) }
        }
    }

    private func pressed() {
        if visible { close(); return }
        guard let t = target else { return }
        pressedAt = Date()
        present(src: t.src, dest: t.dest, ssim: t.ssim)
    }

    private func released() {
        // A long hold behaves like Quick Look and closes on release; a tap leaves it open.
        if visible, Date().timeIntervalSince(pressedAt) > 0.35 { close() }
    }

    func present(src: URL, dest: URL, ssim: Double?) {
        Task {
            let images = await Task.detached { (Compare.load(src), Compare.load(dest)) }.value
            guard let before = images.0, let after = images.1 else { return }
            model.before = before.v; model.after = after.v
            model.oldBytes = fileSize(src); model.newBytes = fileSize(dest)
            model.title = dest.lastPathComponent; model.split = 0.5; model.ssim = ssim
            show()
            if ssim == nil {
                let score = await Task.detached { SSIM.score(original: src, candidate: dest)?.mean }.value
                model.ssim = score
            }
        }
    }

    nonisolated static func load(_ url: URL) -> Boxed<NSImage>? {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(s, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                  kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) else { return nil }
        return Boxed(v: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
    }

    private func show() {
        let p = panel ?? makePanel()
        panel = p
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let size = p.frame.size
            p.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2))
        }
        p.orderFrontRegardless()
        visible = true
    }

    func close() {
        panel?.orderOut(nil)
        visible = false
        if target == nil { HotKeys.shared.unregister(Self.keyID) }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CompareView(model: model) { Compare.shared.close() })
        host.sizingOptions = []
        host.wantsLayer = true; host.layer?.cornerRadius = 14; host.layer?.masksToBounds = true
        p.contentView = host
        return p
    }
}
