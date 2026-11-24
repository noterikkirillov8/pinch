import AppKit
import SwiftUI
import Observation

/// Progress of a dropped folder or several files processed as one result.
struct Batch: Equatable {
    var done = 0, total = 0
}

/// One floating result.
@MainActor @Observable
final class Item: Identifiable {
    enum State: Equatable { case running(String), done, failed(String), notice(String) }
    enum Source { case file, clipboard }

    let id = UUID()
    var state: State = .running("Optimising")
    var name: String
    var ext: String
    var source: Source
    var thumb: NSImage?
    var oldBytes = 0
    var newBytes = 0
    var oldSize: CGSize?
    var newSize: CGSize?
    var hidden = 0
    var textLines = 0
    var textPreview = ""
    var inRemoval = false
    var overlay: String?
    var pinch: PinchFrame?
    var ssim: Double?
    var batch: Batch?
    @ObservationIgnored var moment: Task<Void, Never>?
    let startedAt = Date()

    /// Where the result lives, the untouched original copy, and what was asked of the engine.
    var dest: URL?
    var src: URL?
    var opts = Options()
    var job: Job?
    @ObservationIgnored var hideTask: Task<Void, Never>?

    init(name: String, ext: String, source: Source) {
        self.name = name; self.ext = ext; self.source = source
    }

    var isText: Bool { textLines > 0 }
    var running: Bool { if case .running = state { true } else { false } }
    var improved: Bool { newBytes > 0 && newBytes < oldBytes }
}

@MainActor @Observable
final class ResultStore {
    var items: [Item] = []
    @ObservationIgnored var onChange: (() -> Void)?

    /// Newest first.
    func add(_ item: Item) {
        withAnimation(KitMotion.panelIn) { items.insert(item, at: 0) }
        onChange?()
    }

    func remove(_ item: Item, animated: Bool = true) {
        item.hideTask?.cancel()
        guard items.contains(where: { $0.id == item.id }) else { return }
        if animated {
            withAnimation(KitMotion.panelOut) { item.inRemoval = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(200))
                withAnimation(KitMotion.list) { items.removeAll { $0.id == item.id } }
                onChange?()
            }
        } else {
            items.removeAll { $0.id == item.id }
            onChange?()
        }
    }

    var hoveredID: UUID?

    /// Auto-hide: files 30 s, clipboard 10 s. Hovering pauses; leaving restarts the timer.
    func arm(_ item: Item) {
        item.hideTask?.cancel()
        let secs = item.source == .clipboard ? Prefs.hideClipAfter : Prefs.hideFilesAfter
        guard secs > 0 else { return }
        item.hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled, let self else { return }
            if hoveredID != nil { return }
            remove(item)
        }
    }

    func hover(_ item: Item, _ on: Bool) {
        if on { hoveredID = item.id; item.hideTask?.cancel() }
        else { if hoveredID == item.id { hoveredID = nil }; if !item.running { arm(item) } }
    }
}
