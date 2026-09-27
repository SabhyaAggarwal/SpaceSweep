#if canImport(SwiftUI)
import SwiftUI
import AppKit
import CleanCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            scanningTab(settings: $model.settings)
                .tabItem { Label("Scanning", systemImage: "magnifyingglass") }
            foldersTab(settings: $model.settings)
                .tabItem { Label("Folders", systemImage: "folder") }
            deletionTab(settings: $model.settings)
                .tabItem { Label("Deletion", systemImage: "trash") }
        }
        .frame(width: 560, height: 420)
    }

    // MARK: Scanning

    private func scanningTab(settings: Binding<ScanSettings>) -> some View {
        Form {
            Section {
                Stepper(value: settings.largeFileThresholdMB, in: 10...5000, step: 10) {
                    LabeledContent("Large file threshold", value: "\(settings.wrappedValue.largeFileThresholdMB) MB")
                }
                Toggle("Include ~/Library in the large-file scan", isOn: settings.includeLibraryInLargeFiles)
                Text("Library holds app data and caches, most of which are already covered by other categories. Turn this on to hunt for big files hidden in app containers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Large files")
            }

            Section {
                Stepper(value: settings.staleDays, in: 7...1825, step: 7) {
                    LabeledContent("Consider a file unused after", value: "\(settings.wrappedValue.staleDays) days")
                }
                Text("Uses the file's last-opened time when available, otherwise its modification date. macOS updates last-opened lazily, so treat it as a hint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Not opened in a long time")
            }

            Section {
                Stepper(value: settings.duplicateMinMB, in: 1...1000) {
                    LabeledContent("Ignore duplicates smaller than", value: "\(settings.wrappedValue.duplicateMinMB) MB")
                }
            } header: {
                Text("Duplicates")
            }

            Section {
                Stepper(value: settings.devScanMaxDepth, in: 2...12) {
                    LabeledContent("Search project roots up to", value: "\(settings.wrappedValue.devScanMaxDepth) folders deep")
                }
            } header: {
                Text("Project build folders")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Folders

    private func foldersTab(settings: Binding<ScanSettings>) -> some View {
        Form {
            Section {
                PathListEditor(paths: settings.projectRoots,
                               placeholder: "No project roots — add the folders where you keep code.")
                Button("Reset to defaults") { settings.wrappedValue.projectRoots = ScanSettings.defaultProjectRoots }
                    .controlSize(.small)
            } header: {
                Text("Project roots")
            } footer: {
                Text("Where “Project Build Folders” looks for node_modules, .build, target, .venv, .pio and similar. Folders that don't exist are skipped.")
            }

            Section {
                PathListEditor(paths: settings.excludedPaths,
                               placeholder: "Nothing excluded.")
            } header: {
                Text("Never scan")
            } footer: {
                Text("Skipped by every scanner. Useful for external drives, cloud-sync folders or a project you never want to see here.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Deletion

    private func deletionTab(settings: Binding<ScanSettings>) -> some View {
        Form {
            Section {
                Toggle(isOn: settings.permanentDelete) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delete permanently by default")
                        Text("Skips the Trash so space is freed immediately. Every deletion still shows a confirmation with the full list, where you can flip this per action.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("How items are removed")
            }

            Section {
                LabeledContent("Full Disk Access", value: model.hasFullDiskAccess ? "Granted" : "Not granted")
                Button("Open Privacy & Security settings") { MacServices.openFullDiskAccessSettings() }
                Button("Re-check") { model.hasFullDiskAccess = MacServices.checkFullDiskAccess() }
                    .controlSize(.small)
                Text("Needed to see Mail, Messages, Safari and iOS backup folders. Everything else works without it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Permissions")
            }

            Section {
                Text("SpaceSweep never touches your home folder root, ~/Library, ~/Documents, ~/Desktop, ~/Downloads, ~/Pictures, /Applications or any system folder as a whole — only the specific items listed in a scan result.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Safety")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Path list editor

private struct PathListEditor: View {
    @Binding var paths: [String]
    let placeholder: String
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if paths.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                List(paths, id: \.self, selection: $selected) { p in
                    HStack {
                        Image(systemName: PathUtils.isDirectory(p) ? "folder" : "folder.badge.questionmark")
                            .foregroundStyle(PathUtils.isDirectory(p) ? .secondary : .orange)
                        Text(p)
                            .font(.system(.callout, design: .monospaced))
                    }
                    .tag(p)
                }
                .frame(minHeight: 100, maxHeight: 160)
            }
            HStack(spacing: 8) {
                Button {
                    addFolders()
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    if let selected { paths.removeAll { $0 == selected } }
                    selected = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selected == nil)
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls {
                let p = PathUtils.abbreviate(url.path)
                if !paths.contains(p) { paths.append(p) }
            }
        }
    }
}
#endif
