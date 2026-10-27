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
                    Text("Review Repair Plan")
                        .font(Theme.Typography.sectionHeading)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Text("\(plan.steps.count) steps • \(plan.adminPromptCount) admin \(plan.adminPromptCount == 1 ? "prompt" : "prompts")")
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Text("Inspect the exact files, services, and 9-step repair sequence before starting. Nothing is modified until you choose Start Repair.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.s24)
            .background(Theme.Colors.surface)

            Divider()
                .overlay(Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s24) {
                    // Advisory warnings from readiness snapshot if any
                    if !plan.readiness.warningChecks.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                            Label("Readiness Advisories", systemImage: "exclamationmark.triangle.fill")
                                .font(Theme.Typography.label)
                                .foregroundStyle(Theme.Colors.warning)

                            ForEach(plan.readiness.warningChecks) { check in
                                HStack(alignment: .top, spacing: Theme.Spacing.s8) {
                                    Text("•")
                                        .foregroundStyle(Theme.Colors.warning)
                                    Text("\(check.label): \(check.value)")
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                }
                            }
                        }
                        .padding(Theme.Spacing.s16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.warning.opacity(0.10))
                        .overlay {
                            Rectangle()
                                .stroke(Theme.Colors.warning.opacity(0.45), lineWidth: 1)
                        }
                    }

                    // Affected Locations Ledger
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("AFFECTED LOCATIONS & SERVICES")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        VStack(spacing: 0) {
                            ForEach(Array(plan.affectedLocations.enumerated()), id: \.element.id) { index, location in
                                VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s8) {
                                        Text(location.label)
                                            .font(Theme.Typography.label)
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                        Spacer()
                                        Text(location.requiresAdmin ? "Administrator" : "User Scope")
                                            .font(Theme.Typography.metadata)
                                            .foregroundStyle(location.requiresAdmin ? Theme.Colors.warning : Theme.Colors.textSecondary)
                                            .padding(.horizontal, Theme.Spacing.s8)
                                            .padding(.vertical, 2)
                                            .background(
                                                (location.requiresAdmin ? Theme.Colors.warning : Theme.Colors.border)
                                                    .opacity(0.16)
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                                    }

                                    Text(location.path)
                                        .font(Theme.Typography.mono)
                                        .foregroundStyle(Theme.Colors.link)
                                        .textSelection(.enabled)

                                    Text(location.action)
                                        .font(Theme.Typography.metadata)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }
                                .padding(.horizontal, Theme.Spacing.s16)
                                .padding(.vertical, Theme.Spacing.s12)
                                .frame(maxWidth: .infinity, minHeight: Theme.Window.rowMinHeight, alignment: .leading)

                                if index < plan.affectedLocations.count - 1 {
                                    Divider().overlay(Theme.Colors.border)
                                }
                            }
                        }
                        .ledgerContainer(background: Theme.Colors.surface, borderColor: Theme.Colors.border)
                    }

                    // 9-Step Planned Sequence
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Text("PLANNED 9-STEP SEQUENCE")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        VStack(spacing: 0) {
                            ForEach(Array(plan.steps.enumerated()), id: \.element.id) { index, step in
                                HStack(alignment: .top, spacing: Theme.Spacing.s12) {
                                    Text("\(step.index).")
                                        .font(Theme.Typography.mono)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                        .frame(width: 24, alignment: .trailing)

                                    VStack(alignment: .leading, spacing: Theme.Spacing.s4) {
                                        HStack(spacing: Theme.Spacing.s8) {
                                            Text(step.name)
                                                .font(Theme.Typography.label)
                                                .foregroundStyle(Theme.Colors.textPrimary)
                                            Text(step.scope)
                                                .font(Theme.Typography.metadata)
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                            if step.requiresAdmin {
                                                Label("Admin Prompt", systemImage: "lock.fill")
                                                    .font(Theme.Typography.metadata)
                                                    .foregroundStyle(Theme.Colors.warning)
                                            }
                                        }
                                        Text(step.plannedSummary)
                                            .font(Theme.Typography.body)
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Spacing.s16)
                                .padding(.vertical, Theme.Spacing.s12)
                                .frame(maxWidth: .infinity, minHeight: Theme.Window.rowMinHeight, alignment: .leading)

                                if index < plan.steps.count - 1 {
                                    Divider().overlay(Theme.Colors.border)
                                }
                            }
                        }
                        .ledgerContainer(background: Theme.Colors.surface, borderColor: Theme.Colors.border)
                    }

                    // Safety Guarantees
                    VStack(alignment: .leading, spacing: Theme.Spacing.s8) {
                        Label("Safety & Sandbox Guarantees", systemImage: "checkmark.shield.fill")
                            .font(Theme.Typography.label)
                            .foregroundStyle(Theme.Colors.success)

                        ForEach(plan.safetyGuarantees, id: \.self) { guarantee in
                            HStack(alignment: .top, spacing: Theme.Spacing.s8) {
                                Text("•")
                                    .foregroundStyle(Theme.Colors.success)
                                Text(guarantee)
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(Theme.Spacing.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.surface)
                    .overlay {
                        Rectangle().stroke(Theme.Colors.border, lineWidth: 1)
                    }
                }
                .padding(Theme.Spacing.s24)
            }

            Divider()
                .overlay(Theme.Colors.border)

            // Action Footer
            HStack(spacing: Theme.Spacing.s12) {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Label("Single administrator password prompt for Steps 4 & 6", systemImage: "lock.fill")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.Colors.warning)

                Button("Start Repair", action: onConfirm)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Theme.Spacing.s24)
            .padding(.vertical, Theme.Spacing.s16)
            .background(Theme.Colors.surface)
        }
        .frame(width: 680, height: 600)
        .background(Theme.Colors.surfaceModal)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onCancel)
    }
}
