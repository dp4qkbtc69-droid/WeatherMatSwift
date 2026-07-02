// DesignTokens.swift — zentrale Gestaltungskonstanten
import SwiftUI

enum DesignTokens {
    /// Eckenradien: genau zwei Stufen app-weit.
    /// small = Chips und innere Elemente, card = Karten und Panels.
    static let radiusSmall: CGFloat = 16
    static let radiusCard:  CGFloat = 20

    enum Spacing {
        static let hairline: CGFloat = 1
        static let xsmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let xlarge: CGFloat = 20
    }

    enum Control {
        static let compactCircle: CGFloat = 34
        static let circle: CGFloat = 44
        static let timelineKnob: CGFloat = 16
    }

    enum Motion {
        static let quick: Double = 0.16
        static let standard: Double = 0.22
        static let chromeReveal: Double = 0.24
        static let chromeHide: Double = 0.32
        static let radarCrossfade: Double = 0.16
        static let chromeIdleDelayNanoseconds: UInt64 = 3_000_000_000
    }
}

enum AppColors {
    /// Globaler Tint (Himmelblau) — identisch mit dem Tint in WeatherMatApp.
    static let accent = Color(hex: "#0ea5e9")
    /// Auswahl-/Hervorhebungsfarbe (Gold), z. B. Radar-Scrubber und Tages-Chips.
    static let selection = Color(hex: "#ffd166")
    /// Textfarbe auf `selection`-Hintergrund.
    static let selectionText = Color(hex: "#5f4500")

    enum Surface {
        static let glassDark = Color.black.opacity(0.08)
        static let glassLight = Color.white.opacity(0.11)
        static let instrumentDark = Color.black.opacity(0.45)
        static let instrumentControl = Color.black.opacity(0.30)
        static let quietAction = Color.white.opacity(0.10)
        static let primaryAction = Color.white.opacity(0.18)
        static let selectedMuted = Color.white.opacity(0.12)
    }

    enum Stroke {
        static let faint = Color.white.opacity(0.14)
        static let control = Color.white.opacity(0.16)
        static let primary = Color.white.opacity(0.30)
    }

    enum Text {
        static let primary = Color.white.opacity(0.94)
        static let secondary = Color.white.opacity(0.76)
        static let tertiary = Color.white.opacity(0.56)
    }

    /// Semantic status colors, deep enough to read as a solid icon tile in
    /// light mode and as a bright glyph in dark mode.
    enum Status {
        static let success = Color(hex: "#1a8f4a")
        static let info = Color(hex: "#0e8aa8")
        static let warning = Color(hex: "#c2620a")
        static let danger = Color(hex: "#b3261e")
    }
}

/// Der Standard-Liquid-Glass-Hintergrund der App: dunkler Schleier für
/// Kontrast, heller Schleier für Tiefe, Material für den Blur.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.radiusCard
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.10))
            .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20))
            .background(.ultraThinMaterial.opacity(colorScheme == .dark ? 0.62 : 0.72))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.26), lineWidth: 1)
            )
    }
}

struct InstrumentPanelModifier: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.radiusSmall
    var materialOpacity: Double = 0.70
    var strokeOpacity: Double = 0.14
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(Color.black.opacity(colorScheme == .dark ? 0.56 : 0.40))
            .background(.ultraThinMaterial.opacity(colorScheme == .dark ? materialOpacity + 0.08 : materialOpacity))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(colorScheme == .dark ? strokeOpacity : strokeOpacity + 0.08), lineWidth: DesignTokens.Spacing.hairline)
            )
    }
}

struct QuietActionPillModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.black.opacity(colorScheme == .dark ? 0.10 : 0.06))
            .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18))
            .clipShape(Capsule())
    }
}

extension View {
    /// Liquid-Glass-Karte mit Standard- oder abweichendem Radius.
    func glassCard(cornerRadius: CGFloat = DesignTokens.radiusCard) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Dunkles Instrument-Panel fuer Karten-/Radar-Chrome.
    func instrumentPanel(cornerRadius: CGFloat = DesignTokens.radiusSmall) -> some View {
        modifier(InstrumentPanelModifier(cornerRadius: cornerRadius))
    }

    /// Leichte Aktions-Pill: sichtbar klickbar, aber sekundär.
    func quietActionPill() -> some View {
        modifier(QuietActionPillModifier())
    }
}
