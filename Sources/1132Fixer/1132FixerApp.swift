import SwiftUI
import AppKit

@main
struct Fixer1132App: App {
    @StateObject private var viewModel = AppViewModel()

    init() {
        // SwiftPM executables are not app bundles and have no main bundle ID.
        // Disable automatic tabbing so AppKit does not try to index tabs by bundle identifier.
        NSWindow.allowsAutomaticWindowTabbing = false

        // Avoid Bundle.module here: if the SwiftPM resource bundle is missing in a packaged app,
        // Bundle.module can trap during startup and crash the app.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    private static var requestedWindowSize: CGSize {
        if let raw = ProcessInfo.processInfo.environment["FIXER_WINDOW_SIZE"] {
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
                    if let url = URL(string: "https://1132-fixer.xyz") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("GitHub Repository") {
                    if let url = URL(string: "https://github.com/PrimeUpYourLife/1132-fixer") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
