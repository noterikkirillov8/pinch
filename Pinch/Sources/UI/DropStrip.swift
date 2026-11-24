import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DropModel {
    var expanded = false
    var hover: Preset?
    var edge = "left"
}

/// What the strip shows: a lit lip on the screen edge that opens into the five presets.
struct DropStripView: View {
    var model: DropModel
    @Environment(\.accessibilityReduceMotion) private var reduced
    private let accent = Color(hex: 0xD97757)

    var body: some View {
        let lip = lipPosition
        ZStack(alignment: lip) {
            RoundedRectangle(cornerRadius: 12).fill(KitColor.window)
            RoundedRectangle(cornerRadius: 12).strokeBorder(KitColor.line, lineWidth: 1)
            VStack(alignment: .leading, spacing: 0) {
                Text("Drop to optimise").font(KitFont.header).foregroundStyle(KitColor.text2).padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 8)
                ForEach(Preset.allCases) { preset in
                    let on = (model.hover ?? Prefs.preset) == preset
                    HStack(spacing: 10) {
                        KitLed(on: on, size: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset.title).font(KitFont.body).foregroundStyle(KitColor.text)
                            Text(preset.detail).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(model.hover == preset ? KitColor.raised : .clear)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, lip == .trailing ? 0 : (lip == .leading ? 8 : 0)).padding(.trailing, lip == .trailing ? 8 : 0).padding(.top, lip == .top ? 8 : 0)
            .opacity(model.expanded ? 1 : 0.0)
            lipBar(lip)
        }
        .foregroundStyle(KitColor.text).kitAccent(accent)
        .frame(width: DropStrip.size.width, height: DropStrip.size.height)
        .animation(reduced ? nil : KitMotion.soft, value: model.expanded)
        .animation(KitMotion.soft, value: model.hover)
    }

    private var lipPosition: Alignment { model.edge == "right" ? .leading : model.edge == "bottom" ? .top : .trailing }

    @ViewBuilder private func lipBar(_ lip: Alignment) -> some View {
        let vertical = lip == .leading || lip == .trailing
        RoundedRectangle(cornerRadius: 2).fill(accent)
            .frame(width: vertical ? 4 : 120, height: vertical ? 120 : 4)
            .padding(2)
    }
}

/// Appears while files are being dragged anywhere on the Mac, on the chosen screen edge, and opens
/// into the five presets when the pointer reaches it. Pure mouse monitoring: no permission needed.
@MainActor
final class DropStrip {
    static let shared = DropStrip()
    static let size = CGSize(width: 252, height: 14 + 22 + 5 * 44 + 8)
    static let lip: CGFloat = 8
    let model = DropModel()
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var baseline = 0
    private var dragging = false
    private let drag = NSPasteboard(name: .drag)

    func refresh() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        hide()
        guard Prefs.dropStrip else { return }
        let add: (NSEvent.EventTypeMask, @escaping @MainActor () -> Void) -> Void = { mask, handler in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in MainActor.assumeIsolated { handler() } }) { self.monitors.append(m) }
        }
        add(.leftMouseDown) { self.baseline = self.drag.changeCount; self.end() }
        add(.leftMouseDragged) { self.dragged() }
        add(.leftMouseUp) { self.end() }
    }

    private func dragged() {
        guard !dragging, drag.changeCount != baseline, drag.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        dragging = true
        show()
    }

    private func end() {
        guard dragging else { return }
        dragging = false
        // A drop onto the strip runs before the mouse-up monitor, so hiding here is safe.
        hide()
    }

    private func screen() -> NSScreen? { NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main }

    func frame(on screen: NSScreen, expanded: Bool) -> NSRect {
        let f = screen.visibleFrame, s = Self.size
        switch model.edge {
        case "right": return NSRect(x: expanded ? f.maxX - s.width : f.maxX - Self.lip, y: f.midY - s.height / 2, width: s.width, height: s.height)
        case "bottom": return NSRect(x: f.midX - s.width / 2, y: expanded ? f.minY : f.minY - s.height + Self.lip, width: s.width, height: s.height)
        default: return NSRect(x: expanded ? f.minX : f.minX - s.width + Self.lip, y: f.midY - s.height / 2, width: s.width, height: s.height)
        }
    }

    private func make() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .statusBar; p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none
        let host = NSHostingView(rootView: DropStripView(model: model))
        host.sizingOptions = []
        let view = DropTarget(frame: NSRect(origin: .zero, size: Self.size), model: model)
        host.frame = view.bounds; host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        p.contentView = view
        return p
    }

    private func show() {
        guard let screen = screen() else { return }
        model.edge = Prefs.dropEdge; model.expanded = false; model.hover = nil
        let p = panel ?? make()
        panel = p
        p.setFrame(frame(on: screen, expanded: false), display: true)
        p.orderFrontRegardless()
    }

    func hide() {
        model.expanded = false; model.hover = nil
        panel?.orderOut(nil)
    }

    fileprivate func setExpanded(_ on: Bool) {
        guard let panel, let screen = panel.screen ?? screen() else { return }
        model.expanded = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame(on: screen, expanded: on), display: true)
        }
    }
}

/// The panel's content view: accepts the drop and tells the strip which preset row is under the pointer.
final class DropTarget: NSView {
    let model: DropModel
    init(frame: NSRect, model: DropModel) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { nil }

    private func row(_ info: NSDraggingInfo) -> Preset? {
        let p = convert(info.draggingLocation, from: nil)
        let index = Int((bounds.height - p.y - 36) / 44)   // header 36 pt, then 44 pt rows from the top
        return Preset.allCases.indices.contains(index) && model.expanded ? Preset.allCases[index] : nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { DropStrip.shared.setExpanded(true); model.hover = row(sender) }
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated { model.hover = row(sender) }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated { DropStrip.shared.setExpanded(false) }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        MainActor.assumeIsolated {
            let preset = model.hover
            DropStrip.shared.hide()
            Core.shared.optimiseDropped(urls, preset: preset)
        }
        return true
    }
}

/// Drop target laid over the menu bar button; clicks still reach the button.
final class StatusDropView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { (superview as? NSStatusBarButton)?.performClick(nil) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        MainActor.assumeIsolated { Core.shared.optimiseDropped(urls) }
        return true
    }
}
