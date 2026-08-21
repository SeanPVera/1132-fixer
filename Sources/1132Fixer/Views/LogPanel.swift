import SwiftUI

struct LogPanel: View {
    let logs: [String]
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Activity Log", systemImage: "terminal")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.Colors.accent)

                Spacer()

                Button("Copy") {
                    onCopy()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Colors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .border(Theme.Colors.border, width: 1)
                .disabled(logs.isEmpty)

                Button("Clear") {
                    onClear()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.Colors.warning)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .border(Theme.Colors.warning.opacity(0.5), width: 1)
                .disabled(logs.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if logs.isEmpty {
                            Text("No logs yet. Run an action to see output.")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.72))
                                .padding(.top, 2)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.text)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 8)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: logs.count) { _ in
                        if !logs.isEmpty {
                            withAnimation {
                                proxy.scrollTo(logs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .terminalPanel()
    }
}
