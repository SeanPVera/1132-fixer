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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(tint)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(subtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.26))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(tint.opacity(0.65), lineWidth: 1)
            )
            .opacity(isDisabled ? 0.58 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
