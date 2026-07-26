// DailyView.swift
import SwiftUI

struct DailyView: View {
    @Environment(WeatherViewModel.self) private var vm
    let entries: [DailyEntry]
    var confidenceBands: [ForecastConfidenceBand] = []

    @State private var dayRange = 3   // default: 3-day view

    private static let ranges = [3, 7, 14]

    private var visibleEntries: [DailyEntry] {
        Array(entries.prefix(dayRange))
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab picker ───────────────────────────────────────────────
            rangePicker
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            Divider().background(.white.opacity(0.16))

            // ── Rows ─────────────────────────────────────────────────────
            let allLow  = visibleEntries.map(\.low).min()  ?? 0
            let allHigh = visibleEntries.map(\.high).max() ?? 1
            ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { i, day in
                DailyRowView(
                    day:        day,
                    index:      i,
                    isSelected: vm.selectedDayIndex == i,
                    isToday:    i == 0,
                    allLow:     allLow,
                    allHigh:    allHigh,
                    confidence: confidence(for: i)
                )
                .onTapGesture {
                    HapticService.impact(.light)
                    vm.selectDay(i)
                }

                if i < visibleEntries.count - 1 {
                    Divider()
                        .background(.white.opacity(0.08))
                        .padding(.horizontal, 16)
                }
            }
        }
        .glassCard()
    }

    private func confidence(for index: Int) -> ConfidenceLevel? {
        let id: String
        switch index {
        case 0: id = "0-24h"
        case 1...3: id = "1-3d"
        default: id = "3-10d"
        }
        return confidenceBands.first { $0.id == id }?.confidence
    }

    // MARK: - Range picker
    private var rangePicker: some View {
        HStack(spacing: 0) {
            ForEach(Self.ranges, id: \.self) { range in
                let available = min(range, entries.count)
                Button {
                    HapticService.impact(.light)
                    withAnimation(.easeInOut(duration: 0.18)) {
                        dayRange = range
                        // Deselect if currently selected day is now out of range
                        if let sel = vm.selectedDayIndex, sel >= available {
                            vm.selectDay(sel)   // toggles off
                        }
                    }
                } label: {
                    Text("\(available) Tage")
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(dayRange == range ? AppColors.selectionText : .white.opacity(0.84))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            dayRange == range
                                ? AppColors.selection
                                : Color.clear
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - Single daily row
struct DailyRowView: View {
    let day:        DailyEntry
    let index:      Int
    let isSelected: Bool
    let isToday:    Bool
    let allLow:     Int
    let allHigh:    Int
    let confidence: ConfidenceLevel?

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM."
        return f
    }()

    private var dayLabel: String {
        isToday ? "Heute" : Self.dayFormatter.string(from: day.date)
    }

    private var dateLabel: String {
        Self.dateFormatter.string(from: day.date)
    }

    /// Beyond ~3 days out, models disagree enough that a single-degree number
    /// overstates how well this is actually known. Below that threshold, or
    /// when the models happen to agree closely, the plain point value stays.
    private var showsRange: Bool {
        confidence == .low && (day.highMax - day.highMin >= 2 || day.lowMax - day.lowMin >= 2)
    }

    private var highText: String {
        showsRange ? "\(day.highMin)–\(day.highMax)°" : "\(day.high)°"
    }

    private var lowText: String {
        showsRange ? "\(day.lowMin)–\(day.lowMax)°" : "\(day.low)°"
    }

    private var confidenceAccessibilityHint: String? {
        confidence == .low ? "Prognose für diesen Tag noch unsicher" : nil
    }

    private var dailyAccessibilityLabel: String {
        var label = "\(dayLabel) \(dateLabel), \(day.condition.label), "
        label += "Höchstwert \(day.high) Grad, Tiefstwert \(day.low) Grad, "
        label += "\(day.precipitationProbability) Prozent Niederschlag, Wind bis \(day.windMax) km/h"
        if let hint = confidenceAccessibilityHint {
            label += ", \(hint)"
        }
        return label
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(isSelected ? AppColors.selection : Color.white.opacity(0.28))
                .frame(width: 17)

            VStack(alignment: .leading, spacing: 1) {
                Text(dayLabel)
                    .font(.system(size: 16, weight: isSelected || isToday ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(dateLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 52, alignment: .leading)

            ZStack(alignment: .bottomTrailing) {
                Image(systemName: day.condition.sfSymbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.title)
                    .frame(width: 32)
                if let confidence {
                    Circle()
                        .fill(confidence.color)
                        .frame(width: 7, height: 7)
                        .shadow(color: confidence.color.opacity(0.5), radius: 2)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                metricLine(icon: "drop.fill",
                           text: "\(day.precipitationProbability)%",
                           color: day.precipitationProbability > 0 ? Color(hex: "#7dd3fc") : Color.white.opacity(0.58))
                metricLine(icon: "wind",
                           text: "\(day.windMax)",
                           color: windColor)
            }
            .frame(width: 58, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(lowText)
                    .font(.system(.callout, weight: showsRange ? .medium : .semibold))
                    .foregroundStyle(.white.opacity(showsRange ? 0.6 : 0.76))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: showsRange ? 44 : 30, alignment: .trailing)

                TempBarView(low: day.low, high: day.high,
                            allLow: allLow, allHigh: allHigh)
                    .frame(width: 60, height: 6)

                Text(highText)
                    .font(.system(.headline, weight: showsRange ? .semibold : .bold))
                    .foregroundStyle(.white.opacity(showsRange ? 0.82 : 1))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: showsRange ? 44 : 30, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isSelected ? Color.black.opacity(0.16) : (isToday ? Color.black.opacity(0.08) : .clear))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(AppColors.selection)
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dailyAccessibilityLabel)
        .accessibilityValue(isSelected ? "ausgewählt" : "")
        .accessibilityHint("Tippen für Stundenansicht dieses Tages")
    }

    private var windColor: Color {
        switch day.windMax {
        case 0..<15:  return Color.white.opacity(0.7)
        case 15..<30: return Color(hex: "#7dd3fc")
        case 30..<50: return Color(hex: "#f6e05e")
        case 50..<75: return Color(hex: "#fc814a")
        default:      return Color(hex: "#fc5c5c")
        }
    }

    private func metricLine(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(.caption2, weight: .semibold))
            Text(text)
                .font(.system(.caption, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(color)
    }
}

// MARK: - Temperature range bar
struct TempBarView: View {
    let low, high, allLow, allHigh: Int

    var body: some View {
        GeometryReader { geo in
            let range  = Double(max(1, allHigh - allLow))
            let startX = Double(low  - allLow) / range * geo.size.width
            let endX   = Double(high - allLow) / range * geo.size.width
            Capsule()
                .fill(.white.opacity(0.15))
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(hex: "#5cc8ff"), AppColors.selection],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: max(4, endX - startX))
                .offset(x: startX)
        }
    }
}
