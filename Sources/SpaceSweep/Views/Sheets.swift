#if canImport(SwiftUI)
import SwiftUI
import CleanCore

// MARK: - Delete confirmation / review

struct DeleteSheet: View {
    @Environment(AppModel.self) private var model
    @State private var permanently = false
    @State private var expanded: Set<String> = []

    private struct Group: Identifiable {
        let id: String          // category id or "selection"
        let title: String
        let entries: [FileEntry]
    }

    private var groups: [Group] {
        var byCategory: [String: [FileEntry]] = [:]
        var loose: [FileEntry] = []
        for e in model.pendingDeletion {
            if let c = model.pendingCategory[e.path] { byCategory[c, default: []].append(e) } else { loose.append(e) }
        }
        var out: [Group] = model.categories.compactMap { c in
            guard let list = byCategory[c.id] else { return nil }
            return Group(id: c.id, title: c.title, entries: list.sorted { $0.size > $1.size })
        }
        if !loose.isEmpty { out.append(Group(id: "selection", title: "Selected items", entries: loose)) }
        return out
    }

    private var included: [FileEntry] { model.pendingIncluded }
    private var total: Int64 { included.reduce(0) { $0 + $1.size } }
    private var carefulCount: Int { included.filter { $0.risk == .careful }.count }
    private var multi: Bool { groups.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: permanently ? "trash.slash.fill" : "trash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(multi ? "Review what will be removed" : (permanently ? "Permanently delete \(included.count) item\(included.count == 1 ? "" : "s")?" : "Move \(included.count) item\(included.count == 1 ? "" : "s") to the Trash?"))
                        .font(.title3.weight(.semibold))
                    Text(multi
                         ? "\(included.count) of \(model.pendingDeletion.count) items ticked across \(groups.count) categories · frees about \(ByteFormatter.string(total))"
                         : "This frees about \(ByteFormatter.string(total)).")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if multi {
                    Button("Tick All") { for e in model.pendingDeletion { model.setPending(e, included: true) } }
                    Button("Safe Only") {
                        for e in model.pendingDeletion { model.setPending(e, included: e.risk == .safe) }
                    }
                }
            }
            .controlSize(.small)

            if !model.scanning.isEmpty {
                Label("\(model.scanning.count) scan\(model.scanning.count == 1 ? " is" : "s are") still running — their results aren't included yet.", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            if carefulCount > 0 {
                Label("\(carefulCount) ticked item\(carefulCount == 1 ? " is" : "s are") marked “Careful” — deleting may lose data or need a re-download.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            List {
                ForEach(groups) { group in
                    if multi {
                        DisclosureGroup(isExpanded: expandedBinding(group.id)) {
                            ForEach(group.entries) { e in row(e) }
                        } label: {
                            groupHeader(group)
                        }
                    } else {
                        ForEach(group.entries) { e in row(e) }
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 380)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Toggle(isOn: $permanently) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Delete permanently (skip the Trash)")
                    Text("Faster and frees space immediately, but can't be undone. Also needed for items on external drives that have no Trash.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if model.isDeleting {
                ProgressView(value: Double(model.deleteDone), total: Double(max(model.deleteTotal, 1))) {
                    Text("Removing \(model.deleteDone) of \(model.deleteTotal)…")
                        .font(.callout)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { model.cancelPendingDeletion() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isDeleting)
                Button(role: .destructive) {
                    model.confirmDelete(permanently: permanently)
                } label: {
                    Text(permanently ? "Delete \(ByteFormatter.string(total))" : "Move \(ByteFormatter.string(total)) to Trash")
                        .frame(minWidth: 160)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isDeleting || included.isEmpty)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: multi ? 720 : 620)
        .onAppear {
            permanently = model.settings.permanentDelete
            // Open the biggest groups so the review isn't an empty list of headers.
            expanded = Set(groups.sorted { size(of: $0) > size(of: $1) }.prefix(3).map(\.id))
        }
    }

    private func size(of group: Group) -> Int64 { group.entries.reduce(0) { $0 + $1.size } }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private func groupHeader(_ group: Group) -> some View {
        let inc = group.entries.filter { !model.pendingExcluded.contains($0.path) }
        let allOn = inc.count == group.entries.count
        let noneOn = inc.isEmpty
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !noneOn }, set: { model.setPending(categoryID: group.id, included: $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .opacity(allOn || noneOn ? 1 : 0.55)
            .help(allOn ? "Untick everything in this category" : "Tick everything in this category")
            if let cat = Catalog.category(group.id) {
                Image(systemName: cat.symbol).foregroundStyle(cat.risk.color).frame(width: 18)
            }
            Text(group.title).fontWeight(.semibold)
            Text("\(inc.count)/\(group.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            SizeText(bytes: inc.reduce(0) { $0 + $1.size }, emphasized: true)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func row(_ e: FileEntry) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !model.pendingExcluded.contains(e.path) },
                                 set: { model.setPending(e, included: $0) })) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            Image(nsImage: MacServices.icon(for: e))
                .resizable()
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(PathUtils.abbreviate(e.path))
                    if let d = e.lastUsed {
                        Text("· opened \(AgeFormatter.relative(d))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer()
            Button {
                MacServices.reveal([e.path])
            } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reveal in Finder")
            RiskBadge(risk: e.risk ?? .review, compact: true)
            SizeText(bytes: e.size)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
        .opacity(model.pendingExcluded.contains(e.path) ? 0.5 : 1)
    }
}

// MARK: - Report

struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    let report: CleanReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let report {
                HStack(spacing: 12) {
                    Image(systemName: report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(report.failed.isEmpty ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.removed.isEmpty ? "Nothing was removed" : "Freed \(ByteFormatter.string(report.bytesFreed))")
                            .font(.title3.weight(.semibold))
                        Text(summary(report))
                            .foregroundStyle(.secondary)
                    }
                }
                if !report.failed.isEmpty {
                    List(report.failed) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(PathUtils.abbreviate(f.path)).lineLimit(1).truncationMode(.middle)
                            Text(f.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    if report.failed.contains(where: { $0.message.contains("Permission") }) {
                        HStack {
                            Text("Some items are protected by macOS. Grant Full Disk Access, or delete them from Finder.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open System Settings") { MacServices.openFullDiskAccessSettings() }
                        }
                    }
                }
                if !report.permanently, !report.removed.isEmpty {
                    Text("The space is freed once you empty the Trash (System & Caches → Trash → Empty Trash).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                if let report, !report.permanently, !report.removed.isEmpty {
                    Button("Empty Trash Now…") {
                        model.showReport = false
                        model.showEmptyTrashConfirm = true
                    }
                }
                Button("Done") { model.showReport = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func summary(_ r: CleanReport) -> String {
        var parts: [String] = []
        if !r.removed.isEmpty { parts.append("\(r.removed.count) item\(r.removed.count == 1 ? "" : "s") \(r.permanently ? "deleted" : "moved to the Trash")") }
        if !r.failed.isEmpty { parts.append("\(r.failed.count) couldn't be removed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Shell output

struct ActionOutputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let output: AppModel.ActionOutput

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(output.title)
                .font(.title3.weight(.semibold))
            ScrollView {
                Text(output.text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 120, maxHeight: 320)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
#endif
