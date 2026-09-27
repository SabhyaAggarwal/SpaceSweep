#if canImport(AppKit)
import AppKit
import CoreServices
import UniformTypeIdentifiers
import CleanCore

/// Thin wrappers around AppKit / Foundation things the engine deliberately doesn't know about.
enum MacServices {
    // MARK: Finder

    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Icons

    private static var iconCache: [String: NSImage] = [:]
    private static let iconLock = NSLock()

    /// Finder icon for a path, cached by extension (or by full path for folders/bundles).
    static func icon(for entry: FileEntry) -> NSImage {
        let key = entry.isDirectory ? entry.path : (entry.url.pathExtension.isEmpty ? "file" : "ext:" + entry.url.pathExtension.lowercased())
        iconLock.lock(); defer { iconLock.unlock() }
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if entry.isDirectory || entry.url.pathExtension.isEmpty {
            image = NSWorkspace.shared.icon(forFile: entry.path)
        } else {
            image = NSWorkspace.shared.icon(for: UTTypeHelper.type(forExtension: entry.url.pathExtension))
        }
        if iconCache.count > 2000 { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }

    // MARK: Installed apps

    private static var installedCache: [String: Bool] = [:]
    private static let installedLock = NSLock()

    /// True if any app with this bundle identifier exists on the Mac (Launch Services lookup).
    static func isAppInstalled(_ bundleID: String) -> Bool {
        installedLock.lock()
        if let hit = installedCache[bundleID] { installedLock.unlock(); return hit }
        installedLock.unlock()
        var found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
        if !found {
            // Login items / helpers often live inside another app; a running process is proof enough.
            found = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty == false
        }
        installedLock.lock(); installedCache[bundleID] = found; installedLock.unlock()
        return found
    }

    // MARK: Spotlight

    /// Finder's "Date Last Opened" (kMDItemLastUsedDate). nil when Spotlight has no record of the item being opened.
    static func lastUsedDate(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: Full Disk Access

    /// Probes a few TCC-protected folders. If any can be listed, we have Full Disk Access.
    static func checkFullDiskAccess() -> Bool {
        let probes = ["~/Library/Mail", "~/Library/Safari", "~/Library/Messages", "~/Library/Application Support/MobileSync/Backup"]
            .map(PathUtils.expand)
            .filter { FileManager.default.fileExists(atPath: $0) }
        if probes.isEmpty { return true }
        for p in probes {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: p)
                return true
            } catch {
                if !Walker.isPermissionError(error as NSError) { return true }
            }
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Shell

    /// Name of the startup volume ("Macintosh HD" on most Macs).
    static var startupVolumeName: String {
        (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? "Macintosh HD"
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a command synchronously and returns (exit status, combined output). Call off the main thread.
    static func run(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "Could not start \(launchPath): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum UTTypeHelper {
    static func type(forExtension ext: String) -> UTType {
        UTType(filenameExtension: ext) ?? .data
    }
}
#endif
