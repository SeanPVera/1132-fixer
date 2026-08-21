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
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.Colors.accent)

            switch preflight.status {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking system...")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.Colors.textMuted)
                }
            case .error(let msg):
                Text(msg)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.Colors.error)
            case .ready:
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(preflight.checks) { check in
                        HStack(spacing: 6) {
                            Text(check.isWarning ? "[WARN]" : "[OK]")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(check.isWarning ? Theme.Colors.warning : Theme.Colors.success)
                            Text(check.label + ":")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textMuted)
                            Text(check.value)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.Colors.text)
                        }
                    }
                }
            }

            Divider().background(Theme.Colors.border.opacity(0.5))

            HStack(spacing: 6) {
                Text("Supported:")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.textMuted)
                ForEach(Self.supportMatrix, id: \.label) { item in
                    Text(item.label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(item.supported ? Theme.Colors.text : Theme.Colors.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(item.supported ? Theme.Colors.success.opacity(0.2) : Theme.Colors.error.opacity(0.2))
                        .border(item.supported ? Theme.Colors.success.opacity(0.5) : Theme.Colors.error.opacity(0.5), width: 1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .terminalPanel()
    }
}
