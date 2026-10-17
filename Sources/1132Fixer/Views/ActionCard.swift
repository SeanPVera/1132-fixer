import SwiftUI

struct ActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: Theme.Spacing.xLarge)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                        Text(title)
                            .font(Theme.Typography.subheading)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text(subtitle)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Theme.Spacing.medium)

                    Image(systemName: "arrow.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .stroke(isDisabled ? Theme.Colors.border : tint.opacity(0.75), lineWidth: 1)
            }
            .opacity(isDisabled ? 0.58 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityElement(children: .combine)
        .accessibilityHint(isDisabled ? "Unavailable until required checks pass" : subtitle)
    }
}
