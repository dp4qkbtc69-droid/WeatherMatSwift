// HeroView.swift
import SwiftUI

struct HeroView: View {
    let current:     CurrentWeather
    let today:       DailyEntry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 3) {
            // Weather icon (decorative — condition is spoken via the label below)
            Image(systemName: current.condition.sfSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 68, weight: .thin))
                .symbolEffect(.pulse, options: .repeating.speed(0.4), isActive: !reduceMotion)
                .shadow(radius: 8)
                .padding(.bottom, 2)
                .accessibilityHidden(true)

            // Main temperature
            Text("\(current.temp)°")
                .font(.system(size: 78, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .shadow(radius: 4)
                .accessibilityLabel("\(current.temp) Grad, \(current.condition.label)")

            HStack(spacing: 8) {
                Text(current.condition.label)
                    .font(.system(.title3, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))

                Text("Gefühlt \(current.feelsLike)°")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .shadow(color: .black.opacity(0.22), radius: 2, x: 0, y: 1)

            // High / Low / Rain probability
            HStack(spacing: 16) {
                Label("H: \(today.high)°", systemImage: "thermometer.high")
                Label("T: \(today.low)°",  systemImage: "thermometer.low")
                if today.precipitationProbability > 0 {
                    Label("\(today.precipitationProbability)%", systemImage: "drop.fill")
                        .foregroundStyle(Color(hex: "#8fe3ff"))
                }
            }
            .font(.system(.subheadline, weight: .semibold))
            .foregroundStyle(.white.opacity(0.84))
            .padding(.top, 1)
            .shadow(color: .black.opacity(0.18), radius: 1, x: 0, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Höchstwert \(today.high) Grad, Tiefstwert \(today.low) Grad"
                + (today.precipitationProbability > 0 ? ", \(today.precipitationProbability) Prozent Niederschlag" : "")
            )

            // Sunrise / sunset pills
            SunPillsView(sunrise: today.sunrise, sunset: today.sunset)
                .padding(.top, 5)
        }
        .padding(.vertical, 4)
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
        HStack(spacing: 14) {
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
                .font(.system(.footnote, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.white.opacity(0.18))
        .background(.ultraThinMaterial.opacity(0.42))
        .clipShape(Capsule())
    }
}
