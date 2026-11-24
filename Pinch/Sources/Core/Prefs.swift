import Foundation

/// Every setting Pinch uses. Views bind to these keys with @AppStorage; the engine reads them here.
enum Prefs {
    nonisolated(unsafe) static let defaults: [String: Any] = [
        "clipboardOn": true, "watchOn": true, "floatingOn": true, "paused": false,
        "corner": "bottomRight", "followCursor": true,
        "hideFilesAfter": 30, "hideClipAfter": 10,
        "preset": "identical", "webFallback": false, "stripMetadata": true, "preserveDates": true,
        "videoCompat": false, "capFPS": true, "targetFPS": 60, "removeAudio": false, "silentAudio": true,
        "dropStrip": true, "dropEdge": "left",
        "blurOn": false, "blurEmail": true, "blurKeys": true, "blurPhone": true, "blurCard": true,
        "autoName": true,
    ]
    static var d: UserDefaults { .standard }
    static func register() { d.register(defaults: defaults) }

    static var clipboardOn: Bool { d.bool(forKey: "clipboardOn") }
    static var watchOn: Bool { d.bool(forKey: "watchOn") }
    static var floatingOn: Bool { d.bool(forKey: "floatingOn") }
    static var paused: Bool { d.bool(forKey: "paused") }
    static var corner: String { d.string(forKey: "corner") ?? "bottomRight" }
    static var followCursor: Bool { d.bool(forKey: "followCursor") }
    static var hideFilesAfter: Int { d.integer(forKey: "hideFilesAfter") }
    static var hideClipAfter: Int { d.integer(forKey: "hideClipAfter") }
    static var preset: Preset { Preset(rawValue: d.string(forKey: "preset") ?? "") ?? .identical }
    static var webFallback: Bool { d.bool(forKey: "webFallback") }
    static var dropStrip: Bool { d.bool(forKey: "dropStrip") }
    static var dropEdge: String { d.string(forKey: "dropEdge") ?? "left" }
    static var stripMetadata: Bool { d.bool(forKey: "stripMetadata") }
    static var preserveDates: Bool { d.bool(forKey: "preserveDates") }
    static var videoCompat: Bool { d.bool(forKey: "videoCompat") }
    static var silentAudio: Bool { d.bool(forKey: "silentAudio") }
    static var capFPS: Bool { d.bool(forKey: "capFPS") }
    static var targetFPS: Int { d.integer(forKey: "targetFPS") }
    static var removeAudio: Bool { d.bool(forKey: "removeAudio") }
    static var blurOn: Bool { d.bool(forKey: "blurOn") }
    static var autoName: Bool { d.bool(forKey: "autoName") }
    static var blurCategories: BlurCategories {
        var c: BlurCategories = []
        if d.bool(forKey: "blurEmail") { c.insert(.email) }
        if d.bool(forKey: "blurKeys") { c.insert(.keys) }
        if d.bool(forKey: "blurPhone") { c.insert(.phone) }
        if d.bool(forKey: "blurCard") { c.insert(.card) }
        return c
    }

    /// The macOS screenshot folder, falling back to the Desktop.
    static var screenshotFolder: URL {
        let fm = FileManager.default
        if let raw = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return fm.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }
}

enum Paths {
    static let root: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Pinch", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    static func sub(_ name: String) -> URL {
        let u = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var work: URL { sub("work") }
    static var backups: URL { sub("backups") }
    static var clip: URL { sub("clipboard") }
}
