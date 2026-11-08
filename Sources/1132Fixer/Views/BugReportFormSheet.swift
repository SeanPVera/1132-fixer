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
        "Up to 2,000 recent log entries within 512 KiB; home paths and MAC addresses are sanitized",
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
                    Text("Report a bug")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Signal.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("Snapshot captured at sheet open")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Signal.textSecondary)
                }

                Text("Describe what happened. Home-folder paths are redacted with ~. Inspect or save the exact diagnostic attachment below before sending.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.s24)

            Divider().overlay(Theme.Signal.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s16) {
                    // Frozen Diagnostic Attachment Review
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: Theme.Spacing.s12) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                HStack(spacing: Theme.Spacing.s8) {
                                    Label(draft.diagnosticsFileName, systemImage: "doc.text")
                                        .font(Theme.Typography.label)
                                        .foregroundStyle(Theme.Signal.textPrimary)
                                    Text(formattedAttachmentSize)
                                        .font(Theme.Typography.mono)
                                        .foregroundStyle(Theme.Signal.textSecondary)
                                    if draft.wasTruncated {
                                        StatusTag(text: "Truncated to 1 MiB limit", tone: .warning)
                                    }
                                }
                                Text("Target: \(draft.selectedAppPath) · \(draft.runSummary)")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Signal.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Button("Save log…", action: onSaveAttachment)
                                .buttonStyle(ThemedButtonStyle(variant: .secondary))
                                .disabled(isSubmitting)

                            Button {
                                isAttachmentPreviewExpanded.toggle()
                            } label: {
                                Label(
                                    isAttachmentPreviewExpanded ? "Hide preview" : "Show preview",
                                    systemImage: isAttachmentPreviewExpanded ? "chevron.up" : "chevron.down"
                                )
                            }
                            .buttonStyle(QuietLinkButtonStyle())
                        }
                        .padding(Theme.Spacing.s12)

                        if isAttachmentPreviewExpanded {
                            Divider().overlay(Theme.Signal.border)

                            ScrollView {
                                Text(draft.attachmentContent)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Signal.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(Theme.Spacing.s12)
                            }
                            .frame(height: 150)
                            .background(Theme.Signal.background)
                        }
                    }
                    .ledgerContainer(background: Theme.Signal.surfaceModal)

                    // Optional Contact Field
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("E-mail or Telegram (optional)")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Signal.textPrimary)
                        TextField("user@example.com", text: $email)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Signal.textPrimary)
                            .padding(Theme.Spacing.s12)
                            .background(Theme.Signal.surfaceModal)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .stroke(Theme.Signal.borderControl, lineWidth: 1)
                            }
                            .disabled(isSubmitting)
                    }

                    // Required Message Editor (never truncates user input beyond 4,000 characters)
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("What happened?")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Signal.textPrimary)
                            Text("Required")
                                .font(Theme.Typography.metadata)
                                .foregroundStyle(Theme.Signal.textSecondary)
                            Spacer()
                            if isMessageOverLimit {
                                Text("Exceeds limit by \(excessCharacterCount) (\(message.count)/\(Self.maximumMessageLength))")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Signal.error)
                            } else {
                                Text("\(message.count)/\(Self.maximumMessageLength)")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Signal.textSecondary)
                            }
                        }

                        TextEditor(text: $message)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Signal.textPrimary)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 120)
                            .padding(Theme.Spacing.s8)
                            .background(Theme.Signal.surfaceModal)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .stroke(
                                        isMessageOverLimit ? Theme.Signal.error : Theme.Signal.borderControl,
                                        lineWidth: 1
                                    )
                            }
                            .disabled(isSubmitting)
                            .onChange(of: message) { _ in
                                submissionError = nil
                            }

                        if isMessageOverLimit {
                            Label(
                                "Your text is preserved. Shorten the description by \(excessCharacterCount) \(excessCharacterCount == 1 ? "character" : "characters") to enable Send report.",
                                systemImage: "exclamationmark.circle.fill"
                            )
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.Signal.error)
                        }
                    }

                    if let submissionError {
                        Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Signal.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("Bug report error: \(submissionError)")
                    }
                }
                .padding(Theme.Spacing.s24)
            }

            Divider().overlay(Theme.Signal.border)

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
                        Text("Send report")
                    }
                }
                .buttonStyle(ThemedButtonStyle(variant: .primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .padding(.horizontal, Theme.Spacing.s24)
            .padding(.vertical, Theme.Spacing.s16)
        }
        .frame(width: 640, height: 620)
        .background(Theme.Signal.surfaceModal)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(isSubmitting)
        .onExitCommand {
            if !isSubmitting { onCancel() }
        }
    }
}
