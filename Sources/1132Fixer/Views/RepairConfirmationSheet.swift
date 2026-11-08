import SwiftUI

struct RepairConfirmationSheet: View {
    let plan: RepairPlan
    let onCancel: () -> Void
    let onConfirm: () -> Void

    init(
        plan: RepairPlan,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        self.plan = plan
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    init(
        networkChangeDescription: String,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) {
        let fallbackReadiness = ReadinessSnapshot.initial(
            selectedAppPath: ZoomLocation.defaultAppPath,
            isCustomLocation: false
        )
        self.plan = RepairPlan.build(
            readiness: fallbackReadiness,
            selectedAppPath: ZoomLocation.defaultAppPath,
            isCustomLocation: false
        )
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sheet Header
            VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Review repair plan")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Signal.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(plan.steps.count) steps · \(plan.adminPromptCount) admin \(plan.adminPromptCount == 1 ? "prompt" : "prompts")")
                        .font(Theme.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Signal.textSecondary)
                }

                Text("Inspect the exact files, services, and 9-step repair sequence before starting. Nothing is modified until you choose Start repair.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Signal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.s24)

            Divider()
                .overlay(Theme.Signal.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s24) {
                    // Advisory warnings from readiness snapshot if any
                    if !plan.readiness.warningChecks.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                            Label("Readiness advisories", systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Signal.warning)

                            ForEach(plan.readiness.warningChecks) { check in
                                HStack(alignment: .top, spacing: Theme.Spacing.s8) {
                                    Text("•")
                                        .foregroundStyle(Theme.Signal.warning)
                                    Text("\(check.label): \(check.value)")
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Signal.textPrimary)
                                }
                            }
                        }
                        .padding(Theme.Spacing.s16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ledgerContainer(background: Theme.Signal.surfaceModal)
                    }

                    // Affected Locations Ledger
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("Affected locations and services")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Signal.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(Array(plan.affectedLocations.enumerated()), id: \.element.id) { index, location in
                                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
                                        Text(location.label)
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(Theme.Signal.textPrimary)
                                        Spacer()
                                        StatusTag(
                                            text: location.requiresAdmin ? "Administrator" : "User scope",
                                            tone: location.requiresAdmin ? .warning : .neutral
                                        )
                                    }

                                    Text(location.path)
                                        .font(Theme.Typography.mono)
                                        .foregroundStyle(Theme.Signal.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)

                                    Text(location.action)
                                        .font(Theme.Typography.metadata)
                                        .foregroundStyle(Theme.Signal.textSecondary)
                                }
                                .padding(.horizontal, Theme.Spacing.s16)
                                .padding(.vertical, Theme.Spacing.s12)
                                .frame(maxWidth: .infinity, minHeight: Theme.Window.rowMinHeight, alignment: .leading)

                                if index < plan.affectedLocations.count - 1 {
                                    Divider().overlay(Theme.Signal.border)
                                }
                            }
                        }
                        .ledgerContainer(background: Theme.Signal.surfaceModal)
                    }

                    // 9-Step Planned Sequence
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("Planned \(plan.steps.count)-step sequence")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Signal.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                HStack(alignment: .top, spacing: Theme.Spacing.s12) {
                                    Text(String(format: "%02d", step.index))
                                        .font(Theme.Typography.mono)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.Signal.textSecondary)
                                        .frame(width: 24, alignment: .trailing)

                                    VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
                                            Text(step.name)
                                                .font(Theme.Typography.label)
                                                .foregroundStyle(Theme.Signal.textPrimary)
                                            Text(step.scope)
                                                .font(Theme.Typography.metadata)
                                                .foregroundStyle(Theme.Signal.textSecondary)
                                            if step.requiresAdmin {
                                                Label("Admin prompt", systemImage: "lock.fill")
                                                    .font(Theme.Typography.metadata)
                                                    .foregroundStyle(Theme.Signal.warning)
                                            }
                                        }
                                        Text(step.plannedSummary)
                                            .font(Theme.Typography.body)
                                            .foregroundStyle(Theme.Signal.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Spacing.s16)
                                .padding(.vertical, Theme.Spacing.s12)
                                .frame(maxWidth: .infinity, minHeight: Theme.Window.rowMinHeight, alignment: .leading)

                                if index < plan.steps.count - 1 {
                                    Divider().overlay(Theme.Signal.border)
                                }
                            }
                        }
                        .ledgerContainer(background: Theme.Signal.surfaceModal)
                    }

                    // Safety Guarantees
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Label("Safety and sandbox guarantees", systemImage: "checkmark.shield.fill")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Signal.success)

                        ForEach(plan.safetyGuarantees, id: \.self) { guarantee in
                            HStack(alignment: .top, spacing: Theme.Spacing.s8) {
                                Text("•")
                                    .foregroundStyle(Theme.Signal.success)
                                Text(guarantee)
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Signal.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(Theme.Spacing.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .ledgerContainer(background: Theme.Signal.surfaceModal)
                }
                .padding(Theme.Spacing.s24)
            }

            Divider()
                .overlay(Theme.Signal.border)

            // Action Footer
            HStack(spacing: Theme.Spacing.s12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Label("Single administrator password prompt for steps 4 and 6", systemImage: "lock.fill")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Signal.warning)

                Button("Start repair", action: onConfirm)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Spacing.s24)
            .padding(.vertical, Theme.Spacing.s16)
        }
        .frame(width: 680, height: 600)
        .background(Theme.Signal.surfaceModal)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onCancel)
    }
}
