// DayOutlookView.swift
import SwiftUI

/// Coarse, hour-level outlook for the selected day ("Trocken bis 16:00, danach
/// kräftiger Regen", "Gewitter ab 18:00 möglich") — a different question than
/// RainBannerView's "is it raining right now/soon": this answers "will there
/// be *real* rain or a storm today", staying silent for ordinary light rain.
struct DayOutlookView: View {
    let outlook: HourlyOutlook?

    var body: some View {
        if let outlook {
            content(for: outlook)
        } else {
            EmptyView()
        }
    }

    private func content(for outlook: HourlyOutlook) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: outlook))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint(for: outlook))
                .font(.system(size: 18, weight: .semibold))

            Text(outlook.text)
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint(for: outlook).opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(tint(for: outlook).opacity(0.35), lineWidth: 1)
        )
    }

    private func symbol(for outlook: HourlyOutlook) -> String {
        if outlook.isThunderstorm { return "cloud.bolt.rain.fill" }
        return outlook.severity == .heavy ? "cloud.heavyrain.fill" : "cloud.rain.fill"
    }

    /// Same colours as the radar map's "kräftig"/"stark" legend steps and
    /// RainBannerView's severity tint — one consistent visual language.
    private func tint(for outlook: HourlyOutlook) -> Color {
        if outlook.isThunderstorm { return Color(hex: "#c21882") }
        return outlook.severity == .heavy ? Color(hex: "#d93025") : Color(hex: "#f28c28")
    }
}
