import SwiftUI

/// SwiftUI view rendered inside the streaming overlay panel.
/// Displays confirmed text in primary color and unconfirmed (in-progress) text
/// in secondary color, matching R9.
struct StreamingOverlayView: View {
    let confirmed: String
    let unconfirmed: String
    /// When true the preview text dims and a progress row appears —
    /// shown between hotkey release and the final text landing, so the
    /// user isn't staring at nothing during the whole-buffer decode.
    var isFinalizing: Bool = false

    // Primary color for committed text
    private let primaryColor = Color.primary

    // Secondary color for unconfirmed/in-flight text
    private let secondaryColor = Color.secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !confirmed.isEmpty || !unconfirmed.isEmpty {
                HStack(spacing: 0) {
                    Text(confirmed)
                        .foregroundColor(primaryColor)

                    if !unconfirmed.isEmpty {
                        Text(unconfirmed)
                            .foregroundColor(secondaryColor.opacity(0.8))
                    }
                }
                .opacity(isFinalizing ? 0.45 : 1)
            }

            if isFinalizing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finalizing…")
                        .font(.caption)
                        .foregroundColor(secondaryColor)
                }
            }
        }
        .font(.system(.body, design: .default, weight: .medium))
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#if canImport(PreviewsMacros) && DEBUG
#Preview {
    StreamingOverlayView(confirmed: "Hello ", unconfirmed: "world")
        .background(Color.clear)
}
#endif
