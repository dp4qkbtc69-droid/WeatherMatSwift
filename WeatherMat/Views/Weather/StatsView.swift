// StatsView.swift
import SwiftUI

struct StatsView: View {
    let current:     CurrentWeather
    let selectedDay: DailyEntry
    @State private var isExpanded = false

    /// True when the selected day is today (use live current values).
    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay.date)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — always visible, tap to expand/collapse
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
                HapticService.impact(.light)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.72))
                    Text(isExpanded ? "Details" : detailsSummary)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .buttonStyle(.plain)

            // Expandable grid
            if isExpanded {
                Divider().background(.white.opacity(0.1))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    if isToday {
                        // Live readings — only meaningful for the current moment
                        StatTileView(icon: "humidity.fill",    label: "Luftfeuchtigkeit", value: "\(current.humidity)%")
                        StatTileView(icon: "wind",             label: "Wind aktuell",     value: "\(current.windSpeed) km/h")
                        StatTileView(icon: "gauge.medium",     label: "Luftdruck",        value: "\(current.pressure) hPa")
                        StatTileView(icon: "eye.fill",         label: "Sichtweite",       value: "\(current.visibility) km")
                        StatTileView(icon: "cloud.fill",       label: "Bewölkung",        value: "\(current.cloudCover)%")
                        StatTileView(icon: "drop.fill",        label: "Niederschlag",     value: precipLabel)
                        if let airQuality = current.airQuality {
                            StatTileView(icon: "aqi.medium",    label: "Luftqualität",     value: "AQI \(airQuality.europeanAQI) (\(airQuality.label))")
                            StatTileView(icon: "sparkles",      label: "Feinstaub",        value: String(format: "PM2.5 %.0f µg/m³", airQuality.pm25))
                            StatTileView(icon: "smoke.fill",    label: "PM10",             value: String(format: "%.0f µg/m³", airQuality.pm10))
                            StatTileView(icon: "circle.hexagongrid.fill", label: "Ozon / NO₂",
                                         value: String(format: "%.0f / %.0f µg/m³", airQuality.ozone, airQuality.nitrogenDioxide))
                        }
                    }
                    // Daily values — always shown (today: forecast max; other days: forecast)
                    StatTileView(icon: "sun.max.fill",         label: "UV-Index\(isToday ? "" : " (max)")",
                                 value: uvLabel(isToday ? current.uvIndex : selectedDay.uvMax))
                    StatTileView(icon: "wind.circle.fill",     label: "Windböen max",     value: "\(selectedDay.windMax) km/h")
                    StatTileView(icon: "drop.halffull",        label: "Regenwahrsch.",    value: "\(selectedDay.precipitationProbability)%")
                    StatTileView(icon: "cloud.rain.fill",      label: "Regen gesamt",     value: String(format: "%.1f mm", selectedDay.precipitationSum))
                    if selectedDay.sunshineDuration > 0 {
                        StatTileView(icon: "sun.horizon.fill", label: "Sonnenstunden",    value: String(format: "%.1f h", selectedDay.sunshineDuration))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.11))
        .background(.ultraThinMaterial.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    // One-line summary shown when collapsed
    private var detailsSummary: String {
        var parts: [String] = ["Details"]
        if selectedDay.sunshineDuration > 0 {
            parts.append(String(format: "☀️ %.0fh", selectedDay.sunshineDuration))
        }
        if isToday {
            parts.append("\(current.humidity)% Feuchte")
            if let airQuality = current.airQuality {
                parts.append("AQI \(airQuality.europeanAQI)")
            }
        } else {
            parts.append("\(selectedDay.precipitationProbability)% Regen")
        }
        return parts.joined(separator: " · ")
    }

    private func uvLabel(_ v: Double) -> String {
        let i = Int(v)
        switch i {
        case 0...2:  return "\(i) (Niedrig)"
        case 3...5:  return "\(i) (Mäßig)"
        case 6...7:  return "\(i) (Hoch)"
        case 8...10: return "\(i) (Sehr hoch)"
        default:     return "\(i) (Extrem)"
        }
    }

    private var precipLabel: String {
        let mm = current.precipitation
        if mm < 0.01 { return "0 mm/h" }
        return String(format: "%.1f mm/h", mm)
    }
}

// MARK: - Single stat tile
struct StatTileView: View {
    let icon:  String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.66))
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
