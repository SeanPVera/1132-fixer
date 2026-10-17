import SwiftUI

struct LogPanel: View {
    @State private var isExpanded = false

    let logs: [String]
    let onCopy: () -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                Label("Activity Log", systemImage: "text.alignleft")
                    .font(Theme.Typography.heading)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer()

                Button(action: onCopy) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .disabled(logs.isEmpty)

                Button(action: onClear) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(ThemedButtonStyle(variant: .destructive))
                .disabled(logs.isEmpty)

                Button {
                    isExpanded.toggle()
                } label: {
                    Label(
                        isExpanded ? "Collapse" : "Expand",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .accessibilityLabel(isExpanded ? "Collapse activity log" : "Expand activity log")
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        if logs.isEmpty {
                            Text("No logs yet. Run an action to see output.")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(.top, Theme.Spacing.xSmall)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, Theme.Spacing.xSmall)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: logs.count) { _ in
                        guard !logs.isEmpty else { return }
                        // Diagnostic output should append instantly; never animate the log.
                        proxy.scrollTo(logs.count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(
            maxWidth: .infinity,
            minHeight: Theme.Spacing.section * (isExpanded ? 7 : 4),
            alignment: .topLeading
        )
        .themedPanel()
    }
}
