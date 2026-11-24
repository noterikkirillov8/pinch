import AppKit
import SwiftUI

@main
@MainActor
final class PinchApp: NSObject, NSApplicationDelegate {
    static func main() {
        KitType.wide = false
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.contains("-qa") || arguments.contains("-intro-preview") {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            guard QA.backgroundOnly else {
                print("Headless launch refused: activation policy is not prohibited."); exit(1)
            }
            Prefs.register()
            if QA.runIfAsked() { return }; exit(64)
        }
        Prefs.register()
        if let code = CLI.runIfAsked() { exit(code) }
        if Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true { exit(64) }
        if arguments.contains(where: { ["-selftest", "-make-samples", "-optimise"].contains($0) }) { exit(64) }
        let app = NSApplication.shared
        let delegate = PinchApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    var statusItem: NSStatusItem?
    private var wantsFirstIntro = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        wantsFirstIntro = true
        if statusItem != nil { presentFirstIntroIfRequested() }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        wantsFirstIntro = false
        for url in urls { Core.shared.openImage(url) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Drag.cleanup()
        FloatingWindow.shared.start(Core.shared.store)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = Self.mark()
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        if let button = item.button { button.addSubview(StatusDropView(frame: button.bounds)) }
        statusItem = item
        DropStrip.shared.refresh()
        _ = MenuPanel.shared
        History.shared.refresh()
        NotificationCenter.default.addObserver(self, selector: #selector(newDay), name: .NSCalendarDayChanged, object: nil)
        Core.shared.start()
        presentFirstIntroIfRequested()
    }

    private func presentFirstIntroIfRequested() {
        if wantsFirstIntro, !UserDefaults.standard.bool(forKey: IntroController.seenKey) {
            MenuPanel.shared.close()
            IntroController.shared.show()
        }
    }

    static func mark() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let path = NSBezierPath()
            for points in [[(2,16),(7,11)], [(2,11),(7,11),(7,16)], [(16,2),(11,7)], [(16,7),(11,7),(11,2)]] {
                for (index, point) in points.enumerated() {
                    let target = NSPoint(x: point.0, y: point.1)
                    if index == 0 { path.move(to: target) } else { path.line(to: target) }
                }
            }
            NSColor.black.setStroke(); path.lineWidth = 2; path.lineJoinStyle = .round; path.stroke(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Pinch"
        return image
    }

    func applicationDidBecomeActive(_ notification: Notification) { Core.shared.refreshFolder() }
}

extension PinchApp {
    @objc func togglePanel() {
        if IntroController.shared.isShowing { MenuPanel.shared.close(); IntroController.shared.show(); return }    // never the intro and the panel together
        if let b = statusItem?.button { MenuPanel.shared.toggle(from: b) }
    }
    @objc func newDay() { History.shared.refresh() }
}
