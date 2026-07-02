// DesignTokens.swift — zentrale Gestaltungskonstanten
import SwiftUI

enum DesignTokens {
    /// Eckenradien: genau zwei Stufen app-weit.
    /// small = Chips und innere Elemente, card = Karten und Panels.
    static let radiusSmall: CGFloat = 16
    static let radiusCard:  CGFloat = 20
}

enum AppColors {
    /// Globaler Tint (Himmelblau) — identisch mit dem Tint in WeatherMatApp.
    static let accent = Color(hex: "#0ea5e9")
    /// Auswahl-/Hervorhebungsfarbe (Gold), z. B. Radar-Scrubber und Tages-Chips.
    static let selection = Color(hex: "#ffd166")
    /// Textfarbe auf `selection`-Hintergrund.
    static let selectionText = Color(hex: "#5f4500")
}

/// Der Standard-Liquid-Glass-Hintergrund der App: dunkler Schleier für
/// Kontrast, heller Schleier für Tiefe, Material für den Blur.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = DesignTokens.radiusCard

    func body(content: Content) -> some View {
        content
            .background(Color.black.opacity(0.08))
            .background(.white.opacity(0.11))
            .background(.ultraThinMaterial.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

extension View {
    /// Liquid-Glass-Karte mit Standard- oder abweichendem Radius.
    func glassCard(cornerRadius: CGFloat = DesignTokens.radiusCard) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }
}
