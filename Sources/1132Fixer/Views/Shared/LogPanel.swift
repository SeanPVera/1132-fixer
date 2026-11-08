import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import AVFoundation

struct LogPanel: View {
    let logs: [String]
    let onCopy: () -> Void
    let onClear: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.s2) {
            HStack(spacing: Design.s1) {
                SectionHeader(title: "Activity Log", systemImage: "terminal")

                Spacer(minLength: Design.s2)

                Button(action: onCopy) {
                    Text("Copy").secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .disabled(logs.isEmpty)
                .opacity(logs.isEmpty ? 0.5 : 1.0)

                Button(action: onClear) {
                    Text("Clear").secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .disabled(logs.isEmpty)
                .opacity(logs.isEmpty ? 0.5 : 1.0)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .frame(width: 14)
                        .secondaryControl()
                }
                .buttonStyle(AppButtonStyle())
                .help(isExpanded ? "Collapse activity log" : "Expand activity log")
            }

            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if logs.isEmpty {
                            Text("No logs yet. Run an action to see output.")
                                .font(.system(size: 12, weight: .regular, design: .monospaced))
                                .foregroundStyle(Design.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, Design.s1)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Design.primaryText.opacity(0.85))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, Design.s1 + 2)
                                    .background(index.isMultiple(of: 2) ? Color.clear : Color.white.opacity(0.03))
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxHeight: .infinity)
            }
        }
        .panelChrome()
        .frame(maxHeight: isExpanded ? .infinity : nil, alignment: .topLeading)
    }
}
