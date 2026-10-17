import SwiftUI

struct BugReportFormSheet: View {
    static let maximumMessageLength = 4_000

    @Binding var email: String
    @Binding var message: String
    @Binding var submissionError: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    /// A report always carries an attached diagnostics file. Spell out what is in it
    /// so sending is an informed choice rather than a surprise.
    static let attachedDiagnostics = [
        "App version, macOS version/build, architecture, locale, and time zone",
        "Whether Zoom is installed, where it is, and whether its processes are running",
        "Network interface type, preflight checks, and the latest workflow results",
        "Up to 5,000 recent activity-log entries",
    ]

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Report a bug")
                    .font(Theme.Typography.heading)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Text("Describe what happened. Your contact information is optional.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            DisclosureGroup("What gets sent with your report") {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    ForEach(Self.attachedDiagnostics, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle")
                    }
                    Text("Home-folder paths are replaced with ~. Use Export Diagnostics in the app header to inspect the exact attachment before sending. Reports are sent over HTTPS to the 1132 Fixer bug-report service.")
                        .padding(.top, Theme.Spacing.xSmall)
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Theme.Spacing.small)
            }
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Colors.textPrimary)

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("E-mail or Telegram (optional)")
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Colors.textPrimary)
                TextField("user@example.com", text: $email)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .padding(Theme.Spacing.medium)
                    .background(Theme.Colors.surfaceModal)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    }
                    .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack {
                    Text("Message")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Required")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.error)
                    Spacer()
                    Text("\(message.count)/\(Self.maximumMessageLength)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                TextEditor(text: $message)
                    .font(Theme.Typography.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: Theme.Spacing.section * 3)
                    .padding(Theme.Spacing.small)
                    .background(Theme.Colors.surfaceModal)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    }
                    .disabled(isSubmitting)
                    .onChange(of: message) { newValue in
                        if newValue.count > Self.maximumMessageLength {
                            message = String(newValue.prefix(Self.maximumMessageLength))
                        }
                        submissionError = nil
                    }
            }

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Bug report error: \(submissionError)")
            }

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(isSubmitting)

                Spacer()

                Button(action: onSubmit) {
                    if isSubmitting {
                        HStack(spacing: Theme.Spacing.small) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send Report")
                    }
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(isSubmitting || trimmedMessage.isEmpty)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 520)
        .background(Theme.Colors.surfaceModal)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSubmitting)
        .onExitCommand {
            if !isSubmitting { onCancel() }
        }
    }
}
