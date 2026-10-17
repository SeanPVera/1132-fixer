import SwiftUI

enum Theme {
    enum Colors {
        static let primary = Color(red: 46 / 255, green: 120 / 255, blue: 214 / 255)
        static let background = Color(red: 15 / 255, green: 23 / 255, blue: 36 / 255)
        static let surface = Color(red: 32 / 255, green: 43 / 255, blue: 61 / 255)
        static let surfaceModal = Color(red: 42 / 255, green: 37 / 255, blue: 48 / 255)
        static let success = Color(red: 60 / 255, green: 207 / 255, blue: 110 / 255)
        static let warning = Color(red: 255 / 255, green: 181 / 255, blue: 71 / 255)
        static let error = Color(red: 239 / 255, green: 83 / 255, blue: 80 / 255)
        static let textPrimary = Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
        static let textSecondary = Color(red: 154 / 255, green: 165 / 255, blue: 180 / 255)
        static let border = Color(red: 51 / 255, green: 65 / 255, blue: 90 / 255)
        static let overlay = Color(red: 15 / 255, green: 23 / 255, blue: 36 / 255).opacity(0.72)

        // Compatibility aliases for views that only need a semantic accent/text color.
        static let accent = primary
        static let panelBackground = surface
        static let text = textPrimary
        static let textMuted = textSecondary
        static let cardHover = primary.opacity(0.12)
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
        static let section: CGFloat = 48
    }

    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 28
    }

    enum Typography {
        static let display = Font.system(size: 28, weight: .bold)
        static let heading = Font.system(size: 20, weight: .bold)
        static let subheading = Font.system(size: 16, weight: .semibold)
        static let body = Font.system(size: 14, weight: .regular)
        static let label = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 12, weight: .regular)
        static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)
    }

    struct Panel: ViewModifier {
        var background = Colors.surface
        var radius = Radius.large

        func body(content: Content) -> some View {
            content
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(Colors.border, lineWidth: 1)
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

struct ThemedButtonStyle: ButtonStyle {
    let variant: ThemedButtonVariant

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.label)
            .foregroundStyle(foregroundColor)
            .padding(.vertical, Theme.Spacing.medium)
            .padding(.horizontal, Theme.Spacing.large)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private var foregroundColor: Color {
        switch variant {
        case .primary: return Theme.Colors.textPrimary
        case .secondary: return Theme.Colors.textPrimary
        case .destructive: return Theme.Colors.error
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .primary: return Theme.Colors.primary
        case .secondary, .destructive: return Theme.Colors.surface
        }
    }

    private var borderColor: Color {
        switch variant {
        case .primary: return Theme.Colors.primary
        case .secondary: return Theme.Colors.border
        case .destructive: return Theme.Colors.error.opacity(0.75)
        }
    }
}

extension View {
    func themedPanel(
        background: Color = Theme.Colors.surface,
        radius: CGFloat = Theme.Radius.large
    ) -> some View {
        modifier(Theme.Panel(background: background, radius: radius))
    }

    func terminalPanel() -> some View {
        themedPanel()
    }

    func terminalFont(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        modifier(Theme.TerminalText(size: size, weight: weight))
    }
}
