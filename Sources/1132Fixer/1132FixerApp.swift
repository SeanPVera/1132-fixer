import SwiftUI
import AppKit

@main
struct Fixer1132App: App {
    @StateObject private var viewModel = AppViewModel()

    init() {
        // SwiftPM executables are not app bundles and have no main bundle ID.
        // Disable automatic tabbing so AppKit does not try to index tabs by bundle identifier.
        NSWindow.allowsAutomaticWindowTabbing = false

    }

    private static var requestedWindowSize: CGSize {
        if AppConfiguration.allowsDebugEnvironmentOverrides,
           let raw = ProcessInfo.processInfo.environment["FIXER_WINDOW_SIZE"] {
            let parts = raw.lowercased().split(separator: "x")
            if parts.count == 2,
               let width = Double(parts[0]),
               let height = Double(parts[1]) {
                return CGSize(width: width, height: height)
            }
        }
        return CGSize(width: Theme.Window.defaultWidth, height: Theme.Window.defaultHeight)
    }

    var body: some Scene {
        WindowGroup("1132 Fixer") {
            ContentView(viewModel: viewModel)
        }
        .defaultSize(
            width: Self.requestedWindowSize.width,
            height: Self.requestedWindowSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("1132 Fixer Website") {
                    NSWorkspace.shared.open(AppConfiguration.websiteURL)
                }
                Button("GitHub Repository") {
                    NSWorkspace.shared.open(AppConfiguration.repositoryURL)
                }
            }
        }
    }
}
