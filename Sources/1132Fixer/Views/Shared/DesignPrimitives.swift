import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

/// Shared design tokens. Spacing follows an 8-point system; radii, typography and
/// surface treatments are defined once so every panel and control matches.
enum Design {
    // 8-point spacing scale
    static let s1: CGFloat = 8
    static let s2: CGFloat = 16
    static let s3: CGFloat = 24
    static let s4: CGFloat = 32

    // Corner radii
    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 10
    static let badgeRadius: CGFloat = 999

    // Control metrics
    static let controlHeight: CGFloat = 32
    static let iconColumn: CGFloat = 18

    // Surfaces
    static let panelFill = Color.white.opacity(0.05)
    static let panelStroke = Color.white.opacity(0.08)
    static let controlFill = Color.white.opacity(0.08)
    static let controlStroke = Color.white.opacity(0.10)

    // Text
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.45)

    static let accent = Color(red: 0.13, green: 0.50, blue: 0.86)
    static let neutralAccent = Color(red: 0.62, green: 0.66, blue: 0.72)
}

/// Lightweight panel chrome: soft fill, hairline stroke, generous radius.
struct PanelChrome: ViewModifier {
    var padding: CGFloat = Design.s3
    var radius: CGFloat = Design.panelRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Design.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Design.panelStroke, lineWidth: 1)
            )
    }
}

extension View {
    func panelChrome(padding: CGFloat = Design.s3, radius: CGFloat = Design.panelRadius) -> some View {
        modifier(PanelChrome(padding: padding, radius: radius))
    }
}

/// Section heading used by every panel: fixed-width icon column + title.
struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Design.s1 + 2) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Design.primaryText.opacity(0.85))
                .frame(width: Design.iconColumn, alignment: .center)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Design.primaryText)
        }
    }
}

/// Native-feeling secondary control chrome shared by every button in the app so
/// height, radius, padding and icon spacing stay identical.
struct SecondaryControlChrome: ViewModifier {
    var isProminent: Bool = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Design.primaryText)
            .labelStyle(ControlLabelStyle())
            .padding(.horizontal, Design.s2)
            .frame(height: Design.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                    .fill(isProminent
                          ? Design.accent.opacity(isHovering ? 1.0 : 0.9)
                          : Design.controlFill.opacity(isHovering ? 1.6 : 1.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
                    .strokeBorder(isProminent ? Color.clear : Design.controlStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous))
            .onHover { isHovering = $0 }
    }
}

/// Keeps icon/label spacing identical across every control.
struct ControlLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .font(.system(size: 12, weight: .medium))
            configuration.title
        }
    }
}

extension View {
    func secondaryControl(isProminent: Bool = false) -> some View {
        modifier(SecondaryControlChrome(isProminent: isProminent))
    }
}

/// Button style that gives every control the same pressed feedback.
struct AppButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
