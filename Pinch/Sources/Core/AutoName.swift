import AppKit
import Foundation

/// `<App> <yyyy-MM-dd> at <HH.mm.ss>.<ext>` for new screenshots and recordings.
enum AutoName {
    static func format(app: String, date: Date, ext: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let clean = app.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(clean) \(f.string(from: date)).\(ext)"
    }

    /// Same name, or with " 2", " 3" before the extension when taken.
    static func unique(in dir: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        var url = dir.appendingPathComponent(name)
        while FileManager.default.fileExists(atPath: url.path) {
            n += 1
            url = dir.appendingPathComponent("\(base) \(n).\(ext)")
        }
        return url
    }

    /// macOS marks screenshots and recordings with this metadata, whatever the file is called.
    static func isScreenCapture(_ url: URL) -> Bool {
        if XAttr.has(XAttr.screenCapture, url) { return true }
        guard let item = MDItemCreate(nil, url.path as CFString),
              let v = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber else { return false }
        return v.boolValue
    }

    /// Renames `url` and returns the new URL (unchanged on failure).
    static func rename(_ url: URL, app: String) -> URL {
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let dest = unique(in: url.deletingLastPathComponent(), name: format(app: app, date: date, ext: url.pathExtension))
        do { try FileManager.default.moveItem(at: url, to: dest); return dest } catch { return url }
    }
}

/// The last app that was in front that is not Pinch or the screenshot UI.
@MainActor
final class FrontApp {
    static let shared = FrontApp()
    private(set) var name = "Screenshot"
    private let ignored: Set<String> = ["com.erikkirillov.Pinch", "com.apple.screencaptureui", "com.apple.screenshot.launcher"]

    func start() {
        take(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { FrontApp.shared.take(app) }
        }
    }
    private func take(_ app: NSRunningApplication?) {
        guard let app, let id = app.bundleIdentifier, !ignored.contains(id), let n = app.localizedName else { return }
        name = n
    }
}
