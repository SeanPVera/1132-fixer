import SwiftUI

struct BugReportFormSheet: View {
    @Binding var email: String
    @Binding var message: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    /// A report always carries an attached diagnostics file. Spell out what is in it
    /// so sending is an informed choice rather than a surprise.
    static let attachedDiagnostics = [
        "App version, macOS version and build, and Mac architecture",
        "Locale and time zone",
        "Whether Zoom is installed, where, and whether it is running",
        "Preflight checks and the result of your last run",
        "The activity log shown in the main window",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a bug")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Add an optional email and a message.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            DisclosureGroup("What gets sent with your report") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Self.attachedDiagnostics, id: \.self) { item in
                        Text("• \(item)")
                    }
                    Text("Home folder paths are replaced with ~. Use Export Diagnostics in the app header to read the exact file before sending. Reports are sent over HTTPS to the 1132 Fixer bug report service.")
                        .padding(.top, 2)
                }
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))

            VStack(alignment: .leading, spacing: 6) {
                Text("E-mail or Telegram (optional)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                TextField("user@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Message")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                TextEditor(text: $message)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.08))
                    )
                    .disabled(isSubmitting)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .disabled(isSubmitting)
                Button(isSubmitting ? "Sending..." : "Send Report", action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitting)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
