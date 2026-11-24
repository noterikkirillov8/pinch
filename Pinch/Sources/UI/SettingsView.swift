import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General", images = "Images", video = "Video", privacy = "Privacy", shortcuts = "Shortcuts", tools = "Tools", about = "About"
    var id: String { rawValue }
}

struct SettingsView: View {
    var tab: SettingsTab?
    var tools = ToolPaths.shared
    @AppStorage("settingsTab") private var selection = SettingsTab.general
    var body: some View {
        KitSettings(title: "Settings", tabs: SettingsTab.allCases.map { ($0, $0.rawValue) }, selection: tab.map { .constant($0) } ?? $selection) { selected in
            SettingsPane(tab: selected, tools: tools)
        }
        .minimumScaleFactor(0.78)
        .kitAccent(Color(hex: 0xD97757))
    }
}

struct SettingsPane: View {
    let tab: SettingsTab
    var tools = ToolPaths.shared
    @AppStorage("clipboardOn") var clipboardOn = true
    @AppStorage("watchOn") var watchOn = true
    @AppStorage("floatingOn") var floatingOn = true
    @State private var shortcut = HotKeys.copyTextKey
    @State private var shortcutConflict = false
    @AppStorage("followCursor") var followCursor = true
    @AppStorage("hideFilesAfter") var hideFiles = 30
    @AppStorage("hideClipAfter") var hideClip = 10
    @AppStorage("autoName") var autoName = true
    @AppStorage("preset") var presetName = "identical"
    @AppStorage("webFallback") var webFallback = false
    @AppStorage("stripMetadata") var strip = true
    @AppStorage("preserveDates") var dates = true
    @AppStorage("videoCompat") var videoCompat = false
    @AppStorage("silentAudio") var silentAudio = true
    @AppStorage("dropStrip") var dropStrip = true
    @AppStorage("dropEdge") var dropEdge = "left"
    @State private var cli = CommandLineTool.state
    @AppStorage("capFPS") var capFPS = true
    @AppStorage("targetFPS") var targetFPS = 60
    @AppStorage("removeAudio") var removeAudio = false
    @AppStorage("blurOn") var blurOn = false
    @AppStorage("blurEmail") var blurEmail = true
    @AppStorage("blurKeys") var blurKeys = true
    @AppStorage("blurPhone") var blurPhone = true
    @AppStorage("blurCard") var blurCard = true
    @State private var login = false
    @State private var folder = "Screenshot folder"

    private let hideOptions: [(Int, String)] = [(0, "Never"), (5, "5 s"), (10, "10 s"), (30, "30 s"), (60, "1 min"), (120, "2 min")]

    var body: some View {
        VStack(spacing: KitSpace.l) {
            switch tab {
            case .general:
                KitSection(title: "General") {
                    KitToggleRow(title: "Launch at login", isOn: Binding(get: { login }, set: { login = $0; Core.launchAtLogin = $0 }))
                    KitRow(title: "Copy text shortcut", detail: shortcutConflict ? "That shortcut is already in use" : nil) {
                        KitHotKeyField(hotKey: Binding(get: { shortcut }, set: { key in
                            shortcutConflict = !HotKeys.shared.registerCopyText(key)
                            if shortcutConflict { _ = HotKeys.shared.registerCopyText(shortcut); return }
                            shortcut = key
                            UserDefaults.standard.set(try? JSONEncoder().encode(key), forKey: HotKeys.preference)
                        }))
                    }
                    KitRow(title: "First steps") { Button("Show intro") { IntroController.shared.show() }.buttonStyle(.kitSecondary) }
                }
                KitSoundSection()
                KitSection(title: "Optimise") {
                    KitToggleRow(title: "Clipboard", detail: "Images, videos and PDFs you copy", isOn: $clipboardOn)
                    KitToggleRow(title: "Screenshots and recordings", detail: folder, isOn: $watchOn)
                        .onChange(of: watchOn) { Core.shared.refreshFolder() }
                    KitToggleRow(title: "Rename screenshots", detail: "Use the app name, date and time", isOn: $autoName)
                }
                KitSection(title: "Drop zone", footer: "Drag files or folders onto the menu bar icon, or onto the strip that appears at the screen edge during a drag.") {
                    KitToggleRow(title: "Edge strip", detail: "Shows while you drag files", isOn: $dropStrip)
                        .onChange(of: dropStrip) { DropStrip.shared.refresh() }
                    KitRow(title: "Edge") { KitSelect(selection: $dropEdge, options: [("left", "Left"), ("right", "Right"), ("bottom", "Bottom")]) }
                        .disabled(!dropStrip).opacity(dropStrip ? 1 : 0.5)
                }
                KitSection(title: "Command line", footer: "pinch optimise photo.png --preset chat --to webp") {
                    KitRow(title: "pinch command", detail: cli.detail) {
                        Button(cli.installed ? "Remove" : "Install") { cli = CommandLineTool.toggle() }.buttonStyle(.kitSecondary)
                    }
                }
                KitSection(title: "Floating results") {
                    KitToggleRow(title: "Show results", isOn: $floatingOn)
                    KitToggleRow(title: "Follow the cursor screen", isOn: $followCursor)
                    KitRow(title: "Hide files after") { KitSelect(selection: $hideFiles, options: hideOptions) }
                    KitRow(title: "Hide clipboard results after") { KitSelect(selection: $hideClip, options: hideOptions) }
                }
            case .tools:
                KitSection(title: "Tools") {
                    ForEach(Tool.allCases, id: \.self) { tool in
                        let path = try? tools.executable(tool).path
                        HStack(spacing: 10) {
                            KitLed(on: path != nil)
                            Text(tool.rawValue).font(KitFont.body).foregroundStyle(KitColor.text)
                            if tool == .jpegoptim { Text("Optional").font(KitFont.detail).foregroundStyle(KitColor.text2) }
                            Spacer()
                            Text(path ?? "Missing").font(KitFont.detail).foregroundStyle(KitColor.text2)
                                .lineLimit(1).truncationMode(.middle).help(path ?? "brew install \(tool.formula)")
                        }
                        .padding(.horizontal, KitSpace.m).frame(height: 27)
                        .accessibilityElement(children: .combine)
                    }
                }
                if tools.hasMissing {
                    HStack {
                        Text("Pinch needs these free tools from Homebrew").font(KitFont.detail).foregroundStyle(KitColor.text2)
                        Spacer()
                        Button("Copy install command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ToolPaths.installCommand, forType: .string)
                        }.buttonStyle(.kitSecondary)
                    }
                }
            case .about:
                KitAboutView(name: "Pinch", tagline: "Copy large, paste small.", repoURL: nil, license: "MIT licence", credits: ["Encoders: pngquant, oxipng, mozjpeg, libwebp, libavif, libjxl, gifsicle, ffmpeg, Ghostscript", "Interface sounds by Kenney (kenney.nl), CC0"])
                    .frame(maxWidth: .infinity)
            case .images:
                PresetPicker(selection: Binding(get: { Preset(rawValue: presetName) ?? .identical }, set: { presetName = $0.rawValue }))
                KitSection(title: "Files", footer: "The web preset writes AVIF, or WebP when you prefer it, next to the original. Screenshots and the clipboard keep their format.") {
                    KitToggleRow(title: "Strip metadata", detail: "Removes location and camera data, keeps colour profile", isOn: $strip)
                    KitToggleRow(title: "Keep file dates", isOn: $dates)
                    KitRow(title: "Web format") { KitSelect(selection: $webFallback, options: [(false, "AVIF"), (true, "WebP")]) }
                }
            case .video:
                KitSection(title: "Encoding", footer: "Quality is searched against the preset's SSIM score on sampled frames.") {
                    KitRow(title: "Encoder") { KitSelect(selection: $videoCompat, options: [(false, "HEVC"), (true, "H.264, compatible")]) }
                    KitToggleRow(title: "Remove silent audio", detail: "Screen recordings often carry an empty track", isOn: $silentAudio)
                    KitToggleRow(title: "Remove audio", isOn: $removeAudio)
                }
                KitSection(title: "Frame rate") {
                    KitToggleRow(title: "Cap frame rate", isOn: $capFPS)
                    KitRow(title: "Maximum") { KitStepper(value: $targetFPS, range: 1...120, format: { "\($0) fps" }) }.disabled(!capFPS).opacity(capFPS ? 1 : 0.5)
                }
            case .privacy:
                KitSection(title: "On-device redaction") {
                    KitToggleRow(title: "Experimental: blur private info (may miss things)", detail: "Clipboard images and new screenshots", isOn: $blurOn)
                }
                if blurOn {
                    KitSection(title: "Blur categories", footer: "Vision finds matches on this Mac. Copied text replaces them with •••.") {
                        category("Email addresses", "name@example.com", $blurEmail)
                        category("API keys and tokens", "sk-••••••••••••", $blurKeys)
                        category("Phone numbers", "+1 (202) 555-0142", $blurPhone)
                        category("Card numbers", "4242 4242 4242 4242", $blurCard)
                    }
                }
            case .shortcuts:
                KitSection(title: "Global shortcuts") {
                    KitRow(title: "Optimise clipboard", symbol: "clipboard") { KitKeycaps(keys: "⌃⇧O") }
                    KitRow(title: "Optimise clipboard, harder", symbol: "bolt.horizontal") { KitKeycaps(keys: "⌃⇧A") }
                    KitRow(title: "Optimise clipboard for AI", symbol: "rectangle.compress.vertical") { KitKeycaps(keys: "⌃⇧I") }
                    KitRow(title: "Copy text from image", symbol: "text.viewfinder") { if let shortcut { KitKeycaps(keys: shortcut.display) } else { Text("Not set").font(KitFont.detail) } }
                }
                KitSection(title: "On a result") {
                    KitRow(title: "Compare with the original", detail: "Hold while the pointer is over a result or a menu row", symbol: "square.split.2x1") { KitKeycaps(keys: "Space") }
                }
            }
        }
        .task(id: tab) {
            guard tab == .general else { return }
            let path = await Task.detached { Prefs.screenshotFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }.value
            folder = path; login = Core.launchAtLogin
        }
    }

    private func category(_ title: String, _ example: String, _ selection: Binding<Bool>) -> some View {
        KitRow(title: title, detail: example) { KitCheckbox(isOn: selection).accessibilityLabel(title) }
    }
}

@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private let presentation = PanelPresentation()
    private var closing: Task<Void, Never>?
    func show(tab: SettingsTab? = nil) {
        if let tab { UserDefaults.standard.set(tab.rawValue, forKey: "settingsTab") }
        closing?.cancel()
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
            let host = NSHostingView(rootView: PresentedContent(state: presentation, anchor: .center) { SettingsView() }
                .fixedSize().onGeometryChange(for: CGSize.self) { $0.size } action: { [weak w] size in
                    if let w { resizeWindow(w, content: size, animate: w.isVisible) }
                })
            host.sizingOptions = []; w.contentView = host; w.delegate = self
            resizeWindow(w, content: host.fittingSize, animate: false)
            w.title = "Pinch"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = NSColor(KitColor.window)
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.presentation.shown = true }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        presentation.shown = false; closing?.cancel()
        closing = Task { do { try await Task.sleep(for: .milliseconds(140)); sender.orderOut(nil) } catch {} }
        return false
    }
}
