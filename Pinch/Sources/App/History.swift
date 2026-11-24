import AppKit
import ImageIO
import Observation

struct Receipt: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let name: String
    let before: Int
    let after: Int
    let output: URL
    let original: URL
    var saved: Int { max(0, before - after) }
    var percent: Int { before > 0 ? Int((Double(saved) * 100 / Double(before)).rounded()) : 0 }
}

struct Ledger: Codable, Sendable {
    var recent: [Receipt] = []
    var day = Date.distantPast
    var input = 0
    var saved = 0

    mutating func roll(to now: Date) {
        guard !Calendar.current.isDate(day, inSameDayAs: now) else { return }
        day = now; input = 0; saved = 0
    }

    mutating func add(_ receipt: Receipt) {
        roll(to: receipt.date)
        if let prior = recent.first(where: { $0.id == receipt.id }), Calendar.current.isDate(prior.date, inSameDayAs: day) {
            input -= prior.before; saved -= prior.saved
        }
        recent.removeAll { $0.id == receipt.id }
        recent.insert(receipt, at: 0)
        recent = Array(recent.prefix(50))
        input += receipt.before; saved += receipt.saved
    }
}

struct HistoryFrame: Sendable {
    var rows: [Receipt] = []
    var thumbnails: [UUID: CGImage] = [:]
    var saved = 0
    var input = 0
    var loading = true
    var problem: String?
    var ratio: Double { input > 0 ? Double(saved) / Double(input) : 0 }
}

actor Archive {
    private var ledger: Ledger?
    private var cache: [UUID: CGImage] = [:]
    private var revision = 0
    private let file: URL
    init(file: URL = URL.applicationSupportDirectory.appending(path: "Pinch/history.json")) { self.file = file }

    func refresh(adding receipt: Receipt?) async -> HistoryFrame? {
        let start = ProcessInfo.processInfo.systemUptime
        revision += 1
        let version = revision
        defer { Perf.log("history refresh", since: start) }
        do {
            if ledger == nil {
                if FileManager.default.fileExists(atPath: file.path) { ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: file)) }
                else { ledger = Ledger() }
            }
        } catch { return HistoryFrame(loading: false, problem: "Could not read saved history.") }
        guard var snapshot = ledger else { return nil }
        var problem: String?
        if let receipt {
            snapshot.add(receipt)
            cache[receipt.id] = nil
            do {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
            } catch { problem = "History could not be saved on this Mac." }
        }
        snapshot.roll(to: .now)
        ledger = snapshot
        let rows = Array(snapshot.recent.prefix(5))
        cache = cache.filter { key, _ in rows.contains { $0.id == key } }
        for row in rows where cache[row.id] == nil {
            let thumb = await Self.thumbnail(row.output)
            guard version == revision else { return nil }
            cache[row.id] = thumb
        }
        return HistoryFrame(rows: rows, thumbnails: cache, saved: snapshot.saved, input: snapshot.input, loading: false, problem: problem)
    }

    private static func thumbnail(_ url: URL) async -> CGImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: 96
        ] as CFDictionary) { return image }
        return await Thumbs.make(url)?.v.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

@MainActor @Observable final class History {
    static let shared = History()
    var frame = HistoryFrame()
    var active: [Receipt] = []
    @ObservationIgnored private var running: Set<UUID> = []
    private let archive = Archive()

    func refresh(_ receipt: Receipt? = nil) {
        Task {
            if let next = await archive.refresh(adding: receipt) {
                frame = next
                active.removeAll { !running.contains($0.id) }
            }
        }
    }

    func begin(_ item: Item) {
        guard let output = item.dest, let original = item.src else { return }
        let id = item.id, date = Date.now
        running.insert(id)
        Task {
            let size = await Task.detached { fileSize(original) }.value
            guard running.contains(id) else { return }
            active.removeAll { $0.id == id }
            active.insert(Receipt(id: id, date: date, name: output.lastPathComponent, before: size, after: size, output: output, original: original), at: 0)
        }
    }

    func end(_ item: Item) {
        running.remove(item.id); active.removeAll { $0.id == item.id }
    }

    func record(_ item: Item) {
        running.remove(item.id)
        guard let output = item.dest, let original = item.src else { return }
        refresh(Receipt(id: item.id, date: .now, name: output.lastPathComponent, before: item.oldBytes,
                        after: item.newBytes, output: output, original: original))
    }
}

enum Perf {
    static let enabled = CommandLine.arguments.contains("-perf")
    static func log(_ label: String, since start: Double) {
        guard enabled else { return }
        print(String(format: "[perf] %@ %.2f ms", label, (ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
