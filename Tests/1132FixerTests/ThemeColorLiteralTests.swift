import AppKit
import SwiftUI
import Testing
@testable import _132Fixer

/// The `Color` literals must equal the `hexTokens` strings the parity test compares with macos.json.
@Suite("Theme colour literals match hex tokens")
struct ThemeColorLiteralTests {
    private static let literals: [String: Color] = [
        "background": Theme.Colors.background,
        "surface": Theme.Colors.surface,
        "surface-modal": Theme.Colors.surfaceModal,
        "surface-hover": Theme.Colors.surfaceHover,
        "surface-pressed": Theme.Colors.surfacePressed,
        "surface-recessed": Theme.Colors.surfaceRecessed,
        "text-primary": Theme.Colors.textPrimary,
        "text-secondary": Theme.Colors.textSecondary,
        "border": Theme.Colors.border,
        "border-control": Theme.Colors.borderControl,
        "primary": Theme.Colors.primary,
        "primary-hover": Theme.Colors.primaryHover,
        "primary-pressed": Theme.Colors.primaryPressed,
        "on-primary": Theme.Colors.onPrimary,
        "link": Theme.Colors.link,
        "focus": Theme.Colors.focus,
        "success": Theme.Colors.success,
        "warning": Theme.Colors.warning,
        "error": Theme.Colors.error,
        "gradient-brand-start": Theme.Colors.gradientBrandStart,
        "gradient-brand-end": Theme.Colors.gradientBrandEnd,
    ]

    @Test func everyOpaqueHexTokenMatchesItsColorLiteral() throws {
        let opaque = Theme.Colors.hexTokens.filter { $0.value.hasPrefix("#") }
        #expect(Set(opaque.keys) == Set(Self.literals.keys))
        for (name, hex) in opaque {
            let color = try #require(Self.literals[name])
            let ns = try #require(NSColor(color).usingColorSpace(.sRGB), "\(name) not convertible")
            let rendered = String(
                format: "#%02X%02X%02X",
                Int((ns.redComponent * 255).rounded()),
                Int((ns.greenComponent * 255).rounded()),
                Int((ns.blueComponent * 255).rounded())
            )
            #expect(rendered == hex.uppercased(), "\(name): literal \(rendered) vs token \(hex)")
        }
    }
}
