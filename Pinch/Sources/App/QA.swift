import AppKit
import PDFKit
import SwiftUI

/// `Pinch -qa <dir>`: renders the real SwiftUI views to PNGs (dark mode) and quits.
/// Needs no Screen Recording permission because it draws the views itself.
@MainActor
enum QA {
    static var backgroundOnly: Bool {
        NSApp.activationPolicy() == .prohibited || (NSApp.activationPolicy().rawValue < 0 && Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true)
    }
    static func runIfAsked() -> Bool {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(where: { $0 == "-qa" || $0 == "-intro-preview" }) else { return false }
        guard backgroundOnly else { exit(64) }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { NSApp.applicationIconImage = NSImage(contentsOf: url) }
        let path = a.dropFirst(i + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "qa"
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if a[i] == "-qa", a.contains("-privacy-only") {
            settingsSnapshot(SettingsView(tab: .privacy), to: dir.appendingPathComponent("10-settings-privacy-disabled.png"))
            return true
        }
        UserDefaults.standard.setVolatileDomain(["blurOn": true], forName: UserDefaults.argumentDomain)
        if a[i] == "-qa" {
            renderTools(dir)
            if a.contains("-tools-only") {
                precondition(NSApp.windows.allSatisfy { !$0.isVisible })
                return true
            }
        }
        let demo = IntroDemo()
        for scene in TourScene.allCases {
            for (name, progress) in [("start", 0.0), ("middle", 0.5), ("end", 1.0)] {
                snapshot(IntroView(demo: demo, model: IntroModel(scene: scene, progress: progress)), to: dir.appendingPathComponent("11-intro-\(scene.rawValue + 1)-\(name).png"))
            }
        }
        if a[i] == "-qa" {
            render(dir)
            if a.contains("-check-handoff") { checkHandoff() }
        }
        precondition(NSApp.windows.allSatisfy { !$0.isVisible })
        return true
    }

    static func snapshot<V: View>(_ view: V, to url: URL, scheme: ColorScheme = .dark) {
        print("Rendering \(url.lastPathComponent)")
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.fixedSize().background(Color(white: scheme == .dark ? 0.21 : 0.83)).environment(\.displayScale, 2).environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Could not render \(url.lastPathComponent)") }
            do { try data.write(to: url, options: .atomic) } catch { fatalError("\(url): \(error)") }
        }
    }

    static func render(_ dir: URL) {
        renderPanels(dir)
        let photo = landscapeProof()
        let blurred = IntroDemo().privateImage
        func stack(_ items: [Item], hover: Bool = false) -> some View {
            let s = ResultStore(); s.items = items
            return FloatingStack(store: s, forceHover: hover ? Set(items.map(\.id)) : [])
        }
        func file(_ n: String) -> URL { dir.appendingPathComponent(n) }

        let running = IntroDemo.item("Safari 2026-11-20 at 14.03.21", "png", photo, old: 3_412_000, new: 0, from: CGSize(width: 3024, height: 1964), state: .running("Optimising"))
        snapshot(stack([running]), to: file("01-floating-optimising.png"))

        let done = IntroDemo.item("Safari 2026-11-20 at 14.03.21", "png", photo, old: 3_412_000, new: 811_000, from: CGSize(width: 3024, height: 1964))
        done.ssim = 0.9911
        snapshot(stack([done]), to: file("02-floating-done.png"))
        snapshot(stack([done], hover: true), to: file("03-floating-hover-buttons.png"))

        let ai = IntroDemo.item("Clipboard", "png", photo, old: 5_600_000, new: 640_000, from: CGSize(width: 3024, height: 1964), to: CGSize(width: 1568, height: 1018), clipboard: true)
        ai.opts.preset = .ai; ai.ssim = 0.9704
        snapshot(stack([ai]), to: file("04-floating-ai-size.png"))

        let hid = IntroDemo.item("Clipboard", "png", blurred, old: 190_000, new: 88_000, from: CGSize(width: blurred.width, height: blurred.height), clipboard: true)
        hid.hidden = 2
        snapshot(stack([hid]), to: file("05-floating-2-hidden.png"))
        snapshot(stack([hid], hover: true), to: file("06-floating-2-hidden-hover.png"))

        let text = Item(name: "Text", ext: "txt", source: .clipboard)
        text.state = .done; text.textLines = 12; text.textPreview = "Contact: •••"
        snapshot(stack([text]), to: file("07-floating-text-copied.png"))

        let video = IntroDemo.item("Screen Recording 2026-11-20 at 14.20.05", "mov", artwork(1, scale: 10), old: 52_400_000, new: 31_200_000, from: CGSize(width: 2560, height: 1440))
        let note = IntroDemo.item("Clipboard", "png", photo, old: 40_000, new: 40_000, from: CGSize(width: 800, height: 600), clipboard: true, state: .notice("Already optimised"))
        snapshot(stack([running, done, video, note]), to: file("08-stack-of-3-plus.png"))
        snapshot(stack([running, done, video]), to: file("08-stack-of-3.png"))
        let demo = IntroDemo()
        let landscape = IntroDemo.item("Alpine field notes", "png", photo, old: 2_400_000, new: 610_000, from: CGSize(width: 3024, height: 1964))
        func card(_ name: String, _ item: Item, _ sample: PinchFrame? = nil, hover: Bool = false, scheme: ColorScheme = .dark) {
            snapshot(FloatingCard(item: item, store: demo.store, forceHover: hover, sample: sample).padding(12), to: file("card-\(name).png"), scheme: scheme)
        }
        let cardTuple: (String, Item, PinchFrame?, Bool, ColorScheme) -> Void = { card($0, $1, $2, hover: $3, scheme: $4) }
        card("optimising-start", landscape, .step(0, from: landscape.oldBytes, to: landscape.newBytes))
        card("optimising-mid", landscape, .step(5, from: landscape.oldBytes, to: landscape.newBytes))
        card("done", landscape); card("light", landscape, scheme: .light); card("hover-keys", landscape, hover: true)
        card("2-hidden", demo.redacted); card("2-hidden-hover", demo.redacted, hover: true)
        let failed = Item(name: "Damaged scan.png", ext: "png", source: .file); failed.state = .failed("Could not read this file")
        card("error", failed); card("video", video)
        let missing = Item(name: "Field sketch", ext: "png", source: .file); missing.state = Core.failedState(for: Failure.missingTool("pngquant"))
        card("missing-encoder", missing)
        let pdf = IntroDemo.item("Coastal survey", "pdf", demo.image, old: 5_200_000, new: 1_400_000, from: CGSize(width: 612, height: 792))
        let document = PDFDocument()
        document.insert(PDFPage(image: pdf.thumb!)!, at: 0)
        pdf.thumb = document.page(at: 0)!.thumbnail(of: CGSize(width: 600, height: 456), for: .mediaBox)
        card("pdf", pdf)
        snapshot(stack([landscape, pdf, video]), to: file("card-stack-of-3.png"))
        renderFeatures(dir, photo: photo, card: cardTuple)
        for tab in [SettingsTab.general, .about] { settingsSnapshot(SettingsView(tab: tab), to: file("settings-\(tab.rawValue.lowercased()).png")) }
    }

    /// Presets, compare, drop strip and batch progress.
    private static func renderFeatures(_ dir: URL, photo: CGImage, card: (String, Item, PinchFrame?, Bool, ColorScheme) -> Void) {
        func file(_ n: String) -> URL { dir.appendingPathComponent(n) }
        let chat = IntroDemo.item("Alpine field notes", "jpg", photo, old: 2_400_000, new: 410_000, from: CGSize(width: 3024, height: 1964), to: CGSize(width: 1600, height: 1039))
        chat.opts.preset = .chat; chat.ssim = 0.9712
        card("preset-chip-chat", chat, nil, false, .dark); card("preset-chip-chat-hover", chat, nil, true, .dark)
        let lossless = IntroDemo.item("Boarding pass", "png", photo, old: 640_000, new: 512_000, from: CGSize(width: 1170, height: 2532))
        lossless.opts.preset = .lossless; lossless.ssim = 1
        card("preset-chip-lossless", lossless, nil, false, .dark)
        let batch = Item(name: "12 files", ext: "", source: .file)
        batch.batch = Batch(done: 7, total: 12); batch.state = .running("Optimising 7 of 12"); batch.oldBytes = 18_400_000; batch.newBytes = 7_900_000
        card("batch-running", batch, nil, false, .dark)
        let finished = Item(name: "12 files", ext: "", source: .file)
        finished.batch = Batch(done: 12, total: 12); finished.state = .done; finished.oldBytes = 31_200_000; finished.newBytes = 11_800_000
        card("batch-done", finished, nil, false, .dark)

        // Compare
        let tmp = dir.appendingPathComponent("compare-after.jpg")
        Samples.saveJPEG(photo, tmp, quality: 0.5, gps: false)
        let model = CompareModel()
        model.before = NSImage(cgImage: photo, size: NSSize(width: photo.width, height: photo.height))
        model.after = Engine.decode(tmp).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        try? FileManager.default.removeItem(at: tmp)
        model.oldBytes = 2_400_000; model.newBytes = 610_000; model.ssim = 0.9912; model.title = "Alpine field notes.png"
        snapshot(CompareView(model: model), to: file("compare-view.png"))
        model.split = 0.28
        snapshot(CompareView(model: model), to: file("compare-view-left.png"))
        snapshot(CompareView(model: model), to: file("compare-view-light.png"), scheme: .light)

        // Drop strip: open with a preset under the pointer, and the lip as it sits on the screen edge.
        let drop = DropModel(); drop.expanded = true; drop.hover = .chat
        snapshot(DropStripView(model: drop).padding(12), to: file("drop-strip-open.png"))
        let lip = DropModel(); lip.expanded = false
        snapshot(ZStack(alignment: .leading) {
            Color(hex: 0x2A2B2E)
            RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x3A3B3F)).frame(width: 300, height: 190).offset(x: 90, y: -30)
            DropStripView(model: lip).offset(x: -(DropStrip.size.width - DropStrip.lip))
        }.frame(width: 480, height: 300).clipped(), to: file("drop-strip-edge.png"))

        // Preset picker
        settingsSnapshot(PresetPicker(selection: .constant(.chat)).padding(20).frame(width: 520).background(KitColor.window).kitAccent(Color(hex: 0xD97757)), to: file("preset-picker.png"))
    }

    private static func renderPanels(_ dir: URL) {
        func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
        let history = History()
        let samples: [(String, Int, Int)] = [("Alpine field notes.png", 2_400_000, 610_000), ("Studio walkthrough.mov", 265_000_000, 64_000_000), ("Type specimens.pdf", 5_200_000, 1_400_000), ("Coastline study.jpg", 8_400_000, 2_100_000), ("Palette proof.png", 1_600_000, 490_000)]
        let frames = samples.enumerated().map { index, sample in
            let url = dir.appendingPathComponent(sample.0)
            let receipt = Receipt(id: UUID(), date: .now, name: sample.0, before: sample.1, after: sample.2, output: url, original: url)
            return (receipt, artwork(index))
        }
        let full = HistoryFrame(rows: frames.map(\.0), thumbnails: Dictionary(uniqueKeysWithValues: frames.map { ($0.0.id, $0.1) }), saved: frames.reduce(0) { $0 + $1.0.saved }, input: frames.reduce(0) { $0 + $1.0.before }, loading: false)
        func menu(_ name: String, _ state: HistoryFrame, paused: Bool = false, hover: UUID? = nil) {
            history.frame = state
            snapshot(MenuView(history: history, pausedOverride: paused, highlighted: hover).padding(16), to: file("09-menu\(name).png"))
        }
        menu("", full); menu("-paused", full, paused: true); menu("-hover", full, hover: full.rows.first?.id)
        snapshot(MenuView(history: history, pausedOverride: false, sampledPress: true).padding(16), to: file("09-menu-pressed.png"))
        for (name, fraction) in [("start", 0.0), ("middle", 0.5), ("end", 1.0)] {
            var sampled = full; sampled.saved = Int(Double(full.saved) * fraction); menu("-sweep-\(name)", sampled)
        }
        menu("-empty", HistoryFrame(loading: false)); menu("-loading", HistoryFrame()); menu("-error", HistoryFrame(loading: false, problem: "Could not read saved history."))
        let first = frames[0]
        menu("-one", HistoryFrame(rows: [first.0], thumbnails: [first.0.id: first.1], saved: first.0.saved, input: first.0.before, loading: false))
        history.active = [first.0]
        menu("-optimising", HistoryFrame(loading: false))
        history.active = []
        for t in SettingsTab.allCases where t != .tools {
            settingsSnapshot(SettingsView(tab: t), to: file("10-settings-\(t.rawValue.lowercased()).png"))
        }
        settingsSnapshot(SettingsView(tab: .images), to: file("10-settings-light.png"), scheme: .light)
        let disabled = UserDefaults(suiteName: "Pinch.RenderFixtures")!
        disabled.setVolatileDomain(["blurOn": false], forName: UserDefaults.argumentDomain)
        settingsSnapshot(SettingsView(tab: .privacy).defaultAppStorage(disabled), to: file("10-settings-privacy-disabled.png"))
        if Perf.enabled { benchmark(history, full) }
    }

    private static func renderTools(_ dir: URL) {
        let paths = Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
            let directory = tool.formula == "mozjpeg" ? "/opt/homebrew/opt/mozjpeg/bin" : "/opt/homebrew/bin"
            return (tool, URL(fileURLWithPath: directory).appendingPathComponent(tool.rawValue))
        })
        let missing = ToolPaths(paths: paths.filter { ![.avifenc, .cjxl, .gs].contains($0.key) })
        for (name, tools) in [("found", ToolPaths(paths: paths)), ("missing", missing)] {
            settingsSnapshot(SettingsView(tab: .tools, tools: tools), to: dir.appendingPathComponent("10-settings-tools-\(name).png"))
        }
        let history = History(); history.frame = HistoryFrame(loading: false)
        snapshot(MenuView(history: history, pausedOverride: false, showToolsHint: missing.hasMissing).padding(16), to: dir.appendingPathComponent("09-menu-tools-missing.png"))
    }

    private static func benchmark(_ history: History, _ frame: HistoryFrame) {
        history.frame = frame
        let renderer = ImageRenderer(content: MenuView(history: history, pausedOverride: false).fixedSize().environment(\.colorScheme, .dark))
        renderer.scale = 2
        let clock = ProcessInfo.processInfo
        var elapsed: [Double] = []
        var previous: CFData?
        for index in 0...30 {
            let start = clock.systemUptime
            renderer.content = MenuView(history: history, pausedOverride: index.isMultiple(of: 2)).fixedSize().environment(\.colorScheme, .dark)
            guard let bitmap = renderer.cgImage else { fatalError("Missing benchmark bitmap") }
            let milliseconds = (clock.systemUptime - start) * 1000
            guard let pixels = bitmap.dataProvider?.data else { fatalError("Unreadable benchmark bitmap") }
            if let previous { precondition(!CFEqual(previous, pixels), "Benchmark reused an unchanged frame") }
            previous = pixels
            if index > 0 { elapsed.append(milliseconds) }
            else { print(String(format: "[perf] first off-screen 2x bitmap: %.2f ms", milliseconds)) }
        }
        elapsed.sort()
        print(String(format: "[perf] retained menu, 30 off-screen frames: median %.2f ms, p95 %.2f ms, max %.2f ms", elapsed[14], elapsed[28], elapsed[29]))
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            let dir = FileManager.default.temporaryDirectory.appending(path: "pinch-qa-\(UUID())")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                var ledger = Ledger()
                for row in frame.rows.reversed() {
                    let file = dir.appending(path: "\(row.id).png")
                    Samples.save(frame.thumbnails[row.id]!, file, .png)
                    ledger.add(Receipt(id: row.id, date: row.date, name: row.name, before: row.before, after: row.after, output: file, original: file))
                }
                let path = dir.appending(path: "history.json")
                try JSONEncoder().encode(ledger).write(to: path)
                let archive = Archive(file: path)
                for label in ["cold", "cached"] {
                    let start = clock.systemUptime
                    let state = await archive.refresh(adding: nil)
                    precondition(state?.thumbnails.count == 5 && state?.saved == frame.saved)
                    Perf.log("\(label) five-thumbnail archive", since: start)
                }
            } catch { fatalError("Fixture archive: \(error)") }
        }
        precondition(done.wait(timeout: .now() + 20) == .success)
    }

    private static func settingsSnapshot<V: View>(_ view: V, to url: URL, scheme: ColorScheme = .dark) {
        let host = NSHostingView(rootView: view.environment(\.displayScale, 2).environment(\.colorScheme, scheme)
            .scaleEffect(2, anchor: .topLeading).frame(width: 1040, height: 1120, alignment: .topLeading))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        host.frame = CGRect(x: 0, y: 0, width: 1040, height: 1120)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1040, pixelsHigh: 1120, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        precondition(!window.isVisible)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
    }

    private static func checkHandoff() {
        let temp = FileManager.default.temporaryDirectory
        precondition(Paths.root.path.hasPrefix(temp.deletingLastPathComponent().path + "/"), "Handoff checks require the isolated QA home")
        UserDefaults.standard.setVolatileDomain([KitSound.enabledKey: false, "blurOn": false], forName: UserDefaults.argumentDomain)
        let input = temp.appendingPathComponent("Ledge fixture.png")
        Samples.save(Samples.photo(720, 480), input, .png)
        let initial = try! Data(contentsOf: input)
        let delegate = PinchApp()
        delegate.application(NSApp, open: [input, temp.appendingPathComponent("ignore.txt")])
        let store = Core.shared.store
        precondition(store.items.count == 1)
        let item = store.items[0], deadline = Date.now.addingTimeInterval(25)
        var steps = Set<Int>()
        while (item.running || item.pinch != nil) && Date.now < deadline {
            if let frame = item.pinch, frame.squeezed { steps.insert(frame.bytes) }
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.01))
        }
        precondition(item.state == .done && item.dest == input && item.newBytes < initial.count && item.newBytes == fileSize(input))
        precondition(steps.count == 10 && steps.min() == item.newBytes)
        let backup = try! Data(contentsOf: item.src!)
        precondition(backup == initial && NSApp.windows.allSatisfy { !$0.isVisible } && !NSApp.isActive)
        print("PASS open-files delegate: in-place result, original backup, ten countdown steps, unsupported input ignored, no visible windows or activation")
    }

    private static func landscapeProof() -> CGImage {
        let context = Samples.ctx(852, 324)
        func ink(_ hex: UInt32) { context.setFillColor(CGColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)) }
        func ridge(_ color: UInt32, _ points: [(Int, Int)]) {
            ink(color); context.move(to: .zero)
            for (x, y) in points { context.addLine(to: CGPoint(x: x, y: y)) }
            context.addLine(to: CGPoint(x: 852, y: 0)); context.closePath(); context.fillPath()
        }
        ink(0xCCDACF); context.fill(CGRect(x: 0, y: 0, width: 852, height: 324))
        ink(0xFBDEAA); context.fillEllipse(in: CGRect(x: 594, y: 191, width: 78, height: 78))
        ridge(0x90AAA0, [(0,128),(114,192),(174,159),(302,264),(400,171),(487,224),(630,127),(750,207),(852,149)])
        ridge(0x637F78, [(0,98),(83,125),(186,90),(314,181),(363,160),(480,228),(541,172),(619,144),(742,164),(852,111)])
        ridge(0x365C59, [(0,155),(89,113),(150,121),(309,58),(421,85),(493,64),(608,106),(689,137),(767,112),(852,152)])
        ridge(0x254542, [(0,48),(120,74),(199,58),(310,23),(456,43),(539,28),(691,58),(852,83)])
        return context.makeImage()!
    }

    private static func artwork(_ index: Int, scale: Int = 1) -> CGImage {
        let ctx = Samples.ctx(96 * scale, 96 * scale)
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        func fill(_ hex: UInt32) { ctx.setFillColor(CGColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)) }
        func rect(_ hex: UInt32, _ x: Int, _ y: Int, _ width: Int, _ height: Int) { fill(hex); ctx.fill(CGRect(x: x, y: y, width: width, height: height)) }
        func ridge(_ hex: UInt32, _ peak: Int, _ high: Int) {
            fill(hex); ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 0, y: high/3)); ctx.addLine(to: CGPoint(x: peak, y: high)); ctx.addLine(to: CGPoint(x: 96, y: high/4)); ctx.addLine(to: CGPoint(x: 96, y: 0)); ctx.closePath(); ctx.fillPath()
        }
        switch index {
        case 0, 3:
            rect(index == 0 ? 0xC5CDBA : 0xEDBA96, 0, 0, 96, 96); fill(0xFFEDCA); ctx.fillEllipse(in: CGRect(x: 64, y: 64, width: 16, height: 16))
            ridge(index == 0 ? 0x708B7F : 0x768F96, 27, 68); ridge(index == 0 ? 0x395C59 : 0x345462, 74, 46)
        case 1:
            rect(0xA99179, 0, 0, 96, 96); rect(0x443E39, 10, 30, 75, 51); rect(0xD2BC99, 15, 35, 65, 40); rect(0x676853, 22, 40, 35, 25); rect(0x735041, 0, 18, 96, 7); rect(0x4B4941, 41, 25, 11, 6)
        case 2:
            rect(0xEAE2D5, 0, 0, 96, 96); rect(0xAD533E, 12, 69, 56, 10); rect(0x282929, 12, 49, 70, 7); for y in [38,29,20] { rect(0x857C71, 12, y, y+23, 3) }
        default:
            rect(0xE2D8C9, 0, 0, 96, 96); for (slot, color) in [0xA35440,0xD99766,0x637C75,0x334D55].enumerated() { rect(UInt32(color), 8 + (slot%2)*40, 8 + (slot/2)*40, 36, 36) }
        }
        return ctx.makeImage()!
    }
}
