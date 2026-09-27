#if canImport(SwiftUI)
import SwiftUI
import CleanCore

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                diskCard
                if !model.hasFullDiskAccess {
                    PermissionBanner()
                }
                categoriesGrid
                topItems
            }
            .padding(20)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !model.scanning.isEmpty {
                    Button {
                        model.cancelAll()
                    } label: {
                        Label("Stop", systemImage: "stop.circle")
                    }
                    .help("Stop all scans")
                }
                Button {
                    model.scanAll()
                } label: {
                    Label(model.results.isEmpty ? "Scan Everything" : "Rescan Everything", systemImage: "arrow.clockwise")
                }
                .disabled(model.scanning.count == model.categories.count)
                .help("Scan every category, including the slower deep scans (⇧⌘R)")
            }
        }
    }

    // MARK: Disk

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(MacServices.startupVolumeName)
                    .font(.title2.weight(.semibold))
                Spacer()
                if let usage = model.diskUsage {
                    Text("\(ByteFormatter.string(usage.used)) of \(ByteFormatter.string(usage.total)) used")
                        .foregroundStyle(.secondary)
                }
            }
            if let usage = model.diskUsage {
                let safe = min(model.totalSafe, usage.used)
                let review = min(max(0, model.totalFound - model.totalSafe), usage.used - safe)
                StorageBar(segments: [
                    StorageSegment(label: "Used", bytes: usage.used - safe - review, color: .accentColor),
                    StorageSegment(label: "Safe to delete", bytes: safe, color: .green),
                    StorageSegment(label: "Review", bytes: review, color: .orange),
                    StorageSegment(label: "Purgeable", bytes: usage.purgeable, color: .gray.opacity(0.6)),
                    StorageSegment(label: "Free", bytes: usage.free, color: .clear),
                ], total: usage.total)
            }
            HStack(spacing: 12) {
                StatTile(title: "Free now", value: ByteFormatter.string(model.diskUsage?.free ?? 0),
                         subtitle: (model.diskUsage?.purgeable ?? 0) > 0 ? "+ \(ByteFormatter.string(model.diskUsage?.purgeable ?? 0)) macOS can purge on its own" : nil)
                StatTile(title: "Safe to delete", value: ByteFormatter.string(model.totalSafe),
                         subtitle: "Caches, build products & logs that get regenerated", tint: .green)
                StatTile(title: "Worth reviewing", value: ByteFormatter.string(max(0, model.totalFound - model.totalSafe)),
                         subtitle: "Downloads, old files, media, backups", tint: .orange)
                StatTile(title: "Scanned", value: "\(model.results.count) / \(model.categories.count)",
                         subtitle: model.scanning.isEmpty ? "categories" : "\(model.scanning.count) running…")
            }
        }
        .padding(16)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
    }

    // MARK: Categories

    private var categoriesGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(CategoryGroup.allCases, id: \.self) { group in
                let cats = model.categories.filter { $0.group == group }
                if !cats.isEmpty {
                    HStack {
                        Label(group.rawValue, systemImage: group.symbol)
                            .font(.headline)
                        Spacer()
                        SizeText(bytes: model.groupTotal(group)).foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(cats) { cat in
                            CategoryCard(category: cat)
                        }
                    }
                }
            }
        }
    }

    // MARK: Top items

    private var topItems: some View {
        let top = model.topEntries()
        return VStack(alignment: .leading, spacing: 8) {
            if !top.isEmpty {
                Text("Biggest things found")
                    .font(.headline)
                    .padding(.top, 6)
                VStack(spacing: 0) {
                    ForEach(top.indices, id: \.self) { index in
                        TopItemRow(entry: top[index].0, category: top[index].1)
                        if index < top.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
            }
        }
    }
}

// MARK: - Card

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory
    @State private var hovering = false

    var body: some View {
        Button {
            model.selectedCategoryID = category.id
            if model.results[category.id] == nil, !model.scanning.contains(category.id) {
                model.scan(category.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: category.symbol)
                        .font(.title3)
                        .foregroundStyle(category.risk.color)
                        .frame(width: 24)
                    Spacer()
                    RiskBadge(risk: category.risk, compact: true)
                }
                Text(category.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(category.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                HStack {
                    if model.scanning.contains(category.id) {
                        ProgressView().controlSize(.small)
                        if let p = model.progress[category.id], p.bytesFound > 0 {
                            SizeText(bytes: p.bytesFound).font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Scanning…").font(.callout).foregroundStyle(.secondary)
                        }
                    } else if let size = model.size(of: category.id) {
                        SizeText(bytes: size, emphasized: true)
                            .font(.title3)
                        if let count = model.results[category.id]?.entries.count, count > 0 {
                            Text("\(count) item\(count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not scanned yet")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.accentColor.opacity(0.08) : Color.clear)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Top item row

private struct TopItemRow: View {
    @Environment(AppModel.self) private var model
    let entry: FileEntry
    let category: CleanCategory

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: MacServices.icon(for: entry))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(category.title)
                    Text("·")
                    Text(PathUtils.abbreviate((entry.path as NSString).deletingLastPathComponent))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let d = entry.lastUsed {
                        Text("·")
                        Text("opened \(AgeFormatter.relative(d))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            RiskBadge(risk: entry.risk ?? category.risk, compact: true)
            SizeText(bytes: entry.size, emphasized: true)
                .frame(width: 80, alignment: .trailing)
            Menu {
                Button("Show in Category") { model.selectedCategoryID = category.id }
                Button("Reveal in Finder") { MacServices.reveal([entry.path]) }
                Divider()
                Button("Move to Trash…", role: .destructive) { model.requestDelete([entry]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { MacServices.reveal([entry.path]) }
    }
}
#endif
