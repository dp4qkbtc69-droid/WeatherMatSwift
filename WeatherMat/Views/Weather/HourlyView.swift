// HourlyView.swift
import SwiftUI

private let cellWidth: CGFloat = 90

struct HourlyView: View {
    let entries: [HourlyEntry]
    let label:   String
    @State private var hourStep = 1

    private static let steps = [1, 3, 6]

    private var visibleEntries: [HourlyEntry] {
        guard hourStep > 1 else { return entries }
        return entries.enumerated().compactMap { index, entry in
            index == 0 || index % hourStep == 0 ? entry : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center) {
                HStack(spacing: 7) {
                    Image(systemName: "clock.fill")
                        .font(.system(.subheadline, weight: .semibold))
                    Text(label)
                        .font(.system(.callout, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.9))

                Spacer()

                stepPicker
            }
            .padding(.horizontal)

            if entries.isEmpty {
                Text("Keine stündlichen Daten")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                scrollContent
            }
        }
        .padding(.vertical, 12)
        .glassCard()
        .padding(.horizontal)
    }

    private var stepPicker: some View {
        HStack(spacing: 0) {
            ForEach(Self.steps, id: \.self) { step in
                Button {
                    HapticService.impact(.light)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        hourStep = step
                    }
                } label: {
                    Text("\(step) h")
                        .font(.system(.footnote, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(hourStep == step ? Color(hex: "#5b3b00") : .white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(hourStep == step ? Color(hex: "#ffd166") : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.white.opacity(0.14))
        .clipShape(Capsule())
    }

    // MARK: - Scrollable content
    private var scrollContent: some View {
        let visible = visibleEntries
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { i, entry in
                    HourlyCellView(entry: entry, isFirst: i == 0)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Single hourly cell
struct HourlyCellView: View {
    let entry:   HourlyEntry
    let isFirst: Bool

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH'h'"
        return f
    }()

    private var timeString: String {
        isFirst && abs(entry.time.timeIntervalSinceNow) < 30 * 60
            ? "Jetzt"
            : Self.hourFormatter.string(from: entry.time)
    }

    /// Color-coded by Beaufort / km/h bracket
    private var windColor: Color {
        switch entry.windSpeed {
        case 0..<15:  return .white.opacity(0.78)
        case 15..<30: return Color(hex: "#7ecfff")
        case 30..<50: return Color(hex: "#f6e05e")
        case 50..<75: return Color(hex: "#fc814a")
        default:      return Color(hex: "#fc5c5c")
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            // Time
            Text(timeString)
                .font(.system(size: 14, weight: isFirst ? .bold : .semibold))
                .foregroundStyle(isFirst ? .white : .white.opacity(0.86))

            // Weather icon
            Image(systemName: entry.isDay ? entry.condition.sfSymbol : entry.condition.sfSymbolNight)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 26))
                .frame(height: 28)

            // Temperature
            Text("\(entry.temp)°")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()

            VStack(spacing: 4) {
                metricLine(icon: "drop.fill",
                           text: "\(entry.precipitationProbability)%",
                           color: precipColor)
                metricLine(icon: "wind",
                           text: "\(entry.windSpeed) km/h",
                           color: windColor)
            }
        }
        .frame(width: cellWidth)
        .padding(.vertical, 8)
        .background(isFirst ? Color.black.opacity(0.10) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var precipColor: Color {
        entry.precipitationProbability > 0
            ? Color(hex: "#7dd3fc")
            : Color.white.opacity(0.58)
    }

    private func metricLine(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(.caption2, weight: .semibold))
            Text(text)
                .font(.system(.caption, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity)
    }
}
