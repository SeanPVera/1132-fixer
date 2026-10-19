import SwiftUI

struct BugReportFormSheet: View {
    static let maximumMessageLength = ReportDraft.maxDescriptionCharacters

    let draft: ReportDraft
    @Binding var email: String
    @Binding var message: String
    @Binding var submissionError: String?
    @Binding var isAttachmentPreviewExpanded: Bool
    let isSubmitting: Bool
    let onSaveAttachment: () -> Void
    let onCancel: () -> Void
    let onSubmit: () -> Void

    static let attachedDiagnostics = [
        "App version, macOS version/build, architecture, locale, and time zone",
        "Whether Zoom is installed, where it is, and whether its processes are running",
        "Network interface type, preflight checks, and the latest workflow results",
        "Up to 5,000 recent activity-log entries (redacted for home-directory privacy)",
    ]

    init(
        draft: ReportDraft,
        email: Binding<String>,
        message: Binding<String>,
        submissionError: Binding<String?>,
        isAttachmentPreviewExpanded: Binding<Bool> = .constant(true),
        isSubmitting: Bool,
        onSaveAttachment: @escaping () -> Void = {},
        onCancel: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        self.draft = draft
        self._email = email
        self._message = message
        self._submissionError = submissionError
        self._isAttachmentPreviewExpanded = isAttachmentPreviewExpanded
        self.isSubmitting = isSubmitting
        self.onSaveAttachment = onSaveAttachment
        self.onCancel = onCancel
        self.onSubmit = onSubmit
    }

    init(
        email: Binding<String>,
        message: Binding<String>,
        submissionError: Binding<String?>,
        isSubmitting: Bool,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping () -> Void
    ) {
        let placeholder = ReportDraft(
            id: UUID(),
            createdAt: Date(),
            title: "Bug Report",
            appVersion: "1.8.2",
            selectedAppPath: ZoomLocation.defaultAppPath,
            systemInfo: "",
            readinessSummary: "Ready",
            runSummary: "No repair run in this session",
            diagnosticsFileName: AppViewModel.diagnosticsFileName,
            fullDiagnosticsContent: "",
            attachmentContent: "",
            attachmentData: Data(),
            originalByteCount: 0,
            wasTruncated: false
        )
        self.init(
            draft: placeholder,
            email: email,
            message: message,
            submissionError: submissionError,
            isAttachmentPreviewExpanded: .constant(true),
            isSubmitting: isSubmitting,
            onSaveAttachment: {},
            onCancel: onCancel,
            onSubmit: onSubmit
        )
    }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var excessCharacterCount: Int {
        max(0, message.count - Self.maximumMessageLength)
    }

    private var isMessageOverLimit: Bool {
        excessCharacterCount > 0
    }

    private var canSubmit: Bool {
        !isSubmitting && !trimmedMessage.isEmpty && !isMessageOverLimit
    }

    private var formattedAttachmentSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(draft.attachmentData.count), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sheet Header
            VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Report an Issue")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Text("Snapshot captured at sheet open")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Text("Describe what happened. Home-folder paths are redacted with ~. Inspect or save the exact diagnostic attachment below before sending.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.s24)
            .background(Theme.Colors.surface)

            Divider().overlay(Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s16) {
                    // Frozen Diagnostic Attachment Review
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Theme.Spacing.s12) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                HStack(spacing: Theme.Spacing.s8) {
                                    Label(draft.diagnosticsFileName, systemImage: "doc.text")
                                        .font(Theme.Typography.label)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text(formattedAttachmentSize)
                                        .font(Theme.Typography.mono)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    if draft.wasTruncated {
                                        Text("Truncated to 1 MB limit")
                                            .font(Theme.Typography.metadata)
                                            .foregroundStyle(Theme.Colors.warning)
                                            .padding(.horizontal, Theme.Spacing.s8)
                                            .padding(.vertical, 2)
                                            .background(Theme.Colors.warning.opacity(0.15))
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                    }
                                }
                                Text("Target: \(draft.selectedAppPath) • \(draft.runSummary)")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button("Save Log…", action: onSaveAttachment)
                                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                                .disabled(isSubmitting)

                            Button {
                                isAttachmentPreviewExpanded.toggle()
                            } label: {
                                Label(
                                    isAttachmentPreviewExpanded ? "Hide Preview" : "Preview Payload",
                                    systemImage: isAttachmentPreviewExpanded ? "chevron.up" : "chevron.down"
                                )
                            }
                            .buttonStyle(QuietLinkButtonStyle())
                        }
                        .padding(Theme.Spacing.s12)

                        if isAttachmentPreviewExpanded {
                            Divider().overlay(Theme.Colors.border)

                            ScrollView {
                                Text(draft.attachmentContent)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(Theme.Spacing.s12)
                            }
                            .frame(height: 150)
                            .background(Theme.Colors.background)
                        }
                    }
                    .ledgerContainer(background: Theme.Colors.surface, borderColor: Theme.Colors.border)

                    // Optional Contact Field
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("E-mail or Telegram (optional)")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        TextField("user@example.com", text: $email)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .padding(Theme.Spacing.s12)
                            .background(Theme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .stroke(Theme.Colors.borderControl, lineWidth: 1)
                            }
                            .disabled(isSubmitting)
                    }

                    // Required Message Editor (never truncates user input beyond 4,000 characters)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("What happened?")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text("Required")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.Colors.warning)
                            Spacer()
                            if isMessageOverLimit {
                                Text("Exceeds limit by \(excessCharacterCount) (\(message.count)/\(Self.maximumMessageLength))")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Colors.error)
                            } else {
                                Text("\(message.count)/\(Self.maximumMessageLength)")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }

                        TextEditor(text: $message)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .padding(Theme.Spacing.s8)
                            .background(Theme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .stroke(
                                        isMessageOverLimit ? Theme.Colors.error : Theme.Colors.borderControl,
                                        lineWidth: 1
                                    )
                            }
                            .disabled(isSubmitting)
                            .onChange(of: message) { _ in
                                submissionError = nil
                            }

                        if isMessageOverLimit {
                            Label(
                                "Your text is preserved. Shorten the description by \(excessCharacterCount) \(excessCharacterCount == 1 ? "character" : "characters") to enable Send Report.",
                                systemImage: "exclamationmark.circle.fill"
                            )
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Colors.error)
                        }
                    }

                    if let submissionError {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Bug report error: \(submissionError)")
                    }
                }
                .padding(Theme.Spacing.s24)
            }

            Divider().overlay(Theme.Colors.border)

            // Action Footer
            HStack(spacing: Theme.Spacing.s12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .disabled(isSubmitting)

                Spacer()

                Button(action: onSubmit) {
                    if isSubmitting {
                        HStack(spacing: Theme.Spacing.s8) {
                            ProgressView().controlSize(.small)
                            Text("Sending…")
                        }
                    } else {
                        Text("Send Report")
                    }
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, Theme.Spacing.s24)
            .padding(.vertical, Theme.Spacing.s16)
            .background(Theme.Colors.surface)
        }
        .frame(width: 640, height: 620)
        .background(Theme.Colors.surfaceModal)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSubmitting)
        .onExitCommand {
            if !isSubmitting { onCancel() }
        }
    }
}
