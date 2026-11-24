import AppKit
import SwiftUI

struct MenuView: View {
    var history = History.shared
    var pausedOverride: Bool?
    var highlighted: UUID?
    var sampledPress = false
    var showToolsHint = false
    var presentation: PanelPresentation?
    var onClose: () -> Void = {}
    @AppStorage("paused") private var paused = false
    @State private var message: String?
    @State private var displayed = 0
    @State private var openedTools = false
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let frame = history.frame
        let active = Set(history.active.map(\.id))
        let rows = Array((history.active + frame.rows.filter { !active.contains($0.id) }).prefix(5))
        let stopped = pausedOverride ?? paused
        let shown = presentation?.shown ?? true
        let amount = presentation == nil || reduced ? frame.saved : displayed
        let ratio = frame.input > 0 ? min(1, Double(amount) / Double(frame.input)) : 0
        KitPanel(title: "Pinch", width: 384) {
            KitBadge(text: stopped ? "Paused" : "Watching", lit: !stopped)
                .animation(KitMotion.soft, value: stopped)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Saved \(Self.bytes(amount)) today").font(KitFont.figure(22)).foregroundStyle(KitColor.text)
                        .kitRollingNumber(amount)
                    KitMeter(value: ratio, segments: 32, warn: nil, danger: nil)
                    HStack {
                        Text("Space reclaimed")
                        Spacer()
                        Text("\(Int((ratio * 100).rounded()))% of original size").monospacedDigit().kitRollingNumber(amount)
                    }.font(KitFont.detail).foregroundStyle(KitColor.text2)
                }.padding(16)
                KitDivider()
                HStack {
                    Text("Recent results").font(KitFont.header)
                    Spacer()
                    Text(String(format: "%02d / 05", rows.count)).font(KitFont.figure(10)).kitRollingNumber(rows.count)
                }.foregroundStyle(KitColor.text2).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                if frame.loading && rows.isEmpty {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 7) { Capsule().frame(width: 136, height: 6); Capsule().frame(width: 76, height: 5) }
                    }.foregroundStyle(KitColor.well).padding(16).accessibilityLabel("Loading results")
                } else if rows.isEmpty && frame.problem == nil {
                    KitEmptyState(symbol: "arrow.down.right.and.arrow.up.left", text: stopped ? "Resume to collect new results." : "Copy an image or take a screenshot\nto see your first result.")
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    ReceiptRow(row: row, thumbnail: frame.thumbnails[row.id], highlighted: highlighted == row.id, roll: presentation != nil && shown && !reduced, running: active.contains(row.id)) { action in perform(action, row) }
                        .offset(y: shown || reduced ? 0 : 8).opacity(shown ? 1 : 0)
                        .animation(reduced ? KitMotion.soft : KitMotion.stagger(index), value: shown)
                        .transition(reduced ? .opacity : .kitRow)
                    if row.id != rows.last?.id { KitDivider(inset: 64) }
                }
                if let problem = message ?? frame.problem {
                    Text(problem).font(KitFont.detail).foregroundStyle(KitColor.text2).padding(12)
                        .transition(reduced ? .opacity : .kitBar)
                }
                if showToolsHint && !openedTools {
                    KitDivider()
                    Button {
                        openedTools = true; onClose(); SettingsWindow.shared.show(tab: .tools)
                    } label: {
                        HStack(spacing: 10) {
                            KitLed(on: false)
                            Text("Some tools are missing")
                            Spacer()
                            Text("View tools")
                            Image(systemName: "chevron.right")
                        }.font(KitFont.detail).foregroundStyle(KitColor.text2)
                            .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .animation(reduced ? KitMotion.soft : KitMotion.list, value: rows.map(\.id))
        } footer: {
            HStack(spacing: 0) {
                Button(stopped ? "Resume" : "Pause") { paused.toggle() }.buttonStyle(.kitSecondary)
                    .scaleEffect(sampledPress ? 0.97 : 1).opacity(sampledPress ? 0.85 : 1).keyboardShortcut("p", modifiers: [])
                Button("Show intro") { onClose(); IntroController.shared.show() }.buttonStyle(.kitQuiet)
                Spacer()
                Button("Settings") { onClose(); SettingsWindow.shared.show() }.buttonStyle(.kitQuiet).keyboardShortcut(",")
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.kitQuiet).keyboardShortcut("q")
            }
        }
        .kitAccent(Color(hex: 0xD97757))
        .task(id: shown ? frame.saved : -1) {
            guard presentation != nil, shown, !reduced else { displayed = 0; return }
            let start = displayed
            for step in 1...6 {
                guard !Task.isCancelled else { return }
                displayed = start + Int(Double(frame.saved - start) * Double(step) / 6)
                try? await Task.sleep(for: .milliseconds(85))
            }
        }
    }

    static func bytes(_ count: Int) -> String {
        if count == 0 { return "0 KB" }
        return Int64(count).formatted(.byteCount(style: .decimal, allowedUnits: [.bytes, .kb, .mb, .gb], spellsOutZero: false)).replacingOccurrences(of: "kB", with: "KB")
    }

    private func perform(_ action: ReceiptAction, _ row: Receipt) {
        Task {
            do {
                let url = try await Task.detached {
                    let fm = FileManager.default
                    guard action == .restore else {
                        guard fm.isReadableFile(atPath: row.output.path) else { throw CocoaError(.fileReadNoSuchFile) }
                        return row.output
                    }
                    let base = row.output.deletingPathExtension()
                    for index in 1...100 {
                        let suffix = index == 1 ? "" : " \(index)"
                        let result = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) (original\(suffix)).\(row.output.pathExtension)")
                        do { try fm.copyItem(at: row.original, to: result); return result }
                        catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
                    }
                    throw CocoaError(.fileWriteFileExists)
                }.value
                if action == .copy {
                    let item = Item(name: row.name, ext: url.pathExtension, source: .file)
                    item.dest = url; Core.shared.copyToClipboard(item)
                } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                message = nil; onClose()
            } catch { message = action == .restore ? "Could not restore the backup as a new file." : "This result is no longer available at its saved location." }
        }
    }
}

enum ReceiptAction: Sendable { case copy, reveal, restore }

struct ReceiptRow: View {
    let row: Receipt
    let thumbnail: CGImage?
    let highlighted: Bool
    var roll = false
    var running = false
    let action: (ReceiptAction) -> Void
    @State private var hovered = false
    @State private var animatedSize: Int?
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.displayScale) private var scale

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                KitColor.raised
                if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFill() }
                else { Image(systemName: "doc").foregroundStyle(KitColor.text2) }
            }.frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(KitColor.line, lineWidth: 1 / scale))
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1).truncationMode(.middle)
                let count = roll ? animatedSize ?? row.before : row.after
                Text(running ? "\(MenuView.bytes(row.before)) · Optimising" : "\(MenuView.bytes(row.before)) to \(MenuView.bytes(count))").font(KitFont.figure(10)).foregroundStyle(KitColor.text2).lineLimit(1).kitRollingNumber(count)
            }
            Spacer(minLength: 0)
            if running { KitLed() }
            else if hovered || highlighted {
                HStack(spacing: 2) {
                    KitIconButton(symbol: "doc.on.doc", help: "Copy result", outlined: true) { action(.copy) }
                    KitIconButton(symbol: "folder", help: "Reveal in Finder", outlined: true) { action(.reveal) }
                    KitIconButton(symbol: "arrow.uturn.backward", help: "Restore original as a separate file", outlined: true) { action(.restore) }
                }.transition(reduced ? .opacity : .opacity.combined(with: .offset(x: 4)))
            } else { Text("\(row.percent)%").font(KitFont.figure(15)).foregroundStyle(KitColor.text).kitRollingNumber(row.percent) }
        }
        .padding(.horizontal, 16).frame(height: 52).background(hovered || highlighted ? KitColor.well : Color.clear)
        .contentShape(Rectangle()).onHover { value in
            withAnimation(KitMotion.soft) { hovered = value }
            Compare.shared.hover(src: row.original, dest: row.output, ssim: nil, on: value && !running)
        }
        .task(id: roll ? row.after : -1) {
            guard roll && !running else { animatedSize = nil; return }
            let start = animatedSize ?? row.before
            for step in 1...5 {
                guard !Task.isCancelled else { return }
                animatedSize = start + Int(Double(row.after - start) * Double(step) / 5)
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
        .dragOut(!running, image: thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }, size: MenuView.bytes(row.after)) { row.output }
        .accessibilityActions {
            if !running {
                Button("Copy result") { action(.copy) }
                Button("Reveal in Finder") { action(.reveal) }
                Button("Restore original as a separate file") { action(.restore) }
            }
        }
    }
}

@MainActor final class MenuPanel: NSObject {
    static let shared = MenuPanel()
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { MenuPanel.shared.close() }
    }
    private let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var monitors: [Any] = []
    private var firstFrame: CADisplayLink?
    private var opened = 0.0
    private let state = PanelPresentation()
    private var closing: Task<Void, Never>?

    override init() {
        super.init()
        let showToolsHint = ToolPaths.shared.firstLaunchHint(defaults: .standard)
        let host = NSHostingView(rootView: PresentedContent(state: state) {
            MenuView(showToolsHint: showToolsHint, presentation: self.state, onClose: { [weak self] in self?.close() })
        }.fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in self?.resize(size) })
        host.sizingOptions = []
        panel.contentView = host
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.sharingType = .none; panel.acceptsMouseMovedEvents = true
        resize(host.fittingSize); host.layoutSubtreeIfNeeded()
    }

    private func resize(_ size: CGSize) {
        resizeWindow(panel, content: size, animate: state.shown)
    }

    func toggle(from button: NSStatusBarButton) {
        if state.shown { close(); return }
        closing?.cancel()
        opened = ProcessInfo.processInfo.systemUptime
        guard let window = button.window, let screen = window.screen else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let x = min(max(anchor.midX - panel.frame.width / 2, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - panel.frame.width - 8)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: anchor.minY - 4))
        panel.orderFrontRegardless(); panel.makeKey()
        state.shown = true
        if Perf.enabled {
            firstFrame = panel.displayLink(target: self, selector: #selector(didDisplay))
            firstFrame?.add(to: .main, forMode: .common)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in MainActor.assumeIsolated { MenuPanel.shared.close() } }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self, weak window] event in
            if event.window !== self?.panel && event.window !== window { self?.close() }; return event
        }) { monitors.append(monitor) }
    }

    @objc private func didDisplay() {
        Perf.log("click to first display refresh", since: opened)
        firstFrame?.invalidate(); firstFrame = nil
    }

    func close() {
        state.shown = false
        closing?.cancel()
        closing = Task {
            do { try await Task.sleep(for: .milliseconds(140)); panel.orderOut(nil) } catch {}
        }
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        firstFrame?.invalidate(); firstFrame = nil
    }
}

@MainActor func resizeWindow(_ window: NSWindow, content: CGSize, animate: Bool) {
    guard content.width > 0, content.height > 0 else { return }
    let size = window.frameRect(forContentRect: CGRect(origin: .zero, size: content)).size
    guard size != window.frame.size else { return }
    let rect = CGRect(x: window.frame.minX, y: window.frame.maxY - size.height, width: size.width, height: size.height)
    if animate && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28; context.allowsImplicitAnimation = true; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(rect, display: true)
        }
    } else { window.setFrame(rect, display: window.isVisible) }
}
