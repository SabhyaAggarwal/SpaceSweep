#if canImport(SwiftUI)
import SwiftUI
import Observation
import CleanCore

/// Categories that walk large trees; they run only on demand or via "Scan Everything".
private let deepCategoryIDs: Set<String> = ["files.large", "files.stale", "files.duplicates", "dev.artifacts", "apps.leftovers"]

@MainActor
@Observable
final class AppModel {
    // MARK: Catalog & navigation

    let categories: [CleanCategory] = Catalog.available()
    /// nil or "overview" shows the dashboard.
    var selectedCategoryID: String? = "overview"

    // MARK: Scan state

    var results: [String: ScanResult] = [:]
    var progress: [String: ScanProgress] = [:]
    var scanning: Set<String> = []
    var scanErrors: [String: String] = [:]
    var selection: [String: Set<String>] = [:]

    // MARK: Disk & permissions

    var diskUsage: DiskUsage? = DiskUsage.current()
    var hasFullDiskAccess = true

    // MARK: Settings

    var settings: ScanSettings {
        didSet { AppModel.save(settings) }
    }

    // MARK: Deletion flow

    var pendingDeletion: [FileEntry] = []
    var showDeleteSheet = false
    var isDeleting = false
    var deleteDone = 0
    var deleteTotal = 0
    var lastReport: CleanReport?
    var showReport = false

    // MARK: Special actions

    var showEmptyTrashConfirm = false
    var actionOutput: ActionOutput?
    var runningAction = false

    struct ActionOutput: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init() {
        settings = AppModel.load()
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        refreshDisk()
        hasFullDiskAccess = MacServices.checkFullDiskAccess()
        // Cheap, location-based categories start right away so the dashboard fills in.
        for c in categories where !deepCategoryIDs.contains(c.id) {
            scan(c.id)
        }
    }

    func refreshDisk() {
        diskUsage = DiskUsage.current()
    }

    // MARK: - Derived numbers

    var totalFound: Int64 { results.values.reduce(0) { $0 + $1.totalSize } }

    var totalSafe: Int64 {
        results.values.reduce(0) { sum, r in
            sum + r.entries.filter { $0.risk == .safe }.reduce(0) { $0 + $1.size }
        }
    }

    func size(of categoryID: String) -> Int64? { results[categoryID]?.totalSize }

    func groupTotal(_ group: CategoryGroup) -> Int64 {
        categories.filter { $0.group == group }.reduce(0) { $0 + (size(of: $1.id) ?? 0) }
    }

    /// Largest rows across all categories, for the dashboard.
    func topEntries(limit: Int = 12) -> [(FileEntry, CleanCategory)] {
        var all: [(FileEntry, CleanCategory)] = []
        for c in categories {
            guard let r = results[c.id] else { continue }
            // Skip duplicate "originals" – they aren't candidates for removal.
            for e in r.entries.prefix(40) where !(c.id == "files.duplicates" && e.risk == .careful) {
                all.append((e, c))
            }
        }
        // De-duplicate paths that appear in several categories (e.g. a big .dmg in Downloads + Large Files).
        var seen = Set<String>()
        return all.sorted { $0.0.size > $1.0.size }.filter { seen.insert($0.0.path).inserted }.prefix(limit).map { $0 }
    }

    func selectedEntries(in categoryID: String) -> [FileEntry] {
        guard let r = results[categoryID] else { return [] }
        let ids = selection[categoryID] ?? []
        return r.entries.filter { ids.contains($0.id) }
    }

    func selectedSize(in categoryID: String) -> Int64 {
        selectedEntries(in: categoryID).reduce(0) { $0 + $1.size }
    }

    // MARK: - Scanning

    func scan(_ id: String) {
        guard let category = Catalog.category(id), !scanning.contains(id) else { return }
        scanning.insert(id)
        scanErrors[id] = nil
        progress[id] = ScanProgress()
        let settings = self.settings
        let installedHook: @Sendable (String) -> Bool = { MacServices.isAppInstalled($0) }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let ctx = ScanContext(settings: settings, progress: { p in
                Task { @MainActor [weak self] in
                    self?.progress[id] = p
                }
            }, isAppInstalled: installedHook)
            do {
                let result = try ScanEngine.scan(category, context: ctx)
                await MainActor.run { [weak self] in self?.finish(id, result: result) }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.scanning.remove(id)
                    self?.progress[id] = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.scanning.remove(id)
                    self?.progress[id] = nil
                    self?.scanErrors[id] = error.localizedDescription
                }
            }
        }
        tasks[id] = task
    }

    private func finish(_ id: String, result: ScanResult) {
        results[id] = result
        scanning.remove(id)
        progress[id] = nil
        tasks[id] = nil
        // Pre-select rows that are always safe in categories that are themselves "safe".
        if let cat = Catalog.category(id), cat.risk == .safe {
            selection[id] = Set(result.entries.filter { $0.risk == .safe }.map(\.id))
        } else if selection[id] == nil {
            selection[id] = []
        }
        if result.needsFullDiskAccess { hasFullDiskAccess = MacServices.checkFullDiskAccess() }
    }

    func scanAll() {
        for c in categories { scan(c.id) }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    func cancelAll() {
        for (_, t) in tasks { t.cancel() }
        tasks.removeAll()
    }

    // MARK: - Selection helpers

    func selectAll(in id: String) {
        selection[id] = Set(results[id]?.entries.map(\.id) ?? [])
    }

    func selectSafe(in id: String) {
        selection[id] = Set(results[id]?.entries.filter { $0.risk == .safe }.map(\.id) ?? [])
    }

    func selectOlder(than days: Int, in id: String) {
        let now = Date()
        selection[id] = Set(results[id]?.entries.filter { ($0.daysSinceLastUsed(now: now) ?? 0) >= days }.map(\.id) ?? [])
    }

    func deselectAll(in id: String) {
        selection[id] = []
    }

    // MARK: - Deletion

    func requestDelete(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        pendingDeletion = entries
        showDeleteSheet = true
    }

    func requestDeleteSelection(in id: String) {
        requestDelete(selectedEntries(in: id))
    }

    func confirmDelete(permanently: Bool) {
        let entries = pendingDeletion
        guard !entries.isEmpty else { return }
        isDeleting = true
        deleteDone = 0
        deleteTotal = entries.count
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = Cleaner.remove(entries, permanently: permanently) { done, total in
                Task { @MainActor [weak self] in
                    self?.deleteDone = done
                    self?.deleteTotal = total
                }
            }
            await MainActor.run { [weak self] in self?.apply(report) }
        }
    }

    private func apply(_ report: CleanReport) {
        let removed = Set(report.removed.map(\.path))
        for (id, r) in results {
            let remaining = r.entries.filter { !removed.contains($0.path) }
            if remaining.count != r.entries.count {
                results[id] = ScanResult(categoryID: id, entries: remaining,
                                         permissionDeniedPaths: r.permissionDeniedPaths, errors: r.errors,
                                         finishedAt: r.finishedAt, duration: r.duration, infoLines: r.infoLines)
                selection[id] = (selection[id] ?? []).subtracting(removed)
            }
        }
        isDeleting = false
        showDeleteSheet = false
        pendingDeletion = []
        lastReport = report
        showReport = true
        refreshDisk()
        // Things moved to the Trash now show up there.
        if !report.permanently, categories.contains(where: { $0.id == "sys.trash" }) {
            scan("sys.trash")
        }
    }

    // MARK: - Special actions

    func perform(_ action: SpecialAction) {
        switch action {
        case .emptyTrash:
            showEmptyTrashConfirm = true
        case .deleteUnavailableSimulators:
            runShell(title: "Delete unavailable simulators", "/usr/bin/xcrun", ["simctl", "delete", "unavailable"], rescan: "xcode.simulators")
        case .brewCleanup:
            guard let brew = MacServices.brewPath else {
                actionOutput = ActionOutput(title: "Homebrew not found", text: "Neither /opt/homebrew/bin/brew nor /usr/local/bin/brew exists.")
                return
            }
            runShell(title: "brew cleanup", brew, ["cleanup", "-s", "--prune=all"], rescan: "dev.pkgcaches")
        }
    }

    func emptyTrashNow() {
        runningAction = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let report = Cleaner.emptyTrash()
            await MainActor.run { [weak self] in
                self?.runningAction = false
                self?.apply(report)
                self?.scan("sys.trash")
            }
        }
    }

    private func runShell(title: String, _ launchPath: String, _ args: [String], rescan: String?) {
        runningAction = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let (status, output) = MacServices.run(launchPath, args)
            await MainActor.run { [weak self] in
                self?.runningAction = false
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                self?.actionOutput = ActionOutput(title: title, text: trimmed.isEmpty ? (status == 0 ? "Done." : "Exited with status \(status).") : trimmed)
                self?.refreshDisk()
                if let rescan { self?.scan(rescan) }
            }
        }
    }

    // MARK: - Settings persistence

    private static let settingsKey = "SpaceSweep.settings.v1"

    private static func load() -> ScanSettings {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(ScanSettings.self, from: data) {
            return s
        }
        return ScanSettings()
    }

    private static func save(_ s: ScanSettings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }
}
#endif
