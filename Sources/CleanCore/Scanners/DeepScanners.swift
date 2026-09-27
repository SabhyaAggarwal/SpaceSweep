import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Large files

enum LargeFilesScanner {
    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        let home = PathUtils.home
        let threshold = ctx.settings.largeFileThresholdBytes
        let throttle = ProgressThrottle(sink: ctx.progress)
        var opts = WalkOptions()
        opts.skipHidden = true
        opts.excludedPaths = ctx.excludedPaths
        if !ctx.settings.includeLibraryInLargeFiles {
            opts.excludedPaths.insert(home + "/Library")
        }
        // Never descend into cloud placeholders / other users' stuff.
        opts.excludedNames = ["node_modules", ".git", ".Trash"]
        var entries: [FileEntry] = []
        var denied: [String] = []
        try Walker.walk(home, options: opts) { event in
            switch event {
            case .file(let path, let st, _):
                throttle.items += 1
                if throttle.items % 512 == 0 { throttle.tick(path: path) }
                if st.allocatedSize >= threshold || st.logicalSize >= threshold {
                    entries.append(FileEntry(path: path, size: st.allocatedSize, isDirectory: false,
                                             modified: st.modified, accessed: st.accessed, created: st.created,
                                             note: st.allocatedSize < st.logicalSize / 2 ? "Sparse or compressed" : nil))
                    throttle.bytes += st.allocatedSize
                }
            case .leafDirectory(let path, _):
                // Opaque bundles (Photos library, VMs, .app…): size as a unit.
                throttle.tick(path: path)
                let info = try SizeCalculator.size(of: path) { b, _ in
                    throttle.tick(path: path)
                    _ = b
                }
                denied += info.permissionDenied
                if info.bytes >= threshold, let st = FileStat.read(path) {
                    entries.append(FileEntry(path: path, size: info.bytes, isDirectory: true,
                                             modified: info.newestModified ?? st.modified,
                                             accessed: info.newestAccess ?? st.accessed, created: st.created,
                                             note: "Bundle · \(info.files) files", fileCount: info.files))
                    throttle.bytes += info.bytes
                }
            case .permissionDenied(let p):
                denied.append(p)
            default:
                break
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }
}

// MARK: - Stale files

enum StaleFilesScanner {
    static let roots = ["~/Desktop", "~/Documents", "~/Downloads", "~/Movies", "~/Music", "~/Pictures"]

    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        let cutoff = ctx.now.addingTimeInterval(-Double(ctx.settings.staleDays) * 86_400)
        let minSize: Int64 = 1_000_000
        let throttle = ProgressThrottle(sink: ctx.progress)
        var opts = WalkOptions()
        opts.skipHidden = true
        opts.excludedPaths = ctx.excludedPaths
        opts.excludedNames = ["node_modules", ".git"]
        var entries: [FileEntry] = []
        var denied: [String] = []
        for raw in roots {
            let root = PathUtils.expand(raw)
            guard PathUtils.isDirectory(root) else { continue }
            try Walker.walk(root, options: opts) { event in
                switch event {
                case .file(let path, let st, _):
                    throttle.items += 1
                    if throttle.items % 512 == 0 { throttle.tick(path: path) }
                    guard st.allocatedSize >= minSize else { return }
                    let lastUsed = max(st.accessed ?? .distantPast, st.modified ?? .distantPast)
                    if lastUsed < cutoff {
                        entries.append(FileEntry(path: path, size: st.allocatedSize, isDirectory: false,
                                                 modified: st.modified, accessed: st.accessed, created: st.created,
                                                 note: "Last used \(AgeFormatter.relative(lastUsed, now: ctx.now))"))
                        throttle.bytes += st.allocatedSize
                    }
                case .leafDirectory(let path, _):
                    let info = try SizeCalculator.size(of: path)
                    denied += info.permissionDenied
                    guard info.bytes >= minSize, let st = FileStat.read(path) else { return }
                    let lastUsed = max(info.newestAccess ?? .distantPast, info.newestModified ?? .distantPast)
                    if lastUsed < cutoff {
                        entries.append(FileEntry(path: path, size: info.bytes, isDirectory: true,
                                                 modified: info.newestModified ?? st.modified,
                                                 accessed: info.newestAccess ?? st.accessed, created: st.created,
                                                 note: "Bundle · last used \(AgeFormatter.relative(lastUsed, now: ctx.now))",
                                                 fileCount: info.files))
                        throttle.bytes += info.bytes
                    }
                case .permissionDenied(let p):
                    denied.append(p)
                default:
                    break
                }
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }
}

// MARK: - Dev artifacts

public enum DevArtifacts {
    /// Folder names that are always regenerable.
    public static let alwaysArtifacts: Set<String> = [
        "node_modules", ".build", "DerivedData", "Pods", "__pycache__", ".venv", "venv", ".tox", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", ".next", ".nuxt", ".parcel-cache", ".turbo", ".cache", ".gradle",
        "zig-cache", ".zig-cache", "zig-out", ".dart_tool", ".angular", ".svelte-kit", ".astro", ".vercel",
        ".serverless", ".terraform", "bower_components", ".yarn/cache", ".pnpm-store", "vendor/bundle",
        ".pio", ".ccls-cache", ".clangd", "cmake-build-debug", "cmake-build-release", ".idea/caches", ".metals", ".bloop",
    ]

    /// Folder names that are artifacts only if a marker file sits next to them.
    public static let conditionalArtifacts: [String: [String]] = [
        "target": ["Cargo.toml", "pom.xml", "build.sbt"],
        "build": ["CMakeLists.txt", "build.gradle", "build.gradle.kts", "gradlew", "meson.build", "package.json", "setup.py", "pyproject.toml", "platformio.ini", "Makefile", "flutter.yaml", "pubspec.yaml", "sketch.yaml"],
        "dist": ["package.json", "pyproject.toml", "setup.py"],
        "out": ["package.json", "CMakeLists.txt", "tsconfig.json"],
        "bin": ["go.mod", "CMakeLists.txt"],
        "obj": ["CMakeLists.txt", "Makefile"],
        ".pio": ["platformio.ini"],
        "Debug": ["CMakeLists.txt"],
        "Release": ["CMakeLists.txt"],
    ]

    /// Decide whether `name` inside `parent` is a build/dependency artifact.
    public static func isArtifact(name: String, parent: String) -> String? {
        if alwaysArtifacts.contains(name) { return describe(name) }
        if let markers = conditionalArtifacts[name] {
            for m in markers where FileManager.default.fileExists(atPath: parent + "/" + m) {
                return "\(describe(name)) (\(m) project)"
            }
        }
        return nil
    }

    static func describe(_ name: String) -> String {
        switch name {
        case "node_modules": return "npm / yarn / pnpm dependencies"
        case ".build": return "Swift Package build folder"
        case "DerivedData": return "Xcode derived data"
        case "Pods": return "CocoaPods"
        case ".venv", "venv": return "Python virtualenv"
        case "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox": return "Python cache"
        case "target": return "Cargo / Maven build output"
        case ".pio": return "PlatformIO build output"
        case "build", "dist", "out", "bin", "obj", "Debug", "Release", "cmake-build-debug", "cmake-build-release": return "Build output"
        case ".next", ".nuxt", ".svelte-kit", ".astro", ".angular", ".parcel-cache", ".turbo", ".vercel": return "Web framework build cache"
        case ".gradle": return "Gradle project cache"
        case "zig-cache", ".zig-cache", "zig-out": return "Zig build output"
        case ".dart_tool": return "Dart / Flutter tool cache"
        case ".terraform": return "Terraform providers"
        default: return "Build artifact"
        }
    }
}

enum DevArtifactsScanner {
    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        let throttle = ProgressThrottle(sink: ctx.progress)
        var opts = WalkOptions()
        opts.maxDepth = ctx.settings.devScanMaxDepth
        opts.excludedPaths = ctx.excludedPaths
        opts.excludedNames = [".git", "Library", ".Trash"]
        opts.stopDescending = { path, name in
            DevArtifacts.isArtifact(name: name, parent: (path as NSString).deletingLastPathComponent) != nil
        }
        var entries: [FileEntry] = []
        var denied: [String] = []
        var seen = Set<String>()
        // De-duplicate overlapping roots (e.g. ~/Documents and ~/Documents/Code).
        let roots = ctx.settings.projectRoots.map(PathUtils.expand).filter(PathUtils.isDirectory)
        let uniqueRoots = roots.filter { r in !roots.contains { other in other != r && r.hasPrefix(other + "/") } }
        for root in Array(Set(uniqueRoots)).sorted() {
            try Walker.walk(root, options: opts) { event in
                switch event {
                case .enterDirectory(let path, _):
                    throttle.items += 1
                    if throttle.items % 64 == 0 { throttle.tick(path: path) }
                case .leafDirectory(let path, _):
                    let name = (path as NSString).lastPathComponent
                    let parent = (path as NSString).deletingLastPathComponent
                    guard let why = DevArtifacts.isArtifact(name: name, parent: parent), !seen.contains(path) else { return }
                    seen.insert(path)
                    throttle.tick(path: path, force: true)
                    let info = try SizeCalculator.size(of: path) { b, _ in _ = b; throttle.tick(path: path) }
                    denied += info.permissionDenied
                    guard info.bytes > 0, let st = FileStat.read(path) else { return }
                    let project = (parent as NSString).lastPathComponent
                    entries.append(FileEntry(path: path, name: "\(project)/\(name)", size: info.bytes, isDirectory: true,
                                             modified: info.newestModified ?? st.modified,
                                             accessed: info.newestAccess ?? st.accessed, created: st.created,
                                             note: why, fileCount: info.files))
                    throttle.bytes += info.bytes
                case .permissionDenied(let p):
                    denied.append(p)
                default:
                    break
                }
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }
}

// MARK: - Duplicates

public enum ContentHasher {
    /// Hex digest of the first `limit` bytes (or the whole file when limit is nil).
    public static func digest(of path: String, limit: Int? = nil) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var remaining = limit ?? Int.max
        #if canImport(CryptoKit)
        var hasher = SHA256()
        #else
        var fnv: UInt64 = 0xcbf29ce484222325
        #endif
        while remaining > 0 {
            let chunk = min(remaining, 1 << 20)
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            remaining -= data.count
            #if canImport(CryptoKit)
            hasher.update(data: data)
            #else
            for b in data { fnv = (fnv ^ UInt64(b)) &* 0x100000001b3 }
            #endif
        }
        #if canImport(CryptoKit)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return String(format: "%016llx", fnv)
        #endif
    }
}

enum DuplicateScanner {
    static let roots = ["~/Desktop", "~/Documents", "~/Downloads", "~/Movies", "~/Pictures"]

    static func scan(ctx: ScanContext, roots overrideRoots: [String]? = nil) throws -> ([FileEntry], [String]) {
        let throttle = ProgressThrottle(sink: ctx.progress)
        let minSize = ctx.settings.duplicateMinBytes
        var opts = WalkOptions()
        opts.skipHidden = true
        opts.excludedPaths = ctx.excludedPaths
        opts.excludedNames = ["node_modules", ".git"]
        var bySize: [Int64: [(String, FileStat)]] = [:]
        var denied: [String] = []
        for raw in overrideRoots ?? roots {
            let root = PathUtils.expand(raw)
            guard PathUtils.isDirectory(root) else { continue }
            try Walker.walk(root, options: opts) { event in
                switch event {
                case .file(let path, let st, _):
                    throttle.items += 1
                    if throttle.items % 512 == 0 { throttle.tick(path: path) }
                    if st.isRegular && st.logicalSize >= minSize {
                        bySize[st.logicalSize, default: []].append((path, st))
                    }
                case .permissionDenied(let p):
                    denied.append(p)
                default:
                    break
                }
            }
        }
        var entries: [FileEntry] = []
        for (size, candidates) in bySize where candidates.count > 1 {
            try Task.checkCancellation()
            // Stage 1: cheap prefix hash.
            var byPrefix: [String: [(String, FileStat)]] = [:]
            for c in candidates {
                throttle.tick(path: c.0)
                guard let h = ContentHasher.digest(of: c.0, limit: 64 * 1024) else { continue }
                byPrefix[h, default: []].append(c)
            }
            for (_, group) in byPrefix where group.count > 1 {
                // Stage 2: full hash (skip when the prefix covered the whole file).
                var byFull: [String: [(String, FileStat)]] = [:]
                for c in group {
                    throttle.tick(path: c.0)
                    let h = size <= 64 * 1024 ? "prefix" : (ContentHasher.digest(of: c.0) ?? UUID().uuidString)
                    byFull[h, default: []].append(c)
                }
                for (hash, dupes) in byFull where dupes.count > 1 {
                    // Oldest copy is the "original"; the rest are removable.
                    let sorted = dupes.sorted { ($0.1.created ?? $0.1.modified ?? .distantPast) < ($1.1.created ?? $1.1.modified ?? .distantPast) }
                    let original = sorted[0]
                    let key = String(hash.prefix(12))
                    entries.append(FileEntry(path: original.0, size: original.1.allocatedSize, isDirectory: false,
                                             modified: original.1.modified, accessed: original.1.accessed,
                                             created: original.1.created,
                                             note: "Original · \(sorted.count - 1) cop\(sorted.count == 2 ? "y" : "ies")",
                                             risk: .careful, groupKey: key))
                    for d in sorted.dropFirst() {
                        entries.append(FileEntry(path: d.0, size: d.1.allocatedSize, isDirectory: false,
                                                 modified: d.1.modified, accessed: d.1.accessed, created: d.1.created,
                                                 note: "Duplicate of \(PathUtils.abbreviate(original.0))",
                                                 risk: .review, groupKey: key))
                        throttle.bytes += d.1.allocatedSize
                    }
                }
            }
        }
        // Sort: biggest sets first, original first within a set.
        let groupSize = Dictionary(grouping: entries, by: { $0.groupKey ?? "" }).mapValues { $0.reduce(0) { $0 + $1.size } }
        entries.sort { a, b in
            let ga = groupSize[a.groupKey ?? ""] ?? 0, gb = groupSize[b.groupKey ?? ""] ?? 0
            if ga != gb { return ga > gb }
            if a.groupKey != b.groupKey { return (a.groupKey ?? "") < (b.groupKey ?? "") }
            return (a.risk == .careful) && (b.risk != .careful)
        }
        return (entries, denied)
    }
}

// MARK: - Leftovers

public enum Leftovers {
    static let locations: [(String, String)] = [   // (folder, what)
        ("~/Library/Application Support", "Application Support"),
        ("~/Library/Caches", "Cache"),
        ("~/Library/Containers", "Container"),
        ("~/Library/Group Containers", "Group container"),
        ("~/Library/Saved Application State", "Saved state"),
        ("~/Library/HTTPStorages", "HTTP storage"),
        ("~/Library/WebKit", "WebKit storage"),
        ("~/Library/Logs", "Logs"),
        ("~/Library/Preferences", "Preferences"),
    ]

    /// Bundle-ID-ish prefixes that belong to macOS itself or to things that aren't apps.
    static let ignoredPrefixes = ["com.apple.", "group.com.apple.", "org.swift.", "com.crashlytics", "group.is.workflow", "loginwindow", "com.microsoft.autoupdate", "com.microsoft.OneDrive"]

    /// Extracts the bundle identifier from a folder/file name if it looks like reverse-DNS.
    public static func bundleID(from name: String) -> String? {
        var n = name
        for suffix in [".savedState", ".plist", ".binarycookies"] where n.hasSuffix(suffix) { n.removeLast(suffix.count) }
        // Group containers: "6N38VWS5BX.ru.keepcoder.Telegram" → drop the team ID.
        let parts = n.split(separator: ".").map(String.init)
        guard parts.count >= 3 else { return nil }
        var candidate = parts
        if let first = candidate.first, first.count == 10, first == first.uppercased(),
           first.allSatisfy({ $0.isLetter || $0.isNumber }), first.contains(where: \.isNumber) {
            candidate.removeFirst()   // Apple team ID prefix on group containers
        }
        if candidate.first == "group" { candidate.removeFirst() }
        guard candidate.count >= 2 else { return nil }
        let tld = candidate[0].lowercased()
        let knownTLDs: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "me", "us", "uk", "de", "fr", "ru", "jp", "cn", "in", "it", "nl", "se", "ch", "at", "ai", "sh", "xyz", "tv", "info", "eu", "ca", "au", "nz", "fi", "no", "dk", "pl", "es", "br", "kr", "tw", "hk", "sg", "be", "cz", "pt", "ie", "gg", "so", "st", "im", "is", "ly", "to", "cc", "ws", "org", "one", "team", "studio", "software", "tools", "gmbh", "ltd"]
        guard knownTLDs.contains(tld) else { return nil }
        return candidate.joined(separator: ".")
    }

    static func isIgnored(_ id: String) -> Bool {
        ignoredPrefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
}

enum LeftoversScanner {
    static func scan(ctx: ScanContext) throws -> ([FileEntry], [String]) {
        guard let isInstalled = ctx.isAppInstalled else { return ([], []) }
        let throttle = ProgressThrottle(sink: ctx.progress)
        var entries: [FileEntry] = []
        var denied: [String] = []
        var installedCache: [String: Bool] = [:]
        for (raw, what) in Leftovers.locations {
            let dir = PathUtils.expand(raw)
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir) } catch {
                if Walker.isPermissionError(error as NSError) { denied.append(dir) }
                continue
            }
            for name in names {
                try Task.checkCancellation()
                guard let id = Leftovers.bundleID(from: name), !Leftovers.isIgnored(id) else { continue }
                if installedCache[id] == nil { installedCache[id] = isInstalled(id) }
                if installedCache[id] == true { continue }
                // Also accept the parent ID: "com.foo.bar.helper" is fine if "com.foo.bar" is installed.
                let parentID = id.split(separator: ".").dropLast().joined(separator: ".")
                if parentID.split(separator: ".").count >= 2 {
                    if installedCache[parentID] == nil { installedCache[parentID] = isInstalled(parentID) }
                    if installedCache[parentID] == true { continue }
                }
                let path = dir + "/" + name
                throttle.tick(path: path, force: true)
                guard let (entry, d) = try SizeCalculator.entry(for: path, note: "\(what) for \(id) — app not found", risk: .review) else { continue }
                if entry.size > 0 { entries.append(entry) }
                denied += d
                throttle.bytes += entry.size
            }
        }
        return (entries.sorted { $0.size > $1.size }, denied)
    }
}
