import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct BugReportFormSheet: View {
    @Binding var email: String
    @Binding var message: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            Text("Report a bug")
                .font(.system(size: 20, weight: .semibold, design: .rounded))

            Text("Add an optional email and a message.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Design.s1) {
                Text("E-mail or Telegram (optional)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                TextField("user@example.com", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
            }

            VStack(alignment: .leading, spacing: Design.s1) {
                Text("Message")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                TextEditor(text: $message)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .frame(minHeight: 120)
                    .padding(Design.s1)
                    .background(
                        RoundedRectangle(cornerRadius: Design.controlRadius, style: .continuous)
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
        .padding(Design.s3)
        .frame(width: 480)
    }
}
