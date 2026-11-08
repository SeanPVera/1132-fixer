import SwiftUI

enum Theme {
    enum Colors {
        static let background = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255) // #121214
        static let surface = Color(red: 28 / 255, green: 27 / 255, blue: 32 / 255) // #1C1B20
        static let surfaceModal = Color(red: 36 / 255, green: 35 / 255, blue: 42 / 255) // #24232A
        static let surfaceHover = Color(red: 43 / 255, green: 42 / 255, blue: 49 / 255) // #2B2A31
        static let surfacePressed = Color(red: 23 / 255, green: 22 / 255, blue: 26 / 255) // #17161A
        static let textPrimary = Color(red: 244 / 255, green: 241 / 255, blue: 236 / 255) // #F4F1EC
        static let textSecondary = Color(red: 169 / 255, green: 164 / 255, blue: 157 / 255) // #A9A49D
        static let border = Color(red: 52 / 255, green: 50 / 255, blue: 58 / 255) // #34323A
        static let borderControl = Color(red: 122 / 255, green: 116 / 255, blue: 109 / 255) // #7A746D
        static let primary = Color(red: 255 / 255, green: 154 / 255, blue: 60 / 255) // #FF9A3C
        static let primaryHover = Color(red: 255 / 255, green: 173 / 255, blue: 92 / 255) // #FFAD5C
        static let primaryPressed = Color(red: 232 / 255, green: 132 / 255, blue: 44 / 255) // #E8842C
        static let link = Color(red: 255 / 255, green: 178 / 255, blue: 92 / 255) // #FFB25C
        static let focus = Color(red: 255 / 255, green: 178 / 255, blue: 92 / 255) // #FFB25C
        static let success = Color(red: 61 / 255, green: 220 / 255, blue: 151 / 255) // #3DDC97
        static let warning = Color(red: 255 / 255, green: 194 / 255, blue: 75 / 255) // #FFC24B
        static let error = Color(red: 255 / 255, green: 122 / 255, blue: 133 / 255) // #FF7A85
        static let overlay = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255).opacity(0.72)
        static let gradientBrandStart = Color(red: 255 / 255, green: 210 / 255, blue: 76 / 255) // #FFD24C
        static let surfaceRecessedToken = Color(red: 14 / 255, green: 14 / 255, blue: 16 / 255) // #0E0E10
        static let onPrimary = Color(red: 26 / 255, green: 18 / 255, blue: 6 / 255)           // #1A1206
        static let accentGlow = Color(red: 255 / 255, green: 154 / 255, blue: 60 / 255).opacity(0.28)
        static let gradientBrandEnd = Color(red: 232 / 255, green: 85 / 255, blue: 42 / 255) // #E8552A

        // Canonical token map matching design-system/tokens/macos.json for automated verification.
        static let hexTokens: [String: String] = [
            "background": "#121214",
            "surface": "#1C1B20",
            "surface-modal": "#24232A",
            "surface-hover": "#2B2A31",
            "surface-pressed": "#17161A",
            "surface-recessed": "#0E0E10",
            "text-primary": "#F4F1EC",
            "text-secondary": "#A9A49D",
            "border": "#34323A",
            "border-control": "#7A746D",
            "primary": "#FF9A3C",
            "primary-hover": "#FFAD5C",
            "primary-pressed": "#E8842C",
            "on-primary": "#1A1206",
            "link": "#FFB25C",
            "focus": "#FFB25C",
            "success": "#3DDC97",
            "warning": "#FFC24B",
            "error": "#FF7A85",
            "overlay": "rgba(18,18,20,0.72)",
            "gradient-brand-start": "#FFD24C",
            "gradient-brand-end": "#E8552A",
        ]

        // Compatibility aliases for views that reference semantic roles.
        static let accent = primary
        static let panelBackground = surface
        static let surfaceRecessed = surfaceRecessedToken
        static let surfaceElevated = surfaceHover
        static let borderSubtle = border
        static let text = textPrimary
        static let textMuted = textSecondary
        static let cardHover = surfaceHover
    }

    enum Spacing {
        static let s4: CGFloat = 4
        static let s8: CGFloat = 8
        static let s12: CGFloat = 12
        static let s16: CGFloat = 16
        static let s24: CGFloat = 24
        static let s32: CGFloat = 32
        static let s48: CGFloat = 48
        static let s64: CGFloat = 64

        static let withinRowMin: CGFloat = 8
        static let withinRowMax: CGFloat = 12
        static let groupedContent: CGFloat = 16
        static let majorSection: CGFloat = 24
        static let outerMargin: CGFloat = 24

        // Semantic aliases
        static let xxSmall: CGFloat = s4
        static let xSmall: CGFloat = s4
        static let small: CGFloat = s8
        static let medium: CGFloat = s12
        static let large: CGFloat = s16
        static let xLarge: CGFloat = s24
        static let xxLarge: CGFloat = s32
        static let section: CGFloat = s48
        static let outerPadding: CGFloat = outerMargin
    }

    enum Radius {
        static let row: CGFloat = 0
        static let control: CGFloat = 6

        // Semantic aliases aligned to The Repair Record control radius
        static let small: CGFloat = control
        static let medium: CGFloat = control
        static let large: CGFloat = control
        static let xLarge: CGFloat = control
    }

    enum Focus {
        static let ringWidth: CGFloat = 2
        static let ringGap: CGFloat = 2
    }

    enum Motion {
        static let controlFeedbackMs: Int = 150
        static let disclosureMs: Int = 200
        static let controlFeedbackDuration: Double = 0.15
        static let disclosureDuration: Double = 0.20
    }

    enum Window {
        static let defaultWidth: CGFloat = 900
        static let defaultHeight: CGFloat = 760
        static let minimumWidth: CGFloat = 720
        static let minimumHeight: CGFloat = 640
        static let contentMaxWidth: CGFloat = 960
        static let recordFourColumnMinWidth: CGFloat = 840
        static let rowMinHeight: CGFloat = 44

        static let minWidth: CGFloat = minimumWidth
        static let idealWidth: CGFloat = defaultWidth
        static let minHeight: CGFloat = minimumHeight
        static let idealHeight: CGFloat = defaultHeight
        static let wideLedgerBreakpoint: CGFloat = recordFourColumnMinWidth
    }

    struct TypographyRoleSpec: Equatable {
        let size: CGFloat
        let lineHeight: CGFloat
        let weight: Int
        let family: String
    }

    enum Typography {
        static let fontFamilySans = "SF Pro"
        static let fontFamilyMono = "SF Mono"
        static let fontFamilySerif = "New York"

        static let mainOutcome = Font.system(size: 24, weight: .semibold)
        static let compactIdentity = Font.system(size: 16, weight: .semibold)
        static let sectionHeading = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let button = Font.system(size: 14, weight: .semibold)
        static let label = Font.system(size: 13, weight: .semibold)
        static let metadata = Font.system(size: 12, weight: .regular)
        static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

        /// Expressive status headline: the one serif role (system New York), used once per window.
        static let statusHeadline = Font.system(size: 26, weight: .semibold, design: .serif)

        static let roleSpecs: [String: TypographyRoleSpec] = [
            "main-outcome": TypographyRoleSpec(size: 24, lineHeight: 30, weight: 600, family: "sans"),
            "compact-identity": TypographyRoleSpec(size: 16, lineHeight: 22, weight: 600, family: "sans"),
            "section-heading": TypographyRoleSpec(size: 16, lineHeight: 22, weight: 600, family: "sans"),
            "body": TypographyRoleSpec(size: 14, lineHeight: 20, weight: 400, family: "sans"),
            "button": TypographyRoleSpec(size: 14, lineHeight: 20, weight: 600, family: "sans"),
            "label": TypographyRoleSpec(size: 13, lineHeight: 18, weight: 600, family: "sans"),
            "metadata": TypographyRoleSpec(size: 12, lineHeight: 16, weight: 400, family: "sans"),
            "mono": TypographyRoleSpec(size: 13, lineHeight: 20, weight: 400, family: "mono"),
            "status-headline": TypographyRoleSpec(size: 26, lineHeight: 32, weight: 600, family: "serif"),
        ]

        // Compatibility aliases
        static let display = mainOutcome
        static let title = compactIdentity
        static let heading = sectionHeading
        static let subheading = compactIdentity
        static let caption = metadata
        static let sectionEyebrow = label
        static let stepTitle = label
        static let stepIndex = mono
    }

    struct Panel: ViewModifier {
        var background = Colors.surface
        var radius = Radius.control
        var borderColor = Colors.border

        func body(content: Content) -> some View {
            content
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
        }
    }

    struct LedgerContainer: ViewModifier {
        var background = Colors.surface
        var borderColor = Colors.border

        func body(content: Content) -> some View {
            content
                .background(background)
                .overlay {
                    Rectangle()
                        .stroke(borderColor, lineWidth: 1)
                }
        }
    }

    struct TerminalText: ViewModifier {
        let size: CGFloat
        let weight: Font.Weight

        func body(content: Content) -> some View {
            content
                .font(.system(size: size, weight: weight, design: .monospaced))
                .foregroundStyle(Colors.textPrimary)
        }
    }
}

enum ThemedButtonVariant {
    case primary
    case secondary
    case destructive
}

/// Filled/outlined control button (design-system Button: primary and secondary/ghost).
/// States follow docs/02-colors.md: hover and pressed use the macOS `*-hover` / `*-pressed`
/// tokens; disabled drops the fill and uses `text-secondary` on a `border` outline.
struct ThemedButtonStyle: ButtonStyle {
    let variant: ThemedButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        ThemedButtonBody(configuration: configuration, variant: variant)
    }
}

private struct ThemedButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: ThemedButtonVariant

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        configuration.label
            .font(Theme.Typography.button)
            .foregroundStyle(foregroundColor)
            .padding(.vertical, Theme.Spacing.s8)
            .padding(.horizontal, Theme.Spacing.s16)
            .frame(minHeight: Theme.Spacing.s32)
            .background(fillColor)
            .clipShape(shape)
            .overlay {
                shape.stroke(strokeColor, lineWidth: 1)
            }
            .shadow(color: glowColor, radius: isHovering ? 10 : 6, y: 0)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(feedbackAnimation, value: isHovering)
            .animation(feedbackAnimation, value: configuration.isPressed)
    }

    /// Soft amber halo on the enabled primary action only; static under Reduce Motion
    /// because only the hover change is animated.
    private var glowColor: Color {
        guard isEnabled, variant == .primary else { return .clear }
        return Theme.Colors.accentGlow
    }

    private var feedbackAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: Theme.Motion.controlFeedbackDuration)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return Theme.Colors.textSecondary }
        switch variant {
        case .primary:
            return Theme.Colors.onPrimary
        case .secondary:
            return Theme.Colors.textPrimary
        case .destructive:
            return Theme.Colors.error
        }
    }

    private var fillColor: Color {
        guard isEnabled else { return .clear }
        switch variant {
        case .primary:
            if configuration.isPressed { return Theme.Colors.primaryPressed }
            return isHovering ? Theme.Colors.primaryHover : Theme.Colors.primary
        case .secondary, .destructive:
            if configuration.isPressed { return Theme.Colors.surfacePressed }
            return isHovering ? Theme.Colors.surfaceHover : Theme.Colors.surface
        }
    }

    private var strokeColor: Color {
        guard isEnabled else { return Theme.Colors.border }
        switch variant {
        case .primary:
            // The amber fill carries its own boundary contrast against graphite.
            return Theme.Colors.primaryPressed
        case .secondary:
            return Theme.Colors.borderControl
        case .destructive:
            return Theme.Colors.error
        }
    }
}

/// Borderless text button for inline and utility actions (Recheck, Help, support access).
struct QuietLinkButtonStyle: ButtonStyle {
    var color: Color = Theme.Colors.link

    func makeBody(configuration: Configuration) -> some View {
        QuietLinkButtonBody(configuration: configuration, color: color)
    }
}

private struct QuietLinkButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let color: Color

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

        configuration.label
            .font(Theme.Typography.label)
            .foregroundStyle(isEnabled ? color : Theme.Colors.textSecondary)
            .padding(.vertical, Theme.Spacing.s4)
            .padding(.horizontal, Theme.Spacing.s8)
            .background(fillColor)
            .clipShape(shape)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: Theme.Motion.controlFeedbackDuration), value: isHovering)
    }

    private var fillColor: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed { return Theme.Colors.surfacePressed }
        return isHovering ? Theme.Colors.surfaceHover : .clear
    }
}

/// Semantic tone for status words, symbols, and tags. Status colors are never used alone:
/// every tone is paired with explicit text (docs/09-accessibility.md).
enum StatusTone: Equatable {
    case neutral
    case active
    case success
    case warning
    case error

    var color: Color {
        switch self {
        case .neutral: return Theme.Colors.textSecondary
        // `primary` is a fill colour; its accessible text tint on dark surfaces is `link`.
        case .active: return Theme.Colors.link
        case .success: return Theme.Colors.success
        case .warning: return Theme.Colors.warning
        case .error: return Theme.Colors.error
        }
    }
}

/// Design-system "Status pill / tag": pill shape, caption-size text, `spacing.4`/`spacing.8`
/// padding, status tint with matching text. Neutral tags use an outlined `border` pill.
struct StatusTag: View {
    let text: String
    var tone: StatusTone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.Typography.metadata)
            .monospacedDigit()
            .foregroundStyle(tone.color)
            .lineLimit(1)
            .padding(.horizontal, Theme.Spacing.s8)
            .padding(.vertical, Theme.Spacing.s4)
            .background(fillColor)
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(tone == .neutral ? Theme.Colors.border : .clear, lineWidth: 1)
            }
    }

    private var fillColor: Color {
        tone == .neutral ? .clear : tone.color.opacity(0.14)
    }
}

extension View {
    func themedPanel(
        background: Color = Theme.Colors.surface,
        radius: CGFloat = Theme.Radius.control,
        borderColor: Color = Theme.Colors.border
    ) -> some View {
        modifier(Theme.Panel(background: background, radius: radius, borderColor: borderColor))
    }

    func ledgerContainer(
        background: Color = Theme.Colors.surface,
        borderColor: Color = Theme.Colors.border
    ) -> some View {
        modifier(Theme.LedgerContainer(background: background, borderColor: borderColor))
    }

    func themedLedger(
        background: Color = Theme.Colors.surface,
        borderColor: Color = Theme.Colors.border
    ) -> some View {
        ledgerContainer(background: background, borderColor: borderColor)
    }

    func terminalPanel() -> some View {
        themedPanel()
    }

    func terminalFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        modifier(Theme.TerminalText(size: size, weight: weight))
    }
}
