import SwiftUI
import UIKit
import CoreText

/// Visual tokens taken from the In Process web app (inprocess.world): warm ink on
/// paper, Spectral for editorial titles, Archivo for interface text, flat surfaces
/// with hairline borders. Dark values are this app's own counterpart; the web app
/// ships a light theme only.
enum Theme {
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        func color(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? color(dark) : color(light) })
    }
    /// Text and primary buttons. Web: grey-moss-900.
    static let ink = dynamic(0x1B1504, 0xF3F0E9)
    /// Text on an ink fill.
    static let onInk = dynamic(0xFFFFFF, 0x1B1504)
    /// Page background. Web mobile is white under a grey paper texture; this is its flat equivalent.
    static let paper = dynamic(0xF3F1EC, 0x14110A)
    /// Cards and fields.
    static let surface = dynamic(0xFFFFFF, 0x1F1B12)
    /// Hairline borders and quiet fills. Web: grey-moss-100.
    static let line = dynamic(0xE0DDD8, 0x39342A)
    /// Secondary text. Web: grey-moss-300.
    static let secondaryText = dynamic(0x605F5C, 0xA8A49B)
    /// Links and prices. Web: tan-gold.
    static let gold = dynamic(0xA8862F, 0xD2B25E)
    /// Active status dot. Web: tan.
    static let amber = dynamic(0xFDAD00, 0xFDAD00)
    /// Errors. Web: red.
    static let error = dynamic(0xAA2E2E, 0xE58A8A)

    static let buttonRadius: CGFloat = 8
    static let cardRadius: CGFloat = 6

    // Fonts scale with Dynamic Type through `relativeTo`.
    /// Editorial headline, as the web app's "a collective timeline for artists": Spectral italic, set tight.
    static let display = Font.custom("Spectral-Italic", size: 38, relativeTo: .largeTitle)
    /// Large counter, as the web app's Moments count.
    static let stat = Font.custom("Archivo-Medium", size: 40, relativeTo: .largeTitle)
    /// Small emphasised note beside a counter or as a bracketed link.
    static let note = Font.custom("Archivo-Medium", size: 12, relativeTo: .caption)
    static let wordmark = Font.custom("Spectral-Regular", size: 22, relativeTo: .headline)
    static let title = Font.custom("Archivo-Medium", size: 24, relativeTo: .title2)
    static let headline = Font.custom("Archivo-SemiBold", size: 17, relativeTo: .headline)
    static let button = Font.custom("Archivo-Medium", size: 17, relativeTo: .headline)
    static let body = Font.custom("Archivo-Regular", size: 17, relativeTo: .body)
    static let callout = Font.custom("Archivo-Regular", size: 16, relativeTo: .callout)
    static let footnote = Font.custom("Archivo-Regular", size: 13, relativeTo: .footnote)
    static let caption = Font.custom("Archivo-Regular", size: 11, relativeTo: .caption2)
    /// Uppercase tracked section label, as on the web app's "MOMENTS" counter.
    static let label = Font.custom("Archivo-Regular", size: 11, relativeTo: .caption2)

    /// Registers the bundled fonts once. If a file is missing, text falls back to the system font.
    static func registerFonts() {
        _ = registered
    }
    private static let registered: Bool = {
        for name in ["Archivo-Regular", "Archivo-Medium", "Archivo-SemiBold", "Spectral-Regular", "Spectral-Italic", "Spectral-Medium"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        return true
    }()
}

extension View {
    /// White card with a hairline border and the web app's soft, low shadow.
    func themeCard() -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Theme.line, lineWidth: 1))
            .shadow(color: Theme.ink.opacity(0.08), radius: 8, y: 4)
    }
    /// Text field on a white surface. The hairline border turns to ink while the field has focus.
    func themeField(focused: Bool = false) -> some View {
        textFieldStyle(.plain).padding(.horizontal, 14).padding(.vertical, 14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.buttonRadius).strokeBorder(focused ? Theme.ink : Theme.line, lineWidth: focused ? 1.5 : 1))
            .animation(.easeOut(duration: 0.2), value: focused)
    }
    /// Entrance: fades in and rises a little, staggered by `index`. With Reduce Motion it only fades.
    func appear(_ index: Int) -> some View { modifier(Appear(index: index)) }
    /// Groups fine print into one bordered block under a small label.
    func themeNoteCard() -> some View {
        font(Theme.footnote).foregroundStyle(Theme.secondaryText)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading).themeCard()
    }
    /// Uppercase tracked section label.
    func themeSectionLabel() -> some View {
        font(Theme.label).textCase(.uppercase).tracking(1.1).foregroundStyle(Theme.secondaryText)
    }
}

/// Two-line editorial title. Spectral's line height is tall, so lines are set closer than the font would.
struct DisplayTitle: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: -16) {
            ForEach(lines, id: \.self) { Text($0) }
        }
        .font(Theme.display).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(lines.joined(separator: " ")).accessibilityAddTraits(.isHeader)
    }
}

private struct Appear: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown || reduceMotion ? 0 : 12)
            .onAppear { withAnimation(.easeOut(duration: 0.5).delay(Double(index) * 0.07)) { shown = true } }
    }
}

/// Small gold action set in square brackets, as the web app's "[ View collection ]".
struct BracketButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Text("[").accessibilityHidden(true); configuration.label; Text("]").accessibilityHidden(true)
        }
        .font(Theme.note)
        .foregroundStyle((configuration.role == .destructive ? Theme.error : Theme.gold).opacity(enabled ? (configuration.isPressed ? 0.5 : 1) : 0.4))
        .padding(.vertical, 6).contentShape(Rectangle())
    }
}

/// Text-only action: underlined so it reads as tappable next to body text.
struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.callout).underline()
            .foregroundStyle((configuration.role == .destructive ? Theme.error : Theme.ink).opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
            .padding(.vertical, 4).contentShape(Rectangle())
    }
}

/// Quiet secondary action: a soft fill with ink text.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.callout).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.4))
            .background(Theme.line.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: Theme.buttonRadius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1).animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
