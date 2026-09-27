#if canImport(SwiftUI)
import SwiftUI
import CleanCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $model.selectedCategoryID)
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .sheet(isPresented: $model.showDeleteSheet) {
            DeleteSheet()
                .environment(model)
        }
        .sheet(isPresented: $model.showReport) {
            ReportSheet(report: model.lastReport)
                .environment(model)
        }
        .sheet(item: $model.actionOutput) { output in
            ActionOutputSheet(output: output)
        }
        .confirmationDialog("Empty the Trash?", isPresented: $model.showEmptyTrashConfirm, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { model.emptyTrashNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash (\(ByteFormatter.string(model.size(of: "sys.trash") ?? 0))) will be permanently deleted. This can't be undone.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedCategoryID, id != "overview", let category = Catalog.category(id) {
            CategoryDetailView(category: category)
                .id(id)
        } else {
            OverviewView()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Label("Overview", systemImage: "internaldrive")
                .tag("overview")

            ForEach(CategoryGroup.allCases, id: \.self) { group in
                let cats = model.categories.filter { $0.group == group }
                if !cats.isEmpty {
                    Section {
                        ForEach(cats) { cat in
                            SidebarRow(category: cat)
                                .tag(cat.id)
                        }
                    } header: {
                        HStack {
                            Text(group.rawValue)
                            Spacer()
                            let total = model.groupTotal(group)
                            if total > 0 {
                                SizeText(bytes: total).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarFooter()
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory

    var body: some View {
        HStack(spacing: 8) {
            Label {
                Text(category.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: category.symbol)
                    .foregroundStyle(category.risk.color)
            }
            Spacer(minLength: 4)
            if model.scanning.contains(category.id) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
            } else if let size = model.size(of: category.id) {
                SizeText(bytes: size)
                    .font(.callout)
                    .foregroundStyle(size > 0 ? .primary : .tertiary)
            } else if model.scanErrors[category.id] != nil {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            }
            if model.results[category.id]?.needsFullDiskAccess == true {
                Image(systemName: "lock")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Some folders were skipped — needs Full Disk Access")
            }
        }
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let usage = model.diskUsage {
                HStack {
                    Text("Free").foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: usage.free, emphasized: true)
                }
                .font(.callout)
                ProgressView(value: Double(usage.used), total: Double(max(usage.total, 1)))
                    .tint(usage.free < usage.total / 10 ? .red : .accentColor)
                if usage.purgeable > 0 {
                    Text("+ \(ByteFormatter.string(usage.purgeable)) purgeable by macOS")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.totalFound > 0 {
                HStack {
                    Text("Found").foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: model.totalFound)
                }
                .font(.callout)
                HStack {
                    Text("Safe to delete").foregroundStyle(.secondary)
                    Spacer()
                    SizeText(bytes: model.totalSafe).foregroundStyle(.green)
                }
                .font(.callout)
                CleanEverythingButton()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
