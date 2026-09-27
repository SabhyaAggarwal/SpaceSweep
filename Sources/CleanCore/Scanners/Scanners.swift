import Foundation

/// Shared context handed to every scanner.
public struct ScanContext: Sendable {
    public var settings: ScanSettings
    public var now: Date
    /// Called from the scanning thread, at most a few times per second.
    public var progress: @Sendable (ScanProgress) -> Void
    /// Platform hook: is an app with this bundle identifier installed? (nil = unknown / not on macOS)
    public var isAppInstalled: (@Sendable (String) -> Bool)?
    /// Platform hook: the "Date Last Opened" Finder shows (Spotlight's kMDItemLastUsedDate). nil = unknown.
    public var lastUsedDate: (@Sendable (String) -> Date?)?

    public init(settings: ScanSettings = ScanSettings(),
                now: Date = Date(),
                progress: @escaping @Sendable (ScanProgress) -> Void = { _ in },
                isAppInstalled: (@Sendable (String) -> Bool)? = nil,
                lastUsedDate: (@Sendable (String) -> Date?)? = nil) {
        self.settings = settings
        self.now = now
        self.progress = progress
        self.isAppInstalled = isAppInstalled
        self.lastUsedDate = lastUsedDate
    }

    var excludedPaths: Set<String> { Set(settings.excludedPaths.map(PathUtils.expand)) }
}

/// Rate-limits progress callbacks so the UI isn't flooded.
final class ProgressThrottle: @unchecked Sendable {
    private var last = Date.distantPast
    private let interval: TimeInterval
    private let sink: @Sendable (ScanProgress) -> Void
    var items = 0
    var bytes: Int64 = 0

    init(interval: TimeInterval = 0.25, sink: @escaping @Sendable (ScanProgress) -> Void) {
        self.interval = interval
        self.sink = sink
    }

    func tick(path: String, force: Bool = false) {
        let now = Date()
        if force || now.timeIntervalSince(last) >= interval {
            last = now
            sink(ScanProgress(itemsVisited: items, bytesFound: bytes, currentPath: PathUtils.abbreviate(path)))
        }
    }
}

// MARK: - Location scanners

enum LocationScanner {
    /// One row per listed folder (that exists).
    static func whole(_ paths: [String], risk: RiskLevel?, ctx: ScanContext) throws -> ([FileEntry], [String]) {
        let throttle = ProgressThrottle(sink: ctx.progress)
        var entries: [FileEntry] = []
        var denied: [String] = []
        for raw in paths {
            let path = PathUtils.expand(raw)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            throttle.tick(path: path, force: true)
            if let (entry, d) = try SizeCalculator.entry(for: path, risk: risk, onProgress: { b, f in
                throttle.bytes = b; throttle.items = f; throttle.tick(path: path)
            }) {
                if entry.size > 0 || entry.fileCount > 0 { entries.append(entry) }
                denied += d
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }

    /// One row per immediate child of each listed folder.
    static func children(_ paths: [String],
                         namer: NamingRule = .none,
                         filter: ((String) -> Bool)? = nil,
                         noteFor: ((String, FileStat) -> String?)? = nil,
                         riskFor: ((String) -> RiskLevel?)? = nil,
                         ctx: ScanContext) throws -> ([FileEntry], [String]) {
        let throttle = ProgressThrottle(sink: ctx.progress)
        var entries: [FileEntry] = []
        var denied: [String] = []
        var seen = Set<String>()
        for raw in paths {
            let dir = PathUtils.expand(raw)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: dir)
            } catch {
                let ns = error as NSError
                if Walker.isPermissionError(ns) { denied.append(dir) }
                continue
            }
            for name in names.sorted() {
                if name == ".DS_Store" || name == ".localized" { continue }
                let path = dir + "/" + name
                if seen.contains(path) { continue }
                seen.insert(path)
                if let filter, !filter(path) { continue }
                guard let st = FileStat.read(path), !st.isSymlink else { continue }
                try Task.checkCancellation()
                throttle.tick(path: path, force: true)
                let baseBytes = throttle.bytes, baseItems = throttle.items
                guard let (rawEntry, d) = try SizeCalculator.entry(for: path, onProgress: { b, f in
                    throttle.bytes = baseBytes + b; throttle.items = baseItems + f; throttle.tick(path: path)
                }) else { continue }
                var entry = rawEntry
                entry.note = noteFor?(path, st)
                entry.risk = riskFor?(path)
                entry = rename(entry, rule: namer)
                entries.append(entry)
                denied += d
                throttle.bytes = baseBytes + entry.size
                throttle.items = baseItems + entry.fileCount
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }

    private static func rename(_ entry: FileEntry, rule: NamingRule) -> FileEntry {
        switch rule {
        case .none, .archives:
            return entry
        case .derivedData:
            // "MyApp-abcdefghijklmnopqrstuvwxyz12" → "MyApp"
            let name = entry.name
            if let dash = name.lastIndex(of: "-"), name.distance(from: dash, to: name.endIndex) == 29 {
                var e = FileEntry(path: entry.path, name: String(name[..<dash]), size: entry.size,
                                  isDirectory: entry.isDirectory, modified: entry.modified, accessed: entry.accessed,
                                  created: entry.created, note: entry.note, risk: entry.risk, fileCount: entry.fileCount)
                e.note = e.note ?? "Project build folder"
                return e
            }
            if name == "ModuleCache.noindex" {
                var e = entry; e.note = "Shared module cache"; return e
            }
            return entry
        }
    }
}

// MARK: - Downloads

enum DownloadsScanner {
    static let installerExtensions: Set<String> = ["dmg", "pkg", "zip", "iso", "xip", "tar", "gz", "tgz", "7z", "rar", "msi", "exe", "ipsw", "img", "bin"]

    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        try LocationScanner.children(["~/Downloads"], noteFor: { path, st in
            let ext = (path as NSString).pathExtension.lowercased()
            if installerExtensions.contains(ext) {
                return "Installer / archive"
            }
            if st.isDirectory { return nil }
            if let a = st.accessed, ctx.now.timeIntervalSince(a) > 90 * 86_400 {
                return "Not opened in \(AgeFormatter.relative(a, now: ctx.now).replacingOccurrences(of: " ago", with: ""))"
            }
            return nil
        }, ctx: ctx)
    }
}

// MARK: - Screenshots

enum ScreenshotScanner {
    static func looksLikeScreenshot(_ name: String) -> Bool {
        let lower = name.lowercased()
        let prefixes = ["screenshot ", "screen shot ", "screen recording ", "simulator screenshot", "simulator screen recording", "cleanshot ", "capture d’écran", "bildschirmfoto"]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    static func scan(_ paths: [String], ctx: ScanContext) throws -> ([FileEntry], [String]) {
        try LocationScanner.children(paths, filter: { looksLikeScreenshot(($0 as NSString).lastPathComponent) },
                                     noteFor: { path, _ in
            (path as NSString).pathExtension.lowercased() == "mov" ? "Screen recording" : "Screenshot"
        }, ctx: ctx)
    }
}

// MARK: - Device support

enum DeviceSupportScanner {
    /// Folder names look like "17.4 (21E219)", "iPhone15,3 17.4 (21E219)" or "iPhone15,3 17.4 (21E219) arm64e".
    static func version(from name: String) -> String? {
        let pattern = #"(\d+\.\d+(?:\.\d+)?)\s*\("#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let r = Range(m.range(at: 1), in: name) else { return nil }
        return String(name[r])
    }

    static func scan(_ paths: [String], ctx: ScanContext) throws -> ([FileEntry], [String]) {
        // Find the newest version per platform folder so we can mark it as "keep".
        var newestPerRoot: [String: String] = [:]
        for raw in paths {
            let dir = PathUtils.expand(raw)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let versions = names.compactMap(version(from:))
            if let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
                newestPerRoot[dir] = newest
            }
        }
        return try LocationScanner.children(paths, noteFor: { path, _ in
            let dir = (path as NSString).deletingLastPathComponent
            let platform = ((dir as NSString).lastPathComponent).replacingOccurrences(of: " DeviceSupport", with: "")
            let name = (path as NSString).lastPathComponent
            guard let v = version(from: name) else { return "\(platform) symbols" }
            if newestPerRoot[dir] == v { return "\(platform) \(v) symbols — newest, keep if you still debug on it" }
            return "\(platform) \(v) symbols — old version"
        }, riskFor: { path in
            let dir = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            if let v = version(from: name), newestPerRoot[dir] == v { return .careful }
            return .safe
        }, ctx: ctx)
    }
}

// MARK: - Simulators

enum SimulatorScanner {
    /// Reads CoreSimulator/Devices/<UDID>/device.plist to get a friendly name + runtime.
    static func describe(deviceDir: String) -> (name: String, runtime: String)? {
        let plist = deviceDir + "/device.plist"
        guard let data = FileManager.default.contents(atPath: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let name = dict["name"] as? String ?? "Simulator"
        var runtime = dict["runtime"] as? String ?? ""
        // com.apple.CoreSimulator.SimRuntime.iOS-17-4 → iOS 17.4
        if let r = runtime.range(of: "SimRuntime.") {
            runtime = String(runtime[r.upperBound...])
            var parts = runtime.split(separator: "-").map(String.init)
            if parts.count >= 2 {
                let os = parts.removeFirst()
                runtime = os + " " + parts.joined(separator: ".")
            }
        }
        return (name, runtime)
    }

    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String], [String]) {
        let root = PathUtils.expand("~/Library/Developer/CoreSimulator/Devices")
        var (entries, denied) = try LocationScanner.children([root], noteFor: { path, _ in
            guard let d = describe(deviceDir: path) else { return nil }
            return "\(d.name) · \(d.runtime)"
        }, ctx: ctx)
        // Swap the UDID for the friendly name when we have one.
        entries = entries.map { e in
            guard let d = describe(deviceDir: e.path) else { return e }
            return FileEntry(path: e.path, name: "\(d.name) (\(d.runtime))", size: e.size, isDirectory: true,
                             modified: e.modified, accessed: e.accessed, created: e.created,
                             note: "UDID \(e.name)", risk: .careful, fileCount: e.fileCount)
        }
        // Also include the caches dir and runtime dyld caches as safe rows.
        let (extra, denied2) = try LocationScanner.whole(["~/Library/Developer/CoreSimulator/Caches",
                                                          "~/Library/Developer/CoreSimulator/Volumes",
                                                          "~/Library/Developer/CoreSimulator/Temp"], risk: .safe, ctx: ctx)
        var info: [String] = []
        if !entries.isEmpty {
            info.append("\(entries.count) simulator device\(entries.count == 1 ? "" : "s") on disk. Use “Delete unavailable simulators” to remove ones whose runtime is gone.")
        }
        return ((entries + extra).sorted { $0.size > $1.size }, denied + denied2, info)
    }
}

// MARK: - Trash

enum TrashScanner {
    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        var paths = ["~/.Trash"]
        // Per-volume trashes for the current user (external drives).
        if let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for v in vols {
                let t = "/Volumes/\(v)/.Trashes/\(getuid())"
                if FileManager.default.fileExists(atPath: t) { paths.append(t) }
            }
        }
        return try LocationScanner.children(paths, ctx: ctx)
    }
}
