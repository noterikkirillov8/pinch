import AppKit

/// Files dropped on the menu bar icon or the edge strip, and the `pinch` command installer.
extension Core {
    /// One file runs as a normal result card; several files or a folder run as one batch card.
    func optimiseDropped(_ urls: [URL], preset: Preset? = nil) {
        let files = Command.expand(urls, quiet: true)
        guard !files.isEmpty else { return notify("Nothing to optimise") }
        let preset = preset ?? Prefs.preset
        var opts = Options.fromPrefs(preset: preset)
        opts.allowConvert = true
        if files.count == 1 { single(files[0], opts) } else { batch(files, opts) }
    }

    private func single(_ file: URL, _ opts: Options) {
        guard let backup = Backup.make(file) else { return notify("Could not read this file") }
        let item = Item(name: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension, source: .file)
        item.dest = file; item.src = backup; item.opts = opts
        show(item)
        run(item, label: Kind.of(file) == .video ? "Optimising video" : "Optimising")
    }

    private func batch(_ files: [URL], _ opts: Options) {
        let item = Item(name: "\(files.count) files", ext: "", source: .file)
        item.batch = Batch(done: 0, total: files.count)
        item.state = .running("Optimising 1 of \(files.count)")
        store.add(item)
        History.shared.begin(item)
        Task.detached {
            var before = 0, after = 0, failed = 0
            var receipts: [(URL, URL, Int, Int)] = []
            for (i, file) in files.enumerated() {
                await MainActor.run { item.state = .running("Optimising \(i + 1) of \(files.count)") }
                let old = fileSize(file)
                guard let backup = Backup.make(file) else { failed += 1; continue }
                do {
                    let o = try Engine.process(input: backup, output: file, opts: opts)
                    before += o.oldBytes; after += o.newBytes
                    receipts.append((o.url ?? file, backup, o.oldBytes, o.newBytes))
                } catch { before += old; after += old; if case Failure.alreadyOptimised = error {} else { failed += 1 } }
                let (b, a) = (before, after)
                await MainActor.run { item.batch?.done = i + 1; item.oldBytes = b; item.newBytes = a }
            }
            let finished = receipts
            await MainActor.run {
                item.state = failed == files.count ? .failed("Could not optimise these files") : .done
                item.overlay = failed > 0 ? "\(files.count - failed) of \(files.count) optimised" : nil
                for (out, original, old, new) in finished {
                    let r = Item(name: out.deletingPathExtension().lastPathComponent, ext: out.pathExtension, source: .file)
                    r.dest = out; r.src = original; r.oldBytes = old; r.newBytes = new
                    History.shared.record(r)
                }
                History.shared.end(item)
                KitSound.play(.confirm)
                Core.shared.store.arm(item)
            }
        }
    }
}

enum CommandLineTool {
    struct State { var installed: Bool; var detail: String }

    static var link: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pinch") }

    static var state: State {
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            let current = Bundle.main.executableURL?.path
            return State(installed: true, detail: target == current ? "Installed at ~/.local/bin/pinch" : "Installed, points at another copy of Pinch")
        }
        return State(installed: false, detail: "Adds pinch to ~/.local/bin")
    }

    static func toggle() -> State {
        let fm = FileManager.default
        if state.installed {
            try? fm.trashItem(at: link, resultingItemURL: nil)
        } else if let exe = Bundle.main.executableURL, !fm.fileExists(atPath: link.path) {
            try? fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.createSymbolicLink(at: link, withDestinationURL: exe)
        } else {
            return State(installed: false, detail: "A file named pinch already exists there")
        }
        return state
    }
}
