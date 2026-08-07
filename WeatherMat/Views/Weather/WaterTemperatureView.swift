// WaterTemperatureView.swift
import SwiftUI

/// Compact card for sea surface temperature — only rendered when
/// `CurrentWeather.waterTemperature` is non-nil (coastal locations only).
/// Optionally shows the next tide turning point (`CurrentWeather.tide`) when
/// the location has a meaningful tidal range. Tapping opens a detail sheet
/// with full tide times and heights.
struct WaterTemperatureCardView: View {
    let data: WaterTemperatureData
    var tide: TideData? = nil

    @State private var showDetail = false

    var body: some View {
        Button {
            HapticService.impact(.light)
            showDetail = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "water.waves")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 24))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wassertemperatur")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(data.label)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Int(data.temperature.rounded()))°")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .monospacedDigit()

                    if let next = tide?.next {
                        HStack(spacing: 3) {
                            Image(systemName: next.type == .high ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                .font(.system(size: 11))
                            Text(tideLabel(for: next))
                                .font(.system(.caption2, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.72))
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Öffnet Details zu Wassertemperatur und Tiden")
        .sheet(isPresented: $showDetail) {
            WaterTemperatureDetailSheet(data: data, tide: tide)
                .presentationDetents([.medium, .large])
        }
    }

    private var accessibilityText: String {
        var text = "Wassertemperatur \(Int(data.temperature.rounded())) Grad, \(data.label)"
        if let next = tide?.next {
            let kind = next.type == .high ? "Flut" : "Ebbe"
            text += ", \(kind) um \(Self.timeFormatter.string(from: next.time))"
        }
        return text
    }

    private func tideLabel(for event: TideData.Event) -> String {
        let kind = event.type == .high ? "Flut" : "Ebbe"
        return "\(kind) \(Self.timeFormatter.string(from: event.time))"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Detail sheet
private struct WaterTemperatureDetailSheet: View {
    let data: WaterTemperatureData
    let tide: TideData?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Wassertemperatur") {
                    LabeledContent("Aktuell") {
                        Text("\(Int(data.temperature.rounded()))° · \(data.label)")
                    }
                    LabeledContent("Gemessen um") {
                        Text(Self.timeFormatter.string(from: data.measuredAt))
                    }
                }

                if let tide {
                    Section {
                        LabeledContent("Aktueller Pegel") {
                            Text(Self.heightFormatter.string(fromMeters: tide.currentHeight))
                        }
                        ForEach(tide.nextEvents, id: \.time) { event in
                            HStack {
                                Label(
                                    event.type == .high ? "Flut" : "Ebbe",
                                    systemImage: event.type == .high ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
                                )
                                .foregroundStyle(event.type == .high ? .blue : .orange)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(Self.timeFormatter.string(from: event.time))
                                        .font(.system(.body, weight: .semibold))
                                    Text(Self.heightFormatter.string(fromMeters: event.height))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Tiden")
                    } footer: {
                        Text("Berechnet aus dem Gezeitenverlauf der Open-Meteo Marine API — kann von amtlichen Gezeitentafeln abweichen.")
                    }
                } else {
                    Section {
                        Text("Für diesen Ort liegen keine nennenswerten Gezeiten vor.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Wassertemperatur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "HH:mm"
        return f
    }()
}

private struct MetersFormatter {
    func string(fromMeters value: Double) -> String {
        String(format: "%.2f m", value)
    }
}

private extension WaterTemperatureDetailSheet {
    static let heightFormatter = MetersFormatter()
}
