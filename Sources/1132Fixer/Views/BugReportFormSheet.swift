import SwiftUI

struct BugReportFormSheet: View {
    @Binding var email: String
    @Binding var message: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a bug")
                .font(.system(size: 18, weight: .bold, design: .rounded))

            Text("Add an optional email and a message.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

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
