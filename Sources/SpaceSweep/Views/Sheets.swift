#if canImport(SwiftUI)
import SwiftUI
import CleanCore

// MARK: - Delete confirmation

struct DeleteSheet: View {
    @Environment(AppModel.self) private var model
    @State private var permanently = false

    private var entries: [FileEntry] { model.pendingDeletion }
    private var total: Int64 { entries.reduce(0) { $0 + $1.size } }
    private var carefulCount: Int { entries.filter { $0.risk == .careful }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: permanently ? "trash.slash.fill" : "trash.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(permanently ? "Permanently delete \(entries.count) item\(entries.count == 1 ? "" : "s")?" : "Move \(entries.count) item\(entries.count == 1 ? "" : "s") to the Trash?")
                        .font(.title3.weight(.semibold))
                    Text("This frees about \(ByteFormatter.string(total)).")
                        .foregroundStyle(.secondary)
                }
            }

            if carefulCount > 0 {
                Label("\(carefulCount) of these are marked “Careful” — deleting may lose data or need a re-download.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            List(entries) { e in
                HStack(spacing: 8) {
                    Image(nsImage: MacServices.icon(for: e))
                        .resizable()
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name).lineLimit(1).truncationMode(.middle)
                        Text(PathUtils.abbreviate(e.path))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    RiskBadge(risk: e.risk ?? .review, compact: true)
                    SizeText(bytes: e.size)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
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
                Button("Cancel") { model.showDeleteSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isDeleting)
                Button(role: .destructive) {
                    model.confirmDelete(permanently: permanently)
                } label: {
                    Text(permanently ? "Delete \(ByteFormatter.string(total))" : "Move \(ByteFormatter.string(total)) to Trash")
                        .frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isDeleting)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 620)
        .onAppear { permanently = model.settings.permanentDelete }
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
