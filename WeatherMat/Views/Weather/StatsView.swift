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
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))
                    Text(isExpanded ? "Details" : detailsSummary)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(.caption, weight: .semibold))
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
                WeatherDetailsGrid(current: current, selectedDay: selectedDay)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .glassCard()
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


struct WeatherDetailsGrid: View {
    let current: CurrentWeather
    let selectedDay: DailyEntry

    private var isToday: Bool {
        Calendar.current.isDateInToday(selectedDay.date)
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            if isToday {
                StatTileView(icon: "humidity.fill", label: "Luftfeuchtigkeit", value: "\(current.humidity)%")
                StatTileView(icon: "wind", label: "Wind aktuell", value: "\(current.windSpeed) km/h")
                StatTileView(icon: "gauge.medium", label: "Luftdruck", value: "\(current.pressure) hPa")
                StatTileView(icon: "eye.fill", label: "Sichtweite", value: "\(current.visibility) km")
                StatTileView(icon: "cloud.fill", label: "Bewölkung", value: "\(current.cloudCover)%")
                StatTileView(icon: "drop.fill", label: "Niederschlag", value: precipLabel)
                if let airQuality = current.airQuality {
                    StatTileView(icon: "aqi.medium", label: "Luftqualität", value: "AQI \(airQuality.europeanAQI) (\(airQuality.label))")
                    StatTileView(
                        icon: "sparkles",
                        label: "Feinstaub fein",
                        value: String(format: "PM2.5 %.0f µg/m³", airQuality.pm25),
                        infoTitle: "PM2.5",
                        infoText: "Sehr feine Feinstaubpartikel. Sie können tief in die Atemwege gelangen; niedriger ist besser."
                    )
                    StatTileView(
                        icon: "smoke.fill",
                        label: "Feinstaub grob",
                        value: String(format: "PM10 %.0f µg/m³", airQuality.pm10),
                        infoTitle: "PM10",
                        infoText: "Gröbere Feinstaubpartikel, zum Beispiel Staub und Abrieb. Niedriger ist besser."
                    )
                    StatTileView(icon: "circle.hexagongrid.fill", label: "Ozon / NO₂",
                                 value: String(format: "%.0f / %.0f µg/m³", airQuality.ozone, airQuality.nitrogenDioxide))
                }
            }
            StatTileView(icon: "sun.max.fill", label: "UV-Index\(isToday ? "" : " (max)")",
                         value: uvLabel(isToday ? current.uvIndex : selectedDay.uvMax))
            StatTileView(icon: "wind.circle.fill", label: "Windböen max", value: "\(selectedDay.windMax) km/h")
            StatTileView(icon: "drop.halffull", label: "Regenwahrsch.", value: "\(selectedDay.precipitationProbability)%")
            StatTileView(icon: "cloud.rain.fill", label: "Regen gesamt", value: String(format: "%.1f mm", selectedDay.precipitationSum))
            if selectedDay.sunshineDuration > 0 {
                StatTileView(icon: "sun.horizon.fill", label: "Sonnenstunden", value: String(format: "%.1f h", selectedDay.sunshineDuration))
            }
        }
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
    let icon: String
    let label: String
    let value: String
    var infoTitle: String? = nil
    var infoText: String? = nil

    @State private var showInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .foregroundStyle(.white.opacity(0.66))
                    .font(.footnote)
                Text(label)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                if infoText != nil {
                    Spacer(minLength: 4)
                    Button {
                        HapticService.impact(.light)
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle.fill")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(label) erklären")
                }
            }
            Text(value)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
                .accessibilityLabel("\(label): \(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .alert(infoTitle ?? label, isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(infoText ?? "")
        }
    }
}


// MARK: - Netatmo station tile
struct NetatmoStationPanelView: View {
    let observations: [NetatmoObservation]
    let current: CurrentWeather
    let selectedDay: DailyEntry
    @State private var selectedIndex = 0
    @State private var isDetailsExpanded = false

    private var selectedObservation: NetatmoObservation? {
        guard observations.indices.contains(selectedIndex) else { return observations.first }
        return observations[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(Color(hex: "#68d391"))
                Text("Netatmo Station")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text("\(observations.filter(\.isFresh).count)/\(observations.count) frisch")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.56))
            }

            if observations.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(observations.enumerated()), id: \.offset) { index, observation in
                            Button {
                                HapticService.impact(.light)
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedIndex = index
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(observation.isFresh ? Color(hex: "#68d391") : Color(hex: "#f6e05e"))
                                        .frame(width: 6, height: 6)
                                    Text(observation.displayName)
                                        .lineLimit(1)
                                }
                                .font(.system(.caption, weight: .bold))
                                .foregroundStyle(selectedIndex == index ? AppColors.selectionText : .white.opacity(0.82))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(selectedIndex == index ? AppColors.selection : Color.white.opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let observation = selectedObservation {
                NetatmoModuleRowView(observation: observation)
            }

            Button {
                HapticService.impact(.light)
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    isDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(.footnote, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Details")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .rotationEffect(.degrees(isDetailsExpanded ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.09))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            if isDetailsExpanded {
                WeatherDetailsGrid(current: current, selectedDay: selectedDay)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: observations.count) { _, count in
            if selectedIndex >= count { selectedIndex = 0 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCard()
    }
}

struct NetatmoModuleRowView: View {
    let observation: NetatmoObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.footnote)
                    .foregroundStyle(Color(hex: "#68d391"))
                Text(observation.displayName)
                    .font(.system(.caption, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                Spacer()
                Text(observation.ageLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(observation.isFresh ? .white.opacity(0.52) : Color(hex: "#f6e05e").opacity(0.82))
            }
            HStack(spacing: 12) {
                if let temperature = observation.temperature {
                    value(String(format: "%.1f°", temperature), "Temp")
                }
                if let humidity = observation.humidity {
                    value("\(humidity)%", "Feuchte")
                }
                if let pressure = observation.pressure {
                    value(String(format: "%.0f hPa", pressure), "Druck")
                }
                if let co2 = observation.co2 {
                    value("\(co2)", "CO2")
                }
                if let rainRate = observation.rainRate {
                    value(String(format: "%.1f mm/h", rainRate), "Regen")
                }
                if let rainToday = observation.rainToday {
                    value(String(format: "%.1f mm", rainToday), "Heute")
                }
                if let windSpeed = observation.windSpeed {
                    value(String(format: "%.0f km/h", windSpeed), "Wind")
                }
                if let windGust = observation.windGust {
                    value(String(format: "%.0f km/h", windGust), "Böe")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.10))
        .background(.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func value(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(.caption2, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
        }
    }
}
