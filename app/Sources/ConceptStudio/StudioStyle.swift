import SwiftUI

enum StudioStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(srgbRed: 0.42, green: 0.78, blue: 0.72, alpha: 1)
        } else {
            NSColor(srgbRed: 0.10, green: 0.38, blue: 0.35, alpha: 1)
        }
    })
    /// Filled native buttons use white labels; their background needs a darker role than links.
    static let actionTint = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(srgbRed: 0.16, green: 0.46, blue: 0.41, alpha: 1)
        } else {
            NSColor(srgbRed: 0.10, green: 0.38, blue: 0.35, alpha: 1)
        }
    })
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let supportingText = Color.primary.opacity(0.78)
    static let contentSpacing: CGFloat = 28
}

/// A consistent heading and spacing rhythm without putting every section in a card.
struct StudioSection<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).foregroundStyle(StudioStyle.supportingText).fixedSize(
                        horizontal: false,
                        vertical: true
                    )
                }
            }
            content
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StudioNotice: View {
    let text: String
    var symbol = "info.circle"

    init(_ text: String, symbol: String = "info.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(StudioStyle.accent)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StudioStyle.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DemoBadge: View {
    var body: some View {
        Label("Demo · $0", systemImage: "leaf")
            .font(.callout.weight(.semibold))
            .foregroundStyle(StudioStyle.accent)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(StudioStyle.accent.opacity(0.10), in: Capsule())
            .accessibilityLabel("Offline demo. No charges.")
    }
}
