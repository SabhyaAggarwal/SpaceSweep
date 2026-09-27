#if canImport(SwiftUI)
import SwiftUI
import CleanCore

extension Color {
    /// Card background that adapts to light/dark mode.
    static let card = Color(nsColor: .controlBackgroundColor)
}

// MARK: - Risk badge

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: return .green
        case .review: return .orange
        case .careful: return .red
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.shield"
        case .review: return "eye"
        case .careful: return "exclamationmark.triangle"
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: risk.symbol)
            if !compact { Text(risk.title) }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, compact ? 5 : 8)
        .padding(.vertical, 3)
        .background(risk.color.opacity(0.15), in: Capsule())
        .foregroundStyle(risk.color)
        .help(risk.title)
    }
}

// MARK: - Size text

struct SizeText: View {
    let bytes: Int64
    var emphasized = false

    var body: some View {
        Text(ByteFormatter.short(bytes))
            .monospacedDigit()
            .fontWeight(emphasized ? .semibold : .regular)
    }
}

// MARK: - Storage bar

struct StorageSegment: Identifiable {
    let id = UUID()
    let label: String
    let bytes: Int64
    let color: Color
}

struct StorageBar: View {
    let segments: [StorageSegment]
    let total: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(segments.filter { $0.bytes > 0 }) { seg in
                        Rectangle()
                            .fill(seg.color)
                            .frame(width: max(2, geo.size.width * CGFloat(seg.bytes) / CGFloat(max(total, 1))))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.secondary.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .frame(height: 14)
            HStack(spacing: 14) {
                ForEach(segments) { seg in
                    HStack(spacing: 5) {
                        Circle().fill(seg.color).frame(width: 8, height: 8)
                        Text(seg.label).foregroundStyle(.secondary)
                        SizeText(bytes: seg.bytes)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Permission banner

struct PermissionBanner: View {
    var deniedPaths: [String] = []

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Some folders couldn't be read without Full Disk Access")
                    .font(.callout.weight(.semibold))
                Text(deniedPaths.isEmpty
                     ? "Grant SpaceSweep Full Disk Access in System Settings → Privacy & Security, then rescan. This lets it see Mail, Messages, Safari and iOS backup folders."
                     : "Grant SpaceSweep Full Disk Access in System Settings → Privacy & Security, then rescan. Skipped: " + deniedPaths.prefix(3).map(PathUtils.abbreviate).joined(separator: ", ") + (deniedPaths.count > 3 ? " and \(deniedPaths.count - 3) more" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open System Settings") { MacServices.openFullDiskAccessSettings() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Name cell

struct EntryNameCell: View {
    let entry: FileEntry
    var showPath = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: MacServices.icon(for: entry))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = entry.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if showPath {
                    Text(PathUtils.abbreviate((entry.path as NSString).deletingLastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .help(PathUtils.abbreviate(entry.path))
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Age filter

enum AgeFilter: String, CaseIterable, Identifiable {
    case any = "Any age"
    case month = "Not opened in 30 days"
    case quarter = "Not opened in 90 days"
    case halfYear = "Not opened in 6 months"
    case year = "Not opened in a year"

    var id: String { rawValue }

    var days: Int? {
        switch self {
        case .any: return nil
        case .month: return 30
        case .quarter: return 90
        case .halfYear: return 180
        case .year: return 365
        }
    }
}
#endif
