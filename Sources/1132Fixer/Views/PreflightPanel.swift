import SwiftUI

struct PreflightPanel: View {
    let preflight: AppViewModel.PreflightInfo

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
        VStack(alignment: .leading, spacing: 10) {
            Label("Preflight Checks", systemImage: "checklist")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            switch preflight.status {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking system...")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.9))
            case .ready:
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(preflight.checks) { check in
                        HStack(spacing: 6) {
                            Image(systemName: check.isWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(check.isWarning ? .yellow : .green)
                            Text(check.label + ":")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                            Text(check.value)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                    }
                }
            }

            Divider().background(Color.white.opacity(0.12))

            HStack(spacing: 6) {
                Text("Supported:")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                ForEach(Self.supportMatrix, id: \.label) { item in
                    Text(item.label)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(item.supported ? .white.opacity(0.8) : .white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(item.supported ? Color.green.opacity(0.18) : Color.red.opacity(0.15))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(item.supported ? Color.green.opacity(0.25) : Color.red.opacity(0.2), lineWidth: 0.5)
                        )
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
