import SwiftUI

enum StudioStyle {
    /// Links, symbols and native controls are ink, not colour: the Instant Print accent belongs to
    /// selection and the one primary action.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            NSColor(srgbRed: 0.86, green: 0.86, blue: 0.85, alpha: 1)
        } else {
            NSColor(srgbRed: 0.149, green: 0.165, blue: 0.196, alpha: 1)
        }
    })
    /// Filled native buttons are the screen's primary action, in developing orange with white labels.
    static let actionTint = InstantPrint.developer
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let supportingText = Color.primary.opacity(0.78)
    static let contentSpacing: CGFloat = 28
}

/// A consistent heading and spacing rhythm without putting every section in a card (the owner's flat
/// layout grammar). `paper: true` is for the rare section that is itself a document, such as a receipt.
struct StudioSection<Content: View>: View {
    let title: String
    var subtitle: String?
    var paper = false
    @ViewBuilder var content: Content

    var body: some View {
        if paper {
            PrintPanel { sectionBody }
        } else {
            sectionBody
        }
    }

    private var sectionBody: some View {
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
            Image(systemName: symbol).foregroundStyle(InstantPrint.inkSecondary)
        }
        .font(.callout)
        .foregroundStyle(InstantPrint.ink)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(InstantPrint.filterTrack, in: RoundedRectangle(cornerRadius: 6))
        .environment(\.colorScheme, .light)
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("Demo, no charges")
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(InstantPrint.demoText)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(InstantPrint.demo, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Offline demo. No charges.")
    }
}
