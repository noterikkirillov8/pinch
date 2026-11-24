import AppIntents
import AppKit
import Foundation

enum PresetChoice: String, AppEnum {
    case identical, chat, ai, web, lossless
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let caseDisplayRepresentations: [PresetChoice: DisplayRepresentation] = [
        .identical: "Visually identical", .chat: "For chat", .ai: "For AI", .web: "For the web", .lossless: "Lossless",
    ]
    var preset: Preset { Preset(rawValue: rawValue) ?? .identical }
}

enum FormatChoice: String, AppEnum {
    case png, jpeg, webp, avif, heic, jxl
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Format"
    static let caseDisplayRepresentations: [FormatChoice: DisplayRepresentation] = [
        .png: "PNG", .jpeg: "JPEG", .webp: "WebP", .avif: "AVIF", .heic: "HEIC", .jxl: "JPEG XL",
    ]
    var format: ImageFormat { ImageFormat(rawValue: rawValue) ?? .png }
}

/// Runs the engine on a copy of each input in a scratch folder and hands the results back.
enum IntentWork {
    static func run(_ files: [IntentFile], _ opts: Options) throws -> [IntentFile] {
        let dir = Paths.work.appendingPathComponent("intent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var results: [IntentFile] = []
        for (i, file) in files.enumerated() {
            let name = file.filename.isEmpty ? "file-\(i)" : file.filename
            let src = dir.appendingPathComponent("in-\(i)-\(name)")
            try file.data.write(to: src)
            let dest = dir.appendingPathComponent(name)
            do {
                let o = try Engine.process(input: src, output: dest, opts: opts)
                results.append(IntentFile(fileURL: o.url ?? dest, filename: (o.url ?? dest).lastPathComponent))
            } catch Failure.alreadyOptimised {
                results.append(IntentFile(fileURL: src, filename: name))
            }
        }
        return results
    }
}

struct OptimiseFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Optimise files"
    static let description = IntentDescription("Makes images, videos, GIFs and PDFs smaller without visible loss, using a Pinch preset.")
    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Preset", default: .identical) var preset: PresetChoice
    static var parameterSummary: some ParameterSummary { Summary("Optimise \(\.$files) with \(\.$preset)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        var opts = Options.fromPrefs(preset: preset.preset)
        opts.allowConvert = true
        return .result(value: try IntentWork.run(files, opts))
    }
}

struct ConvertImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert image"
    static let description = IntentDescription("Converts an image to another format at the smallest size that still looks the same.")
    @Parameter(title: "Image") var image: IntentFile
    @Parameter(title: "Format", default: .webp) var format: FormatChoice
    static var parameterSummary: some ParameterSummary { Summary("Convert \(\.$image) to \(\.$format)") }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        var opts = Options.fromPrefs(preset: .identical)
        opts.convert = format.format
        guard let file = try IntentWork.run([image], opts).first else { throw Failure.other("Could not convert this image") }
        return .result(value: file)
    }
}

struct CopyTextFromImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy text from image"
    static let description = IntentDescription("Reads the text in an image on this Mac and copies it.")
    @Parameter(title: "Image") var image: IntentFile
    static var parameterSummary: some ParameterSummary { Summary("Copy text from \(\.$image)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let tmp = Paths.work.appendingPathComponent("\(UUID().uuidString)-\(image.filename)")
        try image.data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let cg = Engine.decode(tmp) else { throw Failure.other("Could not read this image") }
        let hide: BlurCategories = Prefs.blurOn ? Prefs.blurCategories : []
        let text = Redactor.text(of: cg, hide: hide).filter { !$0.isEmpty }.joined(separator: "\n")
        guard !text.isEmpty else { throw Failure.other("No text found") }
        await MainActor.run {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.setString(text, forType: .string); pb.setString("true", forType: Core.marker)
        }
        return .result(value: text)
    }
}

struct PinchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OptimiseFilesIntent(), phrases: ["Optimise files with \(.applicationName)"], shortTitle: "Optimise files", systemImageName: "arrow.down.right.and.arrow.up.left")
        AppShortcut(intent: ConvertImageIntent(), phrases: ["Convert an image with \(.applicationName)"], shortTitle: "Convert image", systemImageName: "photo")
        AppShortcut(intent: CopyTextFromImageIntent(), phrases: ["Copy text from an image with \(.applicationName)"], shortTitle: "Copy text from image", systemImageName: "text.viewfinder")
    }
}
