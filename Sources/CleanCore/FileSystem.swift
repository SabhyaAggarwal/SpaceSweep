import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Paths

public enum PathUtils {
    public static var home: String {
        // NSHomeDirectory() is correct for non-sandboxed apps; fall back to $HOME for tests.
        let h = NSHomeDirectory()
        if !h.isEmpty { return h }
        return ProcessInfo.processInfo.environment["HOME"] ?? "/"
    }

    /// Expands a leading "~" to the real home directory and standardizes the path.
    public static func expand(_ path: String) -> String {
        var p = path
        if p == "~" { p = home }
        else if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        return (p as NSString).standardizingPath
    }

    /// Replaces the home directory prefix with "~" for display.
    public static func abbreviate(_ path: String) -> String {
        let h = home
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }

    public static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path))
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: expand(path), isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Metadata

/// Cheap, per-item metadata read via a single lstat.
public struct FileStat: Sendable {
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isRegular: Bool
    /// Bytes actually allocated on disk (blocks * 512). Falls back to logical size when unknown.
    public let allocatedSize: Int64
    public let logicalSize: Int64
    public let modified: Date?
    public let accessed: Date?
    public let created: Date?

    /// Reads with lstat so symlinks are *not* followed (we never want to size or delete through a link).
    public static func read(_ path: String) -> FileStat? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let mode = st.st_mode & S_IFMT
        let isDir = mode == S_IFDIR
        let isLink = mode == S_IFLNK
        let isReg = mode == S_IFREG
        let logical = Int64(st.st_size)
        let allocated = Int64(st.st_blocks) * 512
        #if canImport(Darwin)
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        let atime = Date(timeIntervalSince1970: TimeInterval(st.st_atimespec.tv_sec) + TimeInterval(st.st_atimespec.tv_nsec) / 1e9)
        let btime = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec) + TimeInterval(st.st_birthtimespec.tv_nsec) / 1e9)
        let created: Date? = st.st_birthtimespec.tv_sec > 0 ? btime : nil
        #else
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtim.tv_sec) + TimeInterval(st.st_mtim.tv_nsec) / 1e9)
        let atime = Date(timeIntervalSince1970: TimeInterval(st.st_atim.tv_sec) + TimeInterval(st.st_atim.tv_nsec) / 1e9)
        let created: Date? = nil
        #endif
        return FileStat(isDirectory: isDir,
                        isSymlink: isLink,
                        isRegular: isReg,
                        allocatedSize: allocated,
                        logicalSize: logical,
                        modified: mtime,
                        accessed: atime,
                        created: created)
    }
}

// MARK: - Bundles we treat as a single opaque item

public enum Bundles {
    /// Folder extensions that are really "documents"/apps. We size them as one unit and never descend.
    public static let opaqueExtensions: Set<String> = [
        "app", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "theater",
        "xcodeproj", "xcworkspace", "playground", "framework", "bundle", "plugin", "appex", "xpc",
        "band", "logicx", "sparsebundle", "key", "pages", "numbers", "rtfd", "textbundle", "scriv",
        "aplibrary", "lrcat", "lrdata", "pkg", "mpkg", "prefpane", "qlgenerator", "kext", "dSYM",
        "xcarchive", "docset", "download", "vbox", "vmwarevm", "pvm", "utm", "3mf", "sketch", "fig",
    ]

    public static func isOpaque(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return !ext.isEmpty && opaqueExtensions.contains(ext)
    }
}

// MARK: - Walker

public struct WalkOptions: Sendable {
    /// 0 = only the root itself, 1 = root's children, … Int.max = unlimited.
    public var maxDepth: Int = .max
    public var skipHidden: Bool = false
    /// Treat bundles (.app, .photoslibrary, …) as leaves.
    public var opaqueBundles: Bool = true
    public var excludedPaths: Set<String> = []
    /// Directory *names* to never enter (e.g. ".git").
    public var excludedNames: Set<String> = []
    /// If a directory matches, it's handed to the visitor and not entered.
    public var stopDescending: (@Sendable (String, String) -> Bool)? = nil  // (path, name)

    public init() {}
}

public enum WalkEvent: Sendable {
    case file(path: String, stat: FileStat, depth: Int)
    /// A directory we are *not* descending into (opaque bundle or stopDescending match).
    case leafDirectory(path: String, depth: Int)
    case enterDirectory(path: String, depth: Int)
    case permissionDenied(path: String)
    case error(path: String, message: String)
}

/// A cancellable, allocation-light directory walker built on `contentsOfDirectory(atPath:)` + `lstat`.
/// Symlinks are never followed. Throws `CancellationError` when the surrounding Task is cancelled.
public enum Walker {
    /// True for EPERM/EACCES-style failures, however Foundation chose to wrap them.
    public static func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            return true
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying !== error {
            return isPermissionError(underlying)
        }
        return false
    }

    public static func walk(_ root: String,
                            options: WalkOptions = WalkOptions(),
                            visit: (WalkEvent) throws -> Void) throws {
        let fm = FileManager.default
        var stack: [(String, Int)] = [(root, 0)]
        var counter = 0
        while let (dir, depth) = stack.popLast() {
            counter += 1
            if counter % 64 == 0 { try Task.checkCancellation() }
            if options.excludedPaths.contains(dir) { continue }
            try visit(.enterDirectory(path: dir, depth: depth))
            let names: [String]
            do {
                names = try fm.contentsOfDirectory(atPath: dir)
            } catch {
                let ns = error as NSError
                if Walker.isPermissionError(ns) {
                    try visit(.permissionDenied(path: dir))
                } else {
                    try visit(.error(path: dir, message: ns.localizedDescription))
                }
                continue
            }
            for name in names {
                if options.skipHidden && name.hasPrefix(".") { continue }
                let path = dir == "/" ? "/" + name : dir + "/" + name
                if options.excludedPaths.contains(path) { continue }
                guard let st = FileStat.read(path) else { continue }
                if st.isSymlink { continue }
                if st.isDirectory {
                    if options.excludedNames.contains(name) { continue }
                    let childDepth = depth + 1
                    if let stop = options.stopDescending, stop(path, name) {
                        try visit(.leafDirectory(path: path, depth: childDepth))
                    } else if options.opaqueBundles && Bundles.isOpaque(path) {
                        try visit(.leafDirectory(path: path, depth: childDepth))
                    } else if childDepth > options.maxDepth {
                        try visit(.leafDirectory(path: path, depth: childDepth))
                    } else {
                        stack.append((path, childDepth))
                    }
                } else {
                    try visit(.file(path: path, stat: st, depth: depth + 1))
                }
            }
        }
    }
}

// MARK: - Sizes

public struct SizeInfo: Sendable {
    public var bytes: Int64 = 0
    public var files: Int = 0
    public var permissionDenied: [String] = []
    public var newestAccess: Date? = nil
    public var newestModified: Date? = nil
}

public enum SizeCalculator {
    /// Recursive allocated size of a path (file or directory). Symlinks are not followed.
    /// `onProgress` is called every ~2k files with the running byte total.
    public static func size(of path: String,
                            onProgress: ((Int64, Int) -> Void)? = nil) throws -> SizeInfo {
        guard let st = FileStat.read(path) else { return SizeInfo() }
        var info = SizeInfo()
        if !st.isDirectory {
            info.bytes = st.allocatedSize
            info.files = 1
            info.newestAccess = st.accessed
            info.newestModified = st.modified
            return info
        }
        var opts = WalkOptions()
        opts.opaqueBundles = false
        try Walker.walk(path, options: opts) { event in
            switch event {
            case .file(_, let s, _):
                info.bytes += s.allocatedSize
                info.files += 1
                if let a = s.accessed, info.newestAccess.map({ a > $0 }) ?? true { info.newestAccess = a }
                if let m = s.modified, info.newestModified.map({ m > $0 }) ?? true { info.newestModified = m }
                if info.files % 2048 == 0 { onProgress?(info.bytes, info.files) }
            case .permissionDenied(let p):
                info.permissionDenied.append(p)
            default:
                break
            }
        }
        return info
    }

    /// Builds a `FileEntry` for a path, sizing directories recursively.
    public static func entry(for path: String,
                             note: String? = nil,
                             risk: RiskLevel? = nil,
                             onProgress: ((Int64, Int) -> Void)? = nil) throws -> (FileEntry, [String])? {
        guard let st = FileStat.read(path), !st.isSymlink else { return nil }
        let info = try size(of: path, onProgress: onProgress)
        // For folders, "last used" is the newest access inside, which is what people actually mean.
        let accessed = st.isDirectory ? (info.newestAccess ?? st.accessed) : st.accessed
        let modified = st.isDirectory ? (info.newestModified ?? st.modified) : st.modified
        let entry = FileEntry(path: path,
                              size: info.bytes,
                              isDirectory: st.isDirectory,
                              modified: modified,
                              accessed: accessed,
                              created: st.created,
                              note: note,
                              risk: risk,
                              fileCount: info.files)
        return (entry, info.permissionDenied)
    }
}
