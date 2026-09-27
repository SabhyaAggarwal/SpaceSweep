#if canImport(SwiftUI)
import SwiftUI
import CleanCore

struct CategoryDetailView: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory

    @State private var sortOrder: [KeyPathComparator<FileEntry>] = [KeyPathComparator(\FileEntry.size, order: .reverse)]
    @State private var searchText = ""
    @State private var ageFilter: AgeFilter = .any
    @State private var riskFilter: RiskLevel? = nil
    @State private var showPaths = false

    private var result: ScanResult? { model.results[category.id] }
    private var isScanning: Bool { model.scanning.contains(category.id) }

    private var selectionBinding: Binding<Set<String>> {
        Binding(
            get: { model.selection[category.id] ?? [] },
            set: { model.selection[category.id] = $0 }
        )
    }

    private var rows: [FileEntry] {
        guard let result else { return [] }
        let now = Date()
        var list = result.entries
        if let days = ageFilter.days {
            list = list.filter { ($0.daysSinceLastUsed(now: now) ?? 0) >= days }
        }
        if let riskFilter {
            list = list.filter { $0.risk == riskFilter }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) || $0.path.lowercased().contains(q) || ($0.note?.lowercased().contains(q) ?? false) }
        }
        return list.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let result, result.needsFullDiskAccess {
                PermissionBanner(deniedPaths: result.permissionDeniedPaths)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            content
            Divider()
            footer
        }
        .navigationTitle(category.title)
        .navigationSubtitle(category.subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Filter by name, path or note")
        .toolbar { toolbarContent }
        .task(id: category.id) {
            if result == nil, !isScanning { model.scan(category.id) }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: category.symbol)
                    .font(.system(size: 30))
                    .foregroundStyle(category.risk.color)
                    .frame(width: 44, height: 44)
                    .background(category.risk.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        RiskBadge(risk: category.risk)
                        if let result {
                            Text("\(result.entries.count) item\(result.entries.count == 1 ? "" : "s") · \(ByteFormatter.string(result.totalSize)) · scanned \(AgeFormatter.relative(result.finishedAt)) in \(String(format: "%.1f", result.duration)) s")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(category.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result, !result.infoLines.isEmpty {
                        ForEach(result.infoLines, id: \.self) { line in
                            Label(line, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !category.paths.isEmpty {
                        DisclosureGroup(isExpanded: $showPaths) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(category.paths.filter { FileManager.default.fileExists(atPath: $0) }, id: \.self) { p in
                                    HStack(spacing: 6) {
                                        Text(PathUtils.abbreviate(p))
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                        Button {
                                            MacServices.reveal([p])
                                        } label: {
                                            Image(systemName: "arrow.up.forward.square")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .help("Reveal in Finder")
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("Locations")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let result {
            if result.entries.isEmpty {
                ContentUnavailableView {
                    Label(isScanning ? "Scanning…" : "Nothing here", systemImage: isScanning ? "magnifyingglass" : "checkmark.circle")
                } description: {
                    Text(isScanning ? progressText : emptyMessage(result))
                }
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: searchText.isEmpty ? ageFilter.rawValue : searchText)
            } else {
                table
            }
        } else if let error = model.scanErrors[category.id] {
            ContentUnavailableView {
                Label("Scan failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { model.scan(category.id) }
            }
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(isScanning ? "Scanning…" : "Ready to scan")
                    .font(.headline)
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
                if !isScanning {
                    Button("Scan Now") { model.scan(category.id) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var progressText: String {
        guard let p = model.progress[category.id] else { return " " }
        var parts: [String] = []
        if p.itemsVisited > 0 { parts.append("\(p.itemsVisited.formatted()) files") }
        if p.bytesFound > 0 { parts.append(ByteFormatter.string(p.bytesFound)) }
        if !p.currentPath.isEmpty { parts.append(p.currentPath) }
        return parts.joined(separator: " · ")
    }

    private func emptyMessage(_ result: ScanResult) -> String {
        if result.needsFullDiskAccess { return "The folders for this category couldn't be read. Grant Full Disk Access and rescan." }
        switch category.kind {
        case .largeFiles: return "No files over \(ByteFormatter.string(model.settings.largeFileThresholdBytes)) found. Lower the threshold in Settings to see more."
        case .staleFiles: return "Nothing over 1 MB has gone unopened for \(model.settings.staleDays) days."
        case .duplicates: return "No identical files over \(ByteFormatter.string(model.settings.duplicateMinBytes)) found."
        case .devArtifacts: return "No build or dependency folders found under your project roots (see Settings)."
        case .leftovers: return "Every support folder belongs to an app that's still installed."
        default: return "These locations are empty or don't exist on this Mac."
        }
    }

    private var table: some View {
        Table(rows, selection: selectionBinding, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                EntryNameCell(entry: entry, showPath: category.kind.showsPathInName)
            }
            .width(min: 220, ideal: 360)

            TableColumn("Size", value: \.size) { entry in
                SizeText(bytes: entry.size)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90, max: 110)

            TableColumn("Last Opened", value: \.lastUsedSortKey) { entry in
                Text(AgeFormatter.relative(entry.lastUsed))
                    .foregroundStyle(ageColor(entry))
                    .help(entry.accessed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "No access time recorded")
            }
            .width(min: 100, ideal: 130, max: 170)

            TableColumn("Modified", value: \.modifiedSortKey) { entry in
                Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 110, max: 140)

            TableColumn("Risk") { entry in
                RiskBadge(risk: entry.risk ?? category.risk, compact: true)
            }
            .width(40)

            TableColumn("Kind", value: \.kind) { entry in
                Text(entry.kind)
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 70, max: 100)

            TableColumn("Location", value: \.path) { entry in
                Text(PathUtils.abbreviate((entry.path as NSString).deletingLastPathComponent))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.path)
            }
            .width(min: 140, ideal: 260)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            let picked = entries(for: ids)
            if picked.count == 1, let e = picked.first {
                Button("Open") { MacServices.open(e.path) }
                Button("Reveal in Finder") { MacServices.reveal([e.path]) }
                Button("Copy Path") { MacServices.copyToClipboard(e.path) }
            } else if !picked.isEmpty {
                Button("Reveal \(picked.count) Items in Finder") { MacServices.reveal(picked.map(\.path)) }
                Button("Copy Paths") { MacServices.copyToClipboard(picked.map(\.path).joined(separator: "\n")) }
            }
            if !picked.isEmpty {
                Divider()
                Button("Move to Trash…", role: .destructive) { model.requestDelete(picked) }
            }
        } primaryAction: { ids in
            MacServices.reveal(entries(for: ids).map(\.path))
        }
    }

    private func entries(for ids: Set<String>) -> [FileEntry] {
        rows.filter { ids.contains($0.id) }
    }

    private func ageColor(_ entry: FileEntry) -> Color {
        guard let days = entry.daysSinceLastUsed() else { return .secondary }
        if days >= 365 { return .red }
        if days >= 90 { return .orange }
        return .primary
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            if let action = category.specialAction {
                Button {
                    model.perform(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
                .disabled(model.runningAction)
                .help(action.help)
            }

            Menu {
                Picker("Age", selection: $ageFilter) {
                    ForEach(AgeFilter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.inline)
                Divider()
                Picker("Risk", selection: $riskFilter) {
                    Text("Any risk").tag(RiskLevel?.none)
                    ForEach(RiskLevel.allCases, id: \.self) { r in Text(r.title).tag(RiskLevel?.some(r)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: ageFilter == .any && riskFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Filter rows by age or risk")

            Menu {
                Button("Select All") { model.selection[category.id] = Set(rows.map(\.id)) }
                Button("Select Only Safe Items") { model.selectSafe(in: category.id) }
                Menu("Select Not Opened In…") {
                    Button("30 days") { model.selectOlder(than: 30, in: category.id) }
                    Button("90 days") { model.selectOlder(than: 90, in: category.id) }
                    Button("6 months") { model.selectOlder(than: 180, in: category.id) }
                    Button("1 year") { model.selectOlder(than: 365, in: category.id) }
                }
                Divider()
                Button("Deselect All") { model.deselectAll(in: category.id) }
            } label: {
                Label("Select", systemImage: "checklist")
            }
            .disabled(result == nil || result!.entries.isEmpty)

            if isScanning {
                Button {
                    model.cancel(category.id)
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .help("Stop this scan")
            } else {
                Button {
                    model.scan(category.id)
                } label: {
                    Label(result == nil ? "Scan" : "Rescan", systemImage: "arrow.clockwise")
                }
                .help("Scan this category again")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if isScanning {
                ProgressView().controlSize(.small)
                Text(progressText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let result {
                Text("\(rows.count) of \(result.entries.count) shown · \(ByteFormatter.string(rows.reduce(0) { $0 + $1.size }))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            let selected = model.selectedEntries(in: category.id)
            if !selected.isEmpty {
                Text("\(selected.count) selected · \(ByteFormatter.string(model.selectedSize(in: category.id)))")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                Button {
                    MacServices.reveal(selected.prefix(50).map(\.path))
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .help("Show the selected items in Finder")
            }
            Button(role: .destructive) {
                model.requestDeleteSelection(in: category.id)
            } label: {
                Label(model.settings.permanentDelete ? "Delete Permanently…" : "Move to Trash…", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(selected.isEmpty || isScanning)
            .tint(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Helpers

extension ScanKind {
    /// Rows from tree scans come from many folders, so the name cell should show where each lives.
    var showsPathInName: Bool {
        switch self {
        case .largeFiles, .staleFiles, .duplicates, .devArtifacts, .leftovers, .screenshots: return true
        default: return false
        }
    }
}

extension SpecialAction {
    var title: String {
        switch self {
        case .deleteUnavailableSimulators: return "Delete Unavailable Simulators"
        case .emptyTrash: return "Empty Trash"
        case .brewCleanup: return "Run brew cleanup"
        }
    }

    var symbol: String {
        switch self {
        case .deleteUnavailableSimulators: return "iphone.slash"
        case .emptyTrash: return "trash.slash"
        case .brewCleanup: return "mug"
        }
    }

    var help: String {
        switch self {
        case .deleteUnavailableSimulators: return "Runs “xcrun simctl delete unavailable” — removes simulators whose runtime is no longer installed"
        case .emptyTrash: return "Permanently deletes everything in the Trash"
        case .brewCleanup: return "Runs “brew cleanup -s --prune=all” to remove old formula versions and downloads"
        }
    }
}
#endif
