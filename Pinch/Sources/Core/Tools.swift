import Foundation

enum Tool: String, CaseIterable, Sendable {
    case pngquant, oxipng, cjpeg, jpegtran, jpegoptim, cwebp, avifenc, cjxl, gifsicle, ffmpeg, ffprobe, gs
    var formula: String {
        switch self {
        case .cjpeg, .jpegtran: "mozjpeg"
        case .cwebp: "webp"
        case .avifenc: "libavif"
        case .cjxl: "jpeg-xl"
        case .gs: "ghostscript"
        case .ffprobe: "ffmpeg"
        default: rawValue
        }
    }
}

struct ToolPaths: Sendable {
    static let shared = ToolPaths()
    static let installCommand = "brew install pngquant oxipng mozjpeg webp libavif jpeg-xl gifsicle ffmpeg ghostscript"
    private let paths: [Tool: URL]

    var hasMissing: Bool { paths.count < Tool.allCases.count }

    init(paths: [Tool: URL]) { self.paths = paths }

    func firstLaunchHint(defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: "checkedToolsAtLaunch") else { return false }
        defaults.set(true, forKey: "checkedToolsAtLaunch")
        return hasMissing
    }

    init(root: URL = URL(fileURLWithPath: "/"), path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") {
        let dirs = ["opt/homebrew/bin", "opt/homebrew/opt/mozjpeg/bin", "usr/local/bin", "usr/local/opt/mozjpeg/bin"].map { root.appendingPathComponent($0) }
            + path.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) }
        var found: [Tool: URL] = [:]
        for tool in Tool.allCases {
            found[tool] = dirs.lazy.map { $0.appendingPathComponent(tool.rawValue) }.first { url in
                FileManager.default.isExecutableFile(atPath: url.path) && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
        }
        paths = found
    }

    func executable(_ tool: Tool) throws -> URL {
        guard let url = paths[tool] else { throw Failure.missingTool(tool.rawValue) }
        return url
    }
}

enum Failure: Error, LocalizedError, Sendable {
    case missingTool(String)
    case tool(String, Int32, String)
    case alreadyOptimised
    case unsupported
    case cancelled
    case other(String)

    var errorDescription: String? {
        switch self {
        case let .missingTool(t): "\(t) is not installed. Run: brew install \(Tool(rawValue: t)?.formula ?? t)"
        case let .tool(t, s, log): "\(t) failed (\(s)). \(log.suffix(160))"
        case .alreadyOptimised: "Already optimised"
        case .unsupported: "Unsupported file type"
        case .cancelled: "Stopped"
        case let .other(m): m
        }
    }
}

/// Lets the stop button end the running tool.
final class Job: @unchecked Sendable {
    let tools: ToolPaths
    init(tools: ToolPaths = .shared) { self.tools = tools }
    private let lock = NSLock()
    private var proc: Process?
    private(set) var cancelled = false
    func attach(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; proc?.terminate(); lock.unlock() }
}

@discardableResult
func runTool(_ tool: Tool, _ args: [String], job: Job? = nil) throws -> String {
    let executable = try (job?.tools ?? .shared).executable(tool)
    if job?.cancelled == true { throw Failure.cancelled }
    let logURL = Paths.work.appendingPathComponent("\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: logURL) }
    let out = try FileHandle(forWritingTo: logURL)
    let p = Process()
    p.executableURL = executable
    p.arguments = args
    p.standardOutput = out
    p.standardError = out
    p.standardInput = FileHandle.nullDevice
    job?.attach(p)
    try p.run()
    p.waitUntilExit()
    try? out.close()
    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    if job?.cancelled == true { throw Failure.cancelled }
    guard p.terminationStatus == 0 else { throw Failure.tool(tool.rawValue, p.terminationStatus, log) }
    return log
}

func fileSize(_ url: URL) -> Int {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
}

extension Int {
    var humanSize: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        return f.string(fromByteCount: Int64(self))
    }
}

// MARK: extended attributes

enum XAttr {
    static let status = "pinch.optimisation.status"
    static let screenCapture = "com.apple.metadata:kMDItemIsScreenCapture"

    static func has(_ name: String, _ url: URL) -> Bool { getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    static func set(_ name: String, _ value: String, _ url: URL) {
        let bytes = Array(value.utf8)
        setxattr(url.path, name, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }
    static func copyAll(from: URL, to: URL) {
        let size = listxattr(from.path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buf = [CChar](repeating: 0, count: size)
        guard listxattr(from.path, &buf, size, XATTR_NOFOLLOW) > 0 else { return }
        var name = ""
        for c in buf {
            if c == 0 {
                if !name.isEmpty, name != status, name != "com.apple.quarantine" {
                    let n = getxattr(from.path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    if n >= 0 {
                        var data = [UInt8](repeating: 0, count: n)
                        if getxattr(from.path, name, &data, n, 0, XATTR_NOFOLLOW) >= 0 {
                            setxattr(to.path, name, data, n, 0, XATTR_NOFOLLOW)
                        }
                    }
                }
                name = ""
            } else { name.append(Character(UnicodeScalar(UInt8(bitPattern: c)))) }
        }
    }
}
