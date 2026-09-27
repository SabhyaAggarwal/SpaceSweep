#if canImport(SwiftUI)
import SwiftUI
import AppKit
import CleanCore

@main
struct SpaceSweepApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("SpaceSweep") {
            ContentView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .task { await model.bootstrap() }
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Scan Everything") { model.scanAll() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop Scanning") { model.cancelAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(model.scanning.isEmpty)
                Divider()
                Button("Review & Clean Everything…") { model.requestCleanEverything() }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                    .disabled(model.results.isEmpty)
            }
            CommandGroup(replacing: .help) {
                Button("SpaceSweep on GitHub") {
                    if let url = URL(string: "https://github.com/SabhyaAggarwal/SpaceSweep") { NSWorkspace.shared.open(url) }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
#else
// The UI needs macOS. This stub keeps `swift build` / `swift test` working on Linux CI.
@main
struct SpaceSweepCLI {
    static func main() { print("SpaceSweep's interface requires macOS. The CleanCore engine builds and tests here.") }
}
#endif
