import AppKit
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One shared window that holds the whole stack: floating level, never activates, hidden from
/// screenshots, anchored to a screen corner.
@MainActor
final class FloatingWindow {
    static let shared = FloatingWindow()
    private var panel: FloatingPanel?
    private var content = CGSize.zero

    func start(_ store: ResultStore) {
        let p = FloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.sharingType = .none          // results do not show up in screenshots
        p.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: FloatingStack(store: store) { size in
            MainActor.assumeIsolated { FloatingWindow.shared.resize(size) }
        })
        host.sizingOptions = []
        p.contentView = host
        panel = p
        store.onChange = { [weak self] in self?.refresh(store) }
        refresh(store)
    }

    private func refresh(_ store: ResultStore) {
        guard let panel else { return }
        if store.items.isEmpty || !Prefs.floatingOn { panel.orderOut(nil); return }
        if !panel.isVisible { place(CGSize(width: 324, height: max(content.height, 220))); panel.orderFrontRegardless() }
    }

    private func resize(_ size: CGSize) {
        content = size
        guard let panel, panel.isVisible, size.width > 0, size.height > 0 else { return }
        place(size)
    }

    /// Screen corner placement: flush with the visible frame.
    private func place(_ size: CGSize) {
        guard let panel else { return }
        let screen = Prefs.followCursor
            ? (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)
            : NSScreen.main
        guard let f = screen?.visibleFrame else { return }
        let x = f.maxX - size.width
        let y = f.minY
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}
