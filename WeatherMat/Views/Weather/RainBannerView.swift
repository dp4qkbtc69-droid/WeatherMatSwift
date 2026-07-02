// RainBannerView.swift
import SwiftUI

struct RainBannerView: View {
    let rain: RainAnalysis

    var body: some View {
        if shouldShowBanner { banner }
        else { EmptyView() }
    }

    private var shouldShowBanner: Bool {
        rain.type != .clear ||
        rain.minutesUntilClear != nil ||
        hasChartSignal
    }

    private var hasChartSignal: Bool {
        rain.chart.contains { $0.precipitationRate > 0.05 || $0.probability > 50 }
    }

    private var showsOnlyChartSignal: Bool {
        rain.type == .clear && rain.minutesUntilClear == nil && hasChartSignal
    }

    private var displayText: String {
        showsOnlyChartSignal ? "Regen möglich" : rain.text
    }

    private var displaySymbol: String {
        showsOnlyChartSignal ? "cloud.drizzle.fill" : rain.sfSymbol
    }

    private var banner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: displaySymbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 26))
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: rain.type == .now)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayText)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(.white)
                    if !rain.sub.isEmpty {
                        Text(rain.sub)
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                    }
                }

                Spacer()

                ConfidenceDot(level: rain.confidence)
            }

            if !rain.chart.isEmpty {
                RainMiniChartView(points: rain.chart)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(cornerRadius: 16)
    }
}

private struct RainMiniChartView: View {
    let points: [RainChartPoint]

    private var sampledPoints: [RainChartPoint] {
        guard points.count > 18 else { return points }
        let stride = max(1, Int(ceil(Double(points.count) / 18.0)))
        return points.enumerated().compactMap { index, point in
            index % stride == 0 ? point : nil
        }
    }

    private var maxRate: Double {
        max(0.4, actualMaxRate)
    }

    private var actualMaxRate: Double {
        sampledPoints.map(\.precipitationRate).max() ?? 0
    }

    private var horizonLabel: String {
        guard let first = points.first?.time,
              let last = points.last?.time
        else { return "Niederschlag" }
        let minutes = max(1, Int(last.timeIntervalSince(first) / 60))
        return minutes < 90
            ? "Niederschlag nächste \(minutes) min"
            : "Niederschlag nächste \(Int((Double(minutes) / 60).rounded())) h"
    }

    private var maxRateLabel: String {
        guard actualMaxRate > 0 else { return "0 mm/h" }
        return actualMaxRate < 1 ? "<1 mm/h" : String(format: "%.1f mm/h", actualMaxRate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(horizonLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(maxRateLabel)
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(sampledPoints) { point in
                    Capsule()
                        .fill(barColor(for: point))
                        .frame(height: max(4, min(32, point.precipitationRate / maxRate * 32)))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(chartLabel(for: point))
                }
            }
            .frame(height: 34, alignment: .bottom)
        }
    }

    private func barColor(for point: RainChartPoint) -> Color {
        point.precipitationRate > 0.2
            ? Color(hex: "#9ee8ff")
            : Color.white.opacity(point.probability > 50 ? 0.5 : 0.22)
    }

    private func chartLabel(for point: RainChartPoint) -> String {
        let time = point.time.formatted(.dateTime.hour().minute())
        return String(format: "%@ %.1f mm/h, %.0f %%", time, point.precipitationRate, point.probability)
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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(horizonLabel)
                        .font(.system(.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.1))
                        .clipShape(Capsule())
                }
                // Dominant model(s) for this horizon — bold
                Text(dominantLabel)
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                // All active models — dimmer, so user can verify what's actually loaded
                if activeModels.count > 1 {
                    Text(activeModels.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(confidence.label)
                .font(.system(.footnote, weight: .semibold))
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
        .clipShape(RoundedRectangle(cornerRadius: 16))
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
                        .font(.headline)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.headlineDe)
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(w.eventDe)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(w.severity.color.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 16))
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
