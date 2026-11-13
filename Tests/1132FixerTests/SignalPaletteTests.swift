import Foundation
import Testing
@testable import _132Fixer

/// WCAG 2.x contrast checks for the Signal macOS palette (`Theme.Colors`, mirrored from
/// `design-system/tokens/macos.json`).
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

    private static let allSurfaces = [
        "background", "surface", "surface-modal", "surface-hover", "surface-pressed", "surface-recessed",
    ]

    private func token(_ name: String) throws -> String {
        try #require(Theme.Colors.hexTokens[name], "Missing token \(name)")
    }

    @Test func textAndStatusColorsMeetAAOnEverySurface() throws {
        let surfaces = Self.allSurfaces
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
        for surface in Self.allSurfaces {
            let ratio = try Self.contrast(try token("border-control"), try token(surface))
            #expect(ratio >= 3.0, "border-control on \(surface) is \(ratio):1")
        }
    }

    /// The primary button has no `border-control` stroke, so its fill must hold the boundary itself.
    @Test func primaryFillsHoldNonTextBoundaryOnEverySurface() throws {
        for fill in ["primary", "primary-hover", "primary-pressed"] {
            for surface in Self.allSurfaces {
                let ratio = try Self.contrast(try token(fill), try token(surface))
                #expect(ratio >= 3.0, "\(fill) on \(surface) is \(ratio):1")
            }
        }
    }

    @Test func warningHueIsDistinctFromTheAmberAccent() throws {
        func hue(_ hex: String) throws -> Double {
            let value = try #require(UInt32(hex.dropFirst(), radix: 16))
            let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
            let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
            guard d > 0 else { return 0 }
            var h: Double
            if maxC == r { h = (g - b) / d } else if maxC == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            return h < 0 ? h + 360 : h
        }
        let warning = try hue(try token("warning"))
        for accent in ["primary", "link"] {
            let accentHue = try hue(try token(accent))
            #expect(abs(warning - accentHue) >= 15, "warning hue too close to \(accent)")
        }
    }

    @Test func statusHeadlineIsTheOnlySerifRole() {
        let serifRoles = Theme.Typography.roleSpecs.filter { $0.value.family == "serif" }.map(\.key)
        #expect(serifRoles == ["status-headline"])
        #expect(Theme.Typography.fontFamilySerif == "New York")
    }
}
