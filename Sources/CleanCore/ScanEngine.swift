import Foundation

/// Runs a category scan on the calling thread. Call it from a background task; cancel via Task cancellation.
public enum ScanEngine {
    public static func scan(_ category: CleanCategory, context ctx: ScanContext) throws -> ScanResult {
        let start = Date()
        var entries: [FileEntry] = []
        var denied: [String] = []
        var info: [String] = []

        switch category.kind {
        case .whole(let paths):
            (entries, denied) = try LocationScanner.whole(paths, risk: nil, ctx: ctx)
        case .children(let paths):
            (entries, denied) = try LocationScanner.children(paths, ctx: ctx)
        case .childrenNamed(let paths, let namer):
            (entries, denied) = try LocationScanner.children(paths, namer: namer, ctx: ctx)
        case .deviceSupport(let paths):
            (entries, denied) = try DeviceSupportScanner.scan(paths, ctx: ctx)
        case .screenshots(let paths):
            (entries, denied) = try ScreenshotScanner.scan(paths, ctx: ctx)
        case .downloads:
            (entries, denied) = try DownloadsScanner.scan(ctx: ctx)
        case .largeFiles:
            (entries, denied) = try LargeFilesScanner.scan(ctx: ctx)
        case .staleFiles:
            (entries, denied) = try StaleFilesScanner.scan(ctx: ctx)
        case .duplicates:
            (entries, denied) = try DuplicateScanner.scan(ctx: ctx)
        case .devArtifacts:
            (entries, denied) = try DevArtifactsScanner.scan(ctx: ctx)
        case .leftovers:
            (entries, denied) = try LeftoversScanner.scan(ctx: ctx)
        case .trash:
            (entries, denied) = try TrashScanner.scan(ctx: ctx)
        case .simulators:
            (entries, denied, info) = try SimulatorScanner.scan(ctx: ctx)
        }

        // Fill in the category risk for rows that didn't set their own.
        entries = entries.map { e in
            var e = e
            if e.risk == nil { e.risk = category.risk }
            return e
        }

        let uniqueDenied = Array(Set(denied)).sorted()
        return ScanResult(categoryID: category.id,
                          entries: entries,
                          permissionDeniedPaths: uniqueDenied,
                          errors: [],
                          finishedAt: Date(),
                          duration: Date().timeIntervalSince(start),
                          infoLines: info)
    }
}

// MARK: - Disk usage

public struct DiskUsage: Hashable, Sendable {
    public let total: Int64
    /// Space available right now.
    public let free: Int64
    /// Space available if macOS purges its purgeable data (nil off-macOS).
    public let freeIncludingPurgeable: Int64?
    public var used: Int64 { total - free }
    public var purgeable: Int64 { max(0, (freeIncludingPurgeable ?? free) - free) }

    public static func current(volume: String = "/") -> DiskUsage? {
        let url = URL(fileURLWithPath: volume)
        #if os(macOS)
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        let free = values.volumeAvailableCapacity ?? 0
        let important = values.volumeAvailableCapacityForImportantUsage
        return DiskUsage(total: Int64(total), free: Int64(free), freeIncludingPurgeable: important.map { Int64($0) })
        #else
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: volume),
              let total = attrs[.systemSize] as? NSNumber, let free = attrs[.systemFreeSize] as? NSNumber else { return nil }
        return DiskUsage(total: total.int64Value, free: free.int64Value, freeIncludingPurgeable: nil)
        #endif
    }
}

// MARK: - Cleaner

public struct CleanReport: Sendable {
    public struct Failure: Sendable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public let message: String
    }
    public var removed: [FileEntry] = []
    public var failed: [Failure] = []
    public var bytesFreed: Int64 { removed.reduce(0) { $0 + $1.size } }
    public var permanently: Bool = false
    public init() {}
}

public enum Cleaner {
    /// Protected roots we refuse to touch no matter what a scanner produced.
    static let neverDelete: Set<String> = {
        let h = PathUtils.home
        return ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/etc", "/var",
                h, h + "/Library", h + "/Desktop", h + "/Documents", h + "/Downloads", h + "/Pictures", h + "/Movies", h + "/Music",
                h + "/Library/Application Support", h + "/Library/Caches", h + "/Library/Containers", h + "/Library/Group Containers",
                h + "/Library/Developer", h + "/Library/Developer/Xcode", h + "/Library/Developer/CoreSimulator",
                h + "/Library/Developer/CoreSimulator/Devices", h + "/Library/Preferences", h + "/Library/Mail", h + "/Library/Messages"]
    }()

    public static func isProtected(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return neverDelete.contains(p) || p.isEmpty || !p.hasPrefix("/")
    }

    /// Moves entries to the Trash (or removes them permanently). Never throws; failures are reported per item.
    public static func remove(_ entries: [FileEntry], permanently: Bool, onProgress: ((Int, Int) -> Void)? = nil) -> CleanReport {
        var report = CleanReport()
        report.permanently = permanently
        let fm = FileManager.default
        for (i, e) in entries.enumerated() {
            onProgress?(i, entries.count)
            if isProtected(e.path) {
                report.failed.append(.init(path: e.path, message: "Refusing to delete a protected folder"))
                continue
            }
            guard fm.fileExists(atPath: e.path) || (try? fm.destinationOfSymbolicLink(atPath: e.path)) != nil else {
                report.failed.append(.init(path: e.path, message: "Already gone"))
                continue
            }
            do {
                if permanently {
                    try fm.removeItem(atPath: e.path)
                } else {
                    #if os(macOS)
                    try fm.trashItem(at: e.url, resultingItemURL: nil)
                    #else
                    try fm.removeItem(atPath: e.path)
                    #endif
                }
                report.removed.append(e)
            } catch {
                let ns = error as NSError
                let msg = Walker.isPermissionError(ns) ? "Permission denied — grant Full Disk Access or delete in Finder" : ns.localizedDescription
                report.failed.append(.init(path: e.path, message: msg))
            }
        }
        onProgress?(entries.count, entries.count)
        return report
    }

    /// Empties ~/.Trash (and per-volume trashes) permanently.
    public static func emptyTrash() -> CleanReport {
        var report = CleanReport()
        report.permanently = true
        guard let (entries, _) = try? TrashScanner.scan(ctx: ScanContext()) else { return report }
        return remove(entries, permanently: true)
    }
}
