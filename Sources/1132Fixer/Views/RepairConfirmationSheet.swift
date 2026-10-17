import SwiftUI

struct RepairConfirmationSheet: View {
    private struct RepairAction: Identifiable {
        let title: String
        let icon: String
        var id: String { title }
    }

    let networkChangeDescription: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    private let actions = [
        RepairAction(title: "Close Zoom and verify it has stopped", icon: "xmark.circle"),
        RepairAction(title: "Create a private recovery backup before deleting local state", icon: "externaldrive.badge.timemachine"),
        RepairAction(title: "Clear Zoom caches, preferences, saved state, and local logs", icon: "trash"),
        RepairAction(title: "Flush the system DNS cache", icon: "arrow.clockwise"),
        RepairAction(title: "Launch the verified Zoom app inside the required sandbox", icon: "lock.shield"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                Text("Ready to repair Zoom?")
                    .font(Theme.Typography.heading)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("Review the changes before continuing. Nothing happens until you choose Start Repair.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                ForEach(actions) { action in
                    Label(action.title, systemImage: action.icon)
                }
                Label(networkChangeDescription, systemImage: "network")
            }
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.textPrimary)

            Label(
                "macOS may ask for an administrator password for network and DNS operations.",
                systemImage: "lock.fill"
            )
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.warning)
            .padding(Theme.Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.warning.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))

            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(ThemedButtonStyle(variant: .secondary))
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Repair", action: onConfirm)
                    .buttonStyle(ThemedButtonStyle(variant: .primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xLarge)
        .frame(width: 540)
        .background(Theme.Colors.surfaceModal)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onCancel)
    }
}
