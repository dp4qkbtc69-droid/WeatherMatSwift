// RainBannerView.swift
import SwiftUI

struct RainBannerView: View {
    let rain: RainAnalysis

    var body: some View {
        if rain.type == .clear { EmptyView() }
        else { banner }
    }

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: rain.sfSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 26))
                .symbolEffect(.pulse.byLayer, options: .repeating, isActive: rain.type == .now)

            VStack(alignment: .leading, spacing: 2) {
                Text(rain.text)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                if !rain.sub.isEmpty {
                    Text(rain.sub)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                }
            }

            Spacer()

            ConfidenceDot(level: rain.confidence)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.11))
        .background(.ultraThinMaterial.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Model Trust
struct ModelTrustView: View {
    let confidence:       ConfidenceLevel
    let activeModels:     [String]
    let agreementPct:     Int
    /// nil or 0 = today. Drives which model(s) are shown as dominant.
    var selectedDayIndex: Int? = nil

    // Hours to the midpoint of the selected day
    private var horizonHours: Double {
        Double((selectedDayIndex ?? 0) * 24 + 12)
    }

    /// The 1–2 most influential models for the current horizon.
    private var dominantLabel: String {
        guard !activeModels.isEmpty else { return "–" }
        let h = horizonHours
        let scored = activeModels.map { ($0, ForecastModelRules.horizonMultiplier($0, hoursAhead: h)) }
        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return activeModels.joined(separator: " · ") }
        // Include all models within 70 % of the best score
        let threshold = top.1 * 0.70
        return scored
            .filter { $0.1 >= threshold }
            .map(\.0)
            .joined(separator: " · ")
    }

    /// Short human label for the horizon (e.g. "+3 Tage", "Heute")
    private var horizonLabel: String {
        let idx = selectedDayIndex ?? 0
        if idx == 0 { return "Heute" }
        return "+\(idx) \(idx == 1 ? "Tag" : "Tage")"
    }

    var body: some View {
        HStack(spacing: 10) {
            ConfidenceDot(level: confidence)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Modell-Einigkeit: \(agreementPct)%")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(horizonLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                // Dominant model(s) for this horizon — bold
                Text(dominantLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                // All active models — dimmer, so user can verify what's actually loaded
                if activeModels.count > 1 {
                    Text(activeModels.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(confidence.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(confidence.color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(confidence.color.opacity(0.15))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Warnings Banner
struct WarningsBannerView: View {
    let warnings: [DWDWarning]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(warnings.prefix(3)) { w in
                HStack(spacing: 10) {
                    Image(systemName: w.severity.sfSymbol)
                        .foregroundStyle(w.severity.color)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.headlineDe)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(w.eventDe)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(w.severity.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

// MARK: - Confidence dot helper
struct ConfidenceDot: View {
    let level: ConfidenceLevel
    var body: some View {
        Circle()
            .fill(level.color)
            .frame(width: 10, height: 10)
            .shadow(color: level.color.opacity(0.6), radius: 4)
    }
}
