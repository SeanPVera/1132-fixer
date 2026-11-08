import Foundation
import Testing
@testable import _132Fixer

/// WCAG 2.x contrast checks for the app-scoped "Signal" skin (`Theme.Signal`).
@Suite("Signal palette contrast")
struct SignalPaletteTests {
    private static func luminance(_ hex: String) throws -> Double {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = try #require(UInt32(digits, radix: 16))
        let channels = [(value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF].map { channel -> Double in
            let c = Double(channel) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    private static func contrast(_ a: String, _ b: String) throws -> Double {
        let la = try luminance(a)
        let lb = try luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func token(_ name: String) throws -> String {
        try #require(Theme.Signal.hexTokens[name], "Missing Signal token \(name)")
    }

    @Test func textAndStatusColorsMeetAAOnEverySurface() throws {
        let surfaces = ["background", "surface", "surface-modal", "surface-hover"]
        let foregrounds = ["text-primary", "text-secondary", "link", "success", "warning", "error"]
        for surface in surfaces {
            for foreground in foregrounds {
                let ratio = try Self.contrast(try token(foreground), try token(surface))
                #expect(ratio >= 4.5, "\(foreground) on \(surface) is \(ratio):1")
            }
        }
    }

    @Test func primaryActionInkMeetsAAOnAllFillStates() throws {
        for fill in ["primary", "primary-hover", "primary-pressed"] {
            let ratio = try Self.contrast(try token("on-primary"), try token(fill))
            #expect(ratio >= 4.5, "on-primary on \(fill) is \(ratio):1")
        }
    }

    @Test func controlBoundaryMeetsNonTextContrast() throws {
        for surface in ["background", "surface", "surface-modal", "surface-hover"] {
            let ratio = try Self.contrast(try token("border-control"), try token(surface))
            #expect(ratio >= 3.0, "border-control on \(surface) is \(ratio):1")
        }
    }

    @Test func canonicalDesignSystemMirrorIsUnchanged() {
        #expect(Theme.Colors.hexTokens["primary"] == "#235FA8")
        #expect(Theme.Signal.hexTokens["primary"] != Theme.Colors.hexTokens["primary"])
    }
}
