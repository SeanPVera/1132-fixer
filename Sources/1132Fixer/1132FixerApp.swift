import SwiftUI
import AppKit

@main
struct Fixer1132App: App {
    init() {
        // SwiftPM executables are not app bundles and have no main bundle ID.
        // Disable automatic tabbing so AppKit does not try to index tabs by bundle identifier.
        NSWindow.allowsAutomaticWindowTabbing = false

    }

    var body: some Scene {
        WindowGroup("1132 Fixer") {
            ContentView()
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
    }
}
