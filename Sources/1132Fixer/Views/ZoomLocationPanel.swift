import SwiftUI

struct ZoomLocationPanel: View {
    let appPath: String
    let isCustom: Bool
    let isDisabled: Bool
    let onChoose: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("Zoom Location", systemImage: "folder.fill")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.accent)
                Spacer()
                if isCustom {
                    Text("Custom")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.warning.opacity(0.2))
                        .border(Theme.Colors.warning.opacity(0.5), width: 1)
                }
            }

            Text(appPath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.Colors.textMuted)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: onChoose) {
                    Label("Choose Location…", systemImage: "folder")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.Colors.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .border(Theme.Colors.border, width: 1)
                .disabled(isDisabled)

                if isCustom {
                    Button(action: onReset) {
                        Text("Use Default")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.Colors.warning)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .border(Theme.Colors.warning.opacity(0.5), width: 1)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalPanel()
    }
}
