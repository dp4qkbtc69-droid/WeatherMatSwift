// HeroView.swift
import SwiftUI

struct HeroView: View {
    let current:     CurrentWeather
    let today:       DailyEntry

    var body: some View {
        VStack(spacing: 4) {
            // Weather icon
            Image(systemName: current.condition.sfSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 80, weight: .thin))
                .symbolEffect(.pulse, options: .repeating.speed(0.4))
                .shadow(radius: 8)
                .padding(.bottom, 4)

            // Main temperature
            Text("\(current.temp)°")
                .font(.system(size: 88, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 4)

            // Condition label
            Text(current.condition.label)
                .font(.system(.title3, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))

            // Feels like
            Text("Gefühlt \(current.feelsLike)°")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .padding(.bottom, 4)

            // High / Low / Rain probability
            HStack(spacing: 16) {
                Label("H: \(today.high)°", systemImage: "thermometer.high")
                Label("T: \(today.low)°",  systemImage: "thermometer.low")
                if today.precipitationProbability > 0 {
                    Label("\(today.precipitationProbability)%", systemImage: "drop.fill")
                        .foregroundStyle(Color(hex: "#8fe3ff"))
                }
            }
            .font(.system(.subheadline, weight: .medium))
            .foregroundStyle(.white.opacity(0.75))

            // Sunrise / sunset pills
            SunPillsView(sunrise: today.sunrise, sunset: today.sunset)
                .padding(.top, 8)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sun pills
struct SunPillsView: View {
    let sunrise: Date
    let sunset:  Date

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 20) {
            pill(icon: "sunrise.fill",  text: Self.timeFormatter.string(from: sunrise), color: .yellow)
            pill(icon: "sunset.fill",   text: Self.timeFormatter.string(from: sunset),  color: .orange)
        }
    }

    private func pill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .symbolRenderingMode(.multicolor)
                .font(.subheadline)
            Text(text)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.white.opacity(0.18))
        .background(.ultraThinMaterial.opacity(0.42))
        .clipShape(Capsule())
    }
}
