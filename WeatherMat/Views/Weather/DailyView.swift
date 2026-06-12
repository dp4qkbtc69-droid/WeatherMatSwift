// DailyView.swift
import SwiftUI

struct DailyView: View {
    @Environment(WeatherViewModel.self) private var vm
    let entries: [DailyEntry]

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
                    allHigh:    allHigh
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
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.11))
        .background(.ultraThinMaterial.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 20))
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
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(dayRange == range ? Color(hex: "#5b3b00") : .white.opacity(0.84))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            dayRange == range
                                ? Color(hex: "#ffd166")
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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEE"
        return f
    }()

    private var dayLabel: String {
        isToday ? "Heute" : Self.dayFormatter.string(from: day.date)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isSelected ? Color(hex: "#ffd166") : Color.white.opacity(0.28))
                .frame(width: 17)

            Text(dayLabel)
                .font(.system(size: 17, weight: isSelected || isToday ? .bold : .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, alignment: .leading)

            Image(systemName: day.condition.sfSymbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 25))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                metricLine(icon: "drop.fill",
                           text: "\(day.precipitationProbability)%",
                           color: day.precipitationProbability > 0 ? Color(hex: "#7dd3fc") : Color.white.opacity(0.58))
                metricLine(icon: "wind",
                           text: "\(day.windMax)",
                           color: windColor)
            }
            .frame(width: 54, alignment: .leading)

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Text("\(day.low)°")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)

                TempBarView(low: day.low, high: day.high,
                            allLow: allLow, allHigh: allHigh)
                    .frame(width: 76, height: 6)

                Text("\(day.high)°")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(isSelected ? Color.black.opacity(0.16) : (isToday ? Color.black.opacity(0.08) : .clear))
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color(hex: "#ffd166"))
                    .frame(width: 4)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isSelected)
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
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 12, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.82)
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
                    colors: [Color(hex: "#5cc8ff"), Color(hex: "#ffd166")],
                    startPoint: .leading, endPoint: .trailing
                ))
                .frame(width: max(4, endX - startX))
                .offset(x: startX)
        }
    }
}
