import AppKit
import CoreText
import SwiftUI

/// The Instant Print design language: a film-back charcoal frame around warm white prints, one
/// developing-orange accent for the selection and the primary action, and neutral state labels
/// except where a sample needs attention.
enum InstantPrint {
    static let frame = Color(red: 0.157, green: 0.157, blue: 0.157)
    static let frameText = Color(red: 0.949, green: 0.949, blue: 0.949)
    static let frameItem = Color(red: 0.902, green: 0.906, blue: 0.910)
    static let frameMuted = Color(red: 0.643, green: 0.655, blue: 0.659)
    static let frameRule = Color.white.opacity(0.16)
    static let selectedStep = Color(red: 0.349, green: 0.220, blue: 0.157)
    /// Developing orange: the selected print's ring and the one primary action, nothing else.
    static let developer = Color(red: 0.973, green: 0.388, blue: 0.098)
    static let ground = dynamic(light: (0.961, 0.961, 0.957), dark: (0.118, 0.118, 0.114))
    /// Prints stay paper-white in both appearances; they are objects on the table, not chrome.
    static let paper = Color(red: 0.988, green: 0.988, blue: 0.984)
    static let ink = Color(red: 0.149, green: 0.165, blue: 0.196)
    static let inkSecondary = Color(red: 0.333, green: 0.337, blue: 0.369)
    static let rule = Color(red: 0.820, green: 0.824, blue: 0.851)
    static let chip = Color(red: 0.922, green: 0.922, blue: 0.922)
    static let chipText = Color(red: 0.286, green: 0.298, blue: 0.333)
    static let attention = Color(red: 0.965, green: 0.816, blue: 0.820)
    static let attentionWash = Color(red: 0.992, green: 0.949, blue: 0.949)
    static let attentionText = Color(red: 0.600, green: 0.098, blue: 0.118)
    static let triggerMark = Color(red: 0.973, green: 0.839, blue: 0.765)
    static let demo = Color(red: 0.227, green: 0.333, blue: 0.275)
    static let demoText = Color(red: 0.937, green: 0.949, blue: 0.937)
    static let filterTrack = Color(red: 0.933, green: 0.933, blue: 0.933)
    static let filterSelected = Color(red: 0.251, green: 0.255, blue: 0.251)

    static let displayFontName = "UbuntuSans-Bold"

    /// The trigger's display face, bundled with the app (Ubuntu Font Licence 1.0).
    static func display(size: CGFloat) -> Font {
        registerFonts
        return .custom(displayFontName, size: size)
    }

    private static let registerFonts: Void = {
        guard let url = Bundle.module.url(forResource: "UbuntuSans-Bold", withExtension: "ttf", subdirectory: "Fonts")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Where a sample stands in review. Only "needs attention" is coloured; the rest are neutral.
enum PrintState: Equatable {
    case final, edited, attention(String?), excluded, other(String)

    var label: String {
        switch self {
        case .final: "Final"
        case .edited: "Edited"
        case .attention: "Needs attention"
        case .excluded: "Excluded"
        case let .other(label): label
        }
    }

    var needsAttention: Bool {
        if case .attention = self { return true }
        return false
    }
}

struct PrintStateChip: View {
    let state: PrintState

    var body: some View {
        Text(state.label)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(state.needsAttention ? InstantPrint.attentionText : InstantPrint.chipText)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(
                state.needsAttention ? InstantPrint.attention : InstantPrint.chip,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .accessibilityLabel("State: \(state.label)")
    }
}

/// Caption text with each trigger marked, so the concept boundary reads at a glance.
struct TriggerCaption: View {
    let text: String
    let triggers: [String]
    var size: CGFloat = 12.5
    var lineLimit: Int? = 2

    var body: some View {
        Text(marked).font(.system(size: size)).foregroundStyle(InstantPrint.ink)
            .lineLimit(lineLimit).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var marked: AttributedString {
        var string = AttributedString(text)
        for trigger in triggers where !trigger.isEmpty {
            var searchStart = string.startIndex
            while let range = string[searchStart...].range(of: trigger) {
                string[range].backgroundColor = InstantPrint.triggerMark
                string[range].font = .system(size: size, weight: .semibold)
                searchStart = range.upperBound
            }
        }
        return string
    }
}

/// One sample as an instant print: the photo inset on white paper, its first caption lines and its
/// state written in the deep bottom margin. Excluded prints are struck through.
struct PrintCard: View {
    let image: ProjectImage
    let state: PrintState
    let triggers: [String]
    let photoHeight: CGFloat
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrainingTargetPreview(url: image.url, fill: true)
                .frame(maxWidth: .infinity).frame(height: photoHeight).clipped()
                .opacity(state == .excluded ? 0.55 : 1)
                .overlay { if state == .excluded { StrikeLine() } }
            VStack(alignment: .leading, spacing: 6) {
                TriggerCaption(
                    text: image.caption.isEmpty ? "No caption yet" : image.caption,
                    triggers: image.caption.isEmpty ? [] : triggers
                )
                .frame(height: 32, alignment: .topLeading)
                PrintStateChip(state: state)
                if case let .attention(note?) = state {
                    Text(note).font(.system(size: 11.5)).foregroundStyle(InstantPrint.ink)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(InstantPrint.attention, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 8)
        }
        .padding([.horizontal, .top], 6)
        .background(state.needsAttention ? InstantPrint.attentionWash : InstantPrint.paper)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1.5)
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 5).strokeBorder(InstantPrint.developer, lineWidth: 2).padding(-3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(image.id), \(state.label)")
    }
}

/// The diagonal stroke across an excluded print, drawn by the app over the untouched photo.
struct StrikeLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0, y: geometry.size.height))
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
            }
            .stroke(.white.opacity(0.9), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Print buttons: the developing-orange primary action, a grey secondary and a plain outlined one.
struct PrintButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, plain }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: kind == .primary ? .bold : kind == .plain ? .regular : .semibold))
            .foregroundStyle(kind == .primary ? Color.white : InstantPrint.ink)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(background, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if kind == .plain {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(InstantPrint.rule, lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private var background: Color {
        switch kind {
        case .primary: InstantPrint.developer
        case .secondary: InstantPrint.chip
        case .plain: Color.white
        }
    }
}
