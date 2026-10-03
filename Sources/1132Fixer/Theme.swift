import SwiftUI

public enum Theme {
    public enum Colors {
        public static let background = Color.black
        public static let panelBackground = Color(red: 0.05, green: 0.05, blue: 0.05)
        public static let border = Color.green.opacity(0.6)
        public static let accent = Color.green
        public static let text = Color.white.opacity(0.9)
        public static let textMuted = Color.white.opacity(0.6)

        public static let success = Color.green
        public static let warning = Color.yellow
        public static let error = Color.red

        public static let cardHover = Color(red: 0.1, green: 0.15, blue: 0.1)
    }

    public struct Panel: ViewModifier {
        public func body(content: Content) -> some View {
            content
                .background(Colors.panelBackground)
                .border(Colors.border, width: 1)
        }
    }

    public struct TerminalText: ViewModifier {
        let size: CGFloat
        let weight: Font.Weight

        public func body(content: Content) -> some View {
            content
                .font(.system(size: size, weight: weight, design: .monospaced))
                .foregroundStyle(Colors.text)
        }
    }
}

extension View {
    public func terminalPanel() -> some View {
        modifier(Theme.Panel())
    }

    public func terminalFont(size: CGFloat = 12, weight: Font.Weight = .regular) -> some View {
        modifier(Theme.TerminalText(size: size, weight: weight))
    }
}
