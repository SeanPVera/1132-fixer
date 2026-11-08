import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct PreflightPanel: View {
    let preflight: AppViewModel.PreflightInfo
    let onOpenCameraSettings: () -> Void
    let onOpenMicrophoneSettings: () -> Void

    @State private var isExpanded = false

    private static let supportMatrix: [(label: String, supported: Bool)] = [
        ("Intel", true),
        ("Apple Silicon", true),
        ("macOS 13", true),
        ("macOS 14+", true),
        ("Wi-Fi", true),
        ("Ethernet", true),
        ("VPN", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Design.s1) {
                    SectionHeader(title: "Preflight Checks", systemImage: "checklist")
                    Spacer(minLength: Design.s2)
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 14)
                        .secondaryControl()
                }
            }
            .buttonStyle(AppButtonStyle())
            .help(isExpanded ? "Collapse preflight checks" : "Expand preflight checks")

            if isExpanded {
                Group {
                    switch preflight.status {
                    case .loading:
                        HStack(spacing: Design.s1) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking system...")
                                .font(.system(size: 13, weight: .regular, design: .rounded))
                                .foregroundStyle(Design.secondaryText)
                        }
                    case .error(let msg):
                        Text(msg)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.red.opacity(0.9))
                    case .ready:
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: Design.s3, alignment: .leading),
                                GridItem(.flexible(), spacing: Design.s3, alignment: .leading)
                            ],
                            alignment: .leading,
                            spacing: Design.s2
                        ) {
                            ForEach(preflight.checks) { check in
                                HStack(alignment: .firstTextBaseline, spacing: Design.s1 + 2) {
                                    Image(systemName: check.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(check.isWarning ? .yellow : .green)
                                        .frame(width: Design.iconColumn, alignment: .center)
                                    Text(check.label + ":")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(Design.secondaryText)
                                    Text(check.value)
                                        .font(.system(size: 13, weight: .regular, design: .rounded))
                                        .foregroundStyle(Design.primaryText.opacity(0.9))
                                        .fixedSize(horizontal: false, vertical: true)

                                    if check.id == "camera" && check.isWarning {
                                        Button("Open Settings", action: onOpenCameraSettings)
                                            .buttonStyle(.link)
                                    } else if check.id == "microphone" && check.isWarning {
                                        Button("Open Settings", action: onOpenMicrophoneSettings)
                                            .buttonStyle(.link)
                                    }
                                }
                            }
                        }
                    }

                    Divider()
                        .overlay(Color.white.opacity(0.08))
                        .padding(.vertical, Design.s1)

                    HStack(spacing: Design.s1) {
                        Text("Supported:")
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(Design.tertiaryText)
                        ForEach(Self.supportMatrix, id: \.label) { item in
                            SupportBadge(label: item.label, supported: item.supported)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .panelChrome()
    }
}

/// Informational pill in the support matrix — soft fill, no hard outline.
struct SupportBadge: View {
    let label: String
    let supported: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(supported ? Color.green.opacity(0.85) : Color.red.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(supported ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
            )
    }
}

struct ZoomLocationPanel: View {
    let appPath: String
    let isCustom: Bool
    let isInstalled: Bool
    let isDisabled: Bool
    let onChoose: () -> Void
    let onReset: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Design.s3) {
            VStack(alignment: .leading, spacing: Design.s1 + 4) {
                HStack(spacing: Design.s1) {
                    SectionHeader(title: "Zoom Location", systemImage: "folder")
                    if isCustom {
                        Text("Custom")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Design.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Design.accent.opacity(0.16))
                            )
                    }
                }

                Text(appPath)
                    .font(.system(size: 13, weight: .regular, design: .default))
                    .foregroundStyle(Design.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !isInstalled {
                    Text("Zoom was not found at this location.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.yellow)
                }
            }

            Spacer(minLength: Design.s2)

            HStack(spacing: Design.s1) {
                if !isInstalled {
                    Button(action: onDownload) {
                        Label("Download Zoom", systemImage: "arrow.down.circle")
                            .secondaryControl()
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isDisabled)
                }

                if isCustom {
                    Button(action: onReset) {
                        Text("Use Default")
                            .secondaryControl()
                    }
                    .buttonStyle(AppButtonStyle())
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1.0)
                }

                Button(action: onChoose) {
                    Label("Choose Location…", systemImage: "folder")
                        .secondaryControl(isProminent: true)
                }
                .buttonStyle(AppButtonStyle())
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.5 : 1.0)
            }
            .fixedSize()
        }
        .panelChrome()
    }
}
