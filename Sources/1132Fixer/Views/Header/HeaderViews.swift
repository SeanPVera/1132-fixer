import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct HeaderCard: View {
    let repositoryURL: URL
    let websiteURL: URL
    let onReportBug: () -> Void
    let isReportBugDisabled: Bool
    let onExportDiagnostics: () -> Void

    var body: some View {
        HStack(spacing: Design.s1) {
            HeaderLinkButton(title: "GitHub", systemImage: "link", destination: repositoryURL)
            HeaderLinkButton(title: "Website", systemImage: "globe", destination: websiteURL)
            HeaderActionButton(
                title: "Report a bug",
                systemImage: "ladybug",
                isDisabled: isReportBugDisabled,
                action: onReportBug
            )
            HeaderActionButton(
                title: "Export Diagnostics",
                systemImage: "square.and.arrow.up",
                isDisabled: false,
                action: onExportDiagnostics
            )
        }
        .panelChrome(padding: Design.s2)
    }
}

struct HeaderLinkButton: View {
    let title: String
    let systemImage: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .secondaryControl()
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(AppButtonStyle())
    }
}

struct HeaderActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .secondaryControl()
        }
        .frame(maxWidth: .infinity)
        .buttonStyle(AppButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1.0)
    }
}

struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    /// Primary cards keep the accent glow; secondary cards differ only by icon color.
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Design.s2) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(tint)
                    .frame(width: 26, alignment: .center)

                VStack(alignment: .leading, spacing: Design.s1) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(Design.primaryText)

                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(Design.secondaryText)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Design.s2)

                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Design.tertiaryText)
            }
            .padding(Design.s3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .fill(isPrimary ? tint.opacity(0.10) : Design.panelFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous)
                    .strokeBorder(
                        isPrimary ? tint.opacity(isHovering ? 0.55 : 0.38) : Design.panelStroke,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isPrimary ? tint.opacity(isHovering ? 0.32 : 0.18) : .clear,
                radius: 16,
                y: 4
            )
            .opacity(isDisabled ? 0.5 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: Design.cardRadius, style: .continuous))
        }
        .buttonStyle(AppButtonStyle())
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
    }
}
