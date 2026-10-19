import SwiftUI

struct LogPanel: View {
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
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
                    if logs.isEmpty {
                        Text("No logs yet. Run a preview or repair to record diagnostic output.")
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
                                .padding(.vertical, 2)
                                .id(index)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.medium)
            }
            .background(Theme.Colors.surfaceRecessed)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .padding(Theme.Spacing.large)
        .frame(
            maxWidth: .infinity,
            minHeight: Theme.Spacing.section * 4,
            alignment: .topLeading
        )
        .themedPanel()
    }
}

struct ActivityLogSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let appVersion: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxSmall) {
                    Text("Activity Log")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("\(viewModel.logEntries.count) entries retained in memory (capped at \(AppViewModel.maxInMemoryLogEntries) lines)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Spacer()

                Toggle("Follow latest", isOn: $viewModel.isFollowingLatestLog)
                    .toggleStyle(.checkbox)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if viewModel.logEntries.isEmpty {
                            Text("No diagnostic output recorded in this session yet.")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .padding(Theme.Spacing.medium)
                        } else {
                            ForEach(viewModel.logEntries) { entry in
                                Text(entry.line)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Theme.Spacing.medium)
                                    .padding(.vertical, 3)
                                    .id(entry.sequence)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.small)
                }
                .background(Theme.Colors.surfaceRecessed)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
                .onAppear {
                    guard viewModel.isFollowingLatestLog, let lastSeq = viewModel.logEntries.last?.sequence else { return }
                    proxy.scrollTo(lastSeq, anchor: .bottom)
                }
                .onChange(of: viewModel.logRevision) { _ in
                    guard viewModel.isFollowingLatestLog, let lastSeq = viewModel.logEntries.last?.sequence else { return }
                    // Diagnostic log scrolling must be immediate, never animated.
                    proxy.scrollTo(lastSeq, anchor: .bottom)
                }
            }

            HStack(spacing: Theme.Spacing.small) {
                Button(action: viewModel.copyLogs) {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                .disabled(viewModel.logEntries.isEmpty)

                Button {
                    viewModel.exportDiagnostics(appVersion: appVersion)
                } label: {
                    Label("Export Diagnostics…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(ThemedButtonStyle(variant: .secondary))

                Button(action: viewModel.clearLogs) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(ThemedButtonStyle(variant: .destructive))
                .disabled(viewModel.logEntries.isEmpty)

                Spacer()

                Button("Done", action: onClose)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(minWidth: 680, idealWidth: 740, minHeight: 460, idealHeight: 520, alignment: .topLeading)
        .background(Theme.Colors.background)
        .preferredColorScheme(.dark)
    }
}
