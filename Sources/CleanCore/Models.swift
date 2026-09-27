import Foundation

// MARK: - Risk

/// How careful the user should be before removing something in a category.
public enum RiskLevel: String, Codable, Hashable, Sendable, CaseIterable {
    /// Regenerated automatically (caches, build products, logs). Delete freely.
    case safe
    /// Usually fine, but a human should glance at the list first (downloads, old files, leftovers).
    case review
    /// Deleting may lose data or require a re-download / re-setup (backups, simulators, Docker).
    case careful

    public var title: String {
        switch self {
        case .safe: return "Safe to delete"
        case .review: return "Review first"
        case .careful: return "Careful"
        }
    }
}

// MARK: - File entry

/// One row in a scan result: a file or a folder, with its (recursive) allocated size and timestamps.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }

    public let path: String
    public let name: String
    /// Allocated size on disk in bytes. Recursive for directories.
    public let size: Int64
    public let isDirectory: Bool
    public let modified: Date?
    /// Last access ("last opened") time. On APFS this is updated lazily, so treat it as a hint.
    public let accessed: Date?
    public let created: Date?
    /// Short human hint, e.g. "iOS 17.4 debug symbols", "Duplicate of …", "Installer".
    public var note: String?
    /// Per-item override of the category risk (e.g. a current DeviceSupport folder is `.careful`).
    public var risk: RiskLevel?
    /// Groups related rows (duplicate sets share a key).
    public var groupKey: String?
    /// Number of files inside (directories only, best effort).
    public var fileCount: Int

    public init(path: String,
                name: String? = nil,
                size: Int64,
                isDirectory: Bool,
                modified: Date? = nil,
                accessed: Date? = nil,
                created: Date? = nil,
                note: String? = nil,
                risk: RiskLevel? = nil,
                groupKey: String? = nil,
                fileCount: Int = 0) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.size = size
        self.isDirectory = isDirectory
        self.modified = modified
        self.accessed = accessed
        self.created = created
        self.note = note
        self.risk = risk
        self.groupKey = groupKey
        self.fileCount = fileCount
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Extension, lower-cased, or "" for none.
    public var kind: String {
        if isDirectory && url.pathExtension.isEmpty { return "Folder" }
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "File" : ext
    }

    /// The most useful "last used" date we have: access time, falling back to modification time.
    public var lastUsed: Date? { accessed ?? modified }

    // Comparable keys for table sorting (optionals are not Comparable).
    public var accessedSortKey: Date { accessed ?? .distantPast }
    public var modifiedSortKey: Date { modified ?? .distantPast }
    public var lastUsedSortKey: Date { lastUsed ?? .distantPast }

    /// Whole days since the file was last used, or nil if unknown.
    public func daysSinceLastUsed(now: Date = Date()) -> Int? {
        guard let d = lastUsed else { return nil }
        return max(0, Int(now.timeIntervalSince(d) / 86_400))
    }
}

// MARK: - Progress / results

public struct ScanProgress: Hashable, Sendable {
    public var itemsVisited: Int
    public var bytesFound: Int64
    public var currentPath: String

    public init(itemsVisited: Int = 0, bytesFound: Int64 = 0, currentPath: String = "") {
        self.itemsVisited = itemsVisited
        self.bytesFound = bytesFound
        self.currentPath = currentPath
    }
}

public struct ScanResult: Hashable, Sendable {
    public let categoryID: String
    public var entries: [FileEntry]
    public var totalSize: Int64
    /// Paths that could not be read because of permissions (usually Full Disk Access).
    public var permissionDeniedPaths: [String]
    /// Other non-fatal errors, as short strings.
    public var errors: [String]
    public var finishedAt: Date
    public var duration: TimeInterval
    /// Extra info lines for the UI (e.g. simulator list, snapshot list).
    public var infoLines: [String]

    public init(categoryID: String,
                entries: [FileEntry],
                permissionDeniedPaths: [String] = [],
                errors: [String] = [],
                finishedAt: Date = Date(),
                duration: TimeInterval = 0,
                infoLines: [String] = []) {
        self.categoryID = categoryID
        self.entries = entries
        self.totalSize = entries.reduce(0) { $0 + $1.size }
        self.permissionDeniedPaths = permissionDeniedPaths
        self.errors = errors
        self.finishedAt = finishedAt
        self.duration = duration
        self.infoLines = infoLines
    }

    public var needsFullDiskAccess: Bool { !permissionDeniedPaths.isEmpty }
}

// MARK: - Settings

/// User-tunable knobs. Stored by the app as JSON.
public struct ScanSettings: Codable, Hashable, Sendable {
    /// Minimum size for the "Large files" scan.
    public var largeFileThresholdMB: Int = 200
    /// Files not opened for this many days are "stale".
    public var staleDays: Int = 180
    /// Minimum size for duplicate detection.
    public var duplicateMinMB: Int = 1
    /// Folders to look for dev artifacts (node_modules, .build, …). "~" is expanded.
    public var projectRoots: [String] = ScanSettings.defaultProjectRoots
    /// Folders to skip everywhere.
    public var excludedPaths: [String] = []
    /// Include ~/Library in the large-file scan.
    public var includeLibraryInLargeFiles: Bool = false
    /// Remove files permanently instead of moving them to the Trash.
    public var permanentDelete: Bool = false
    /// Maximum directory depth for the dev-artifact scan.
    public var devScanMaxDepth: Int = 7

    public init() {}

    public static let defaultProjectRoots: [String] = [
        "~/Developer", "~/Projects", "~/projects", "~/Code", "~/code", "~/src", "~/dev",
        "~/GitHub", "~/github", "~/repos", "~/Documents", "~/Desktop", "~/Downloads",
    ]

    public var largeFileThresholdBytes: Int64 { Int64(largeFileThresholdMB) * 1_000_000 }
    public var duplicateMinBytes: Int64 { Int64(duplicateMinMB) * 1_000_000 }
}
