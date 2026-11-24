import AppKit

/// Watches one folder for new files with a directory event source (no polling).
@MainActor
final class FolderWatcher {
    let dir: URL
    private var source: DispatchSourceFileSystemObject?
    private var known: Set<String> = []
    private var ignored: Set<String> = []
    private let onFile: @MainActor (URL, String) -> Void

    init(dir: URL, onFile: @escaping @MainActor (URL, String) -> Void) {
        self.dir = dir; self.onFile = onFile
        known = Set(names())
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scan() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
    deinit { source?.cancel() }

    private func names() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// Files Pinch renames or writes itself are not new files.
    func ignore(_ url: URL) {
        ignored.insert(url.lastPathComponent)
        known.insert(url.lastPathComponent)
    }

    private func scan() {
        let now = Set(names())
        let fresh = now.subtracting(known).subtracting(ignored)
        known = now
        let app = FrontApp.shared.name
        for name in fresh where !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            Task { @MainActor [weak self] in
                guard await Self.settle(url) else { return }
                self?.onFile(url, app)
            }
        }
    }

    /// Waits until size and modification date stop changing (screen recordings grow for a while).
    static func settle(_ url: URL) async -> Bool {
        try? await Task.sleep(for: .milliseconds(300))
        var last: (Int, Date?)?
        for _ in 0 ..< 400 {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return false }
            let cur = (v.fileSize ?? 0, v.contentModificationDate)
            if let l = last, l.0 == cur.0, l.1 == cur.1, cur.0 > 0 { return !XAttr.has(XAttr.status, url) }
            last = cur
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }
}
