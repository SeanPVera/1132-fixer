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
                Label("Zoom Location", systemImage: "folder.circle.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                if isCustom {
                    Text("Custom")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.blue.opacity(0.28))
                        )
                }
            }

            Text(appPath)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button(action: onChoose) {
                    Label("Choose Location…", systemImage: "folder")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isDisabled)

                if isCustom {
                    Button(action: onReset) {
                        Text("Use Default")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .controlSize(.small)
                    .disabled(isDisabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}
