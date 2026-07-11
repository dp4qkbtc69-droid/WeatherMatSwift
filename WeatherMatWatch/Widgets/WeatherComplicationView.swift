// WeatherComplicationView.swift
import SwiftUI
import WidgetKit

struct WeatherComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WeatherEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:   circular
            case .accessoryRectangular: rectangular
            case .accessoryInline:     inline
            case .accessoryCorner:     corner
            default:                  rectangular
            }
        }
        // Required since watchOS 10 — without it the system shows a generic
        // "!" placeholder instead of the custom view, for every family.
        .containerBackground(.clear, for: .widget)
    }

    private var circular: some View {
        VStack(spacing: 2) {
            Image(systemName: entry.snapshot?.sfSymbol ?? "cloud.fill")
                .font(.title3)
            Text(entry.snapshot.map { "\($0.currentTemp)°" } ?? "–")
                .font(.headline)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: entry.snapshot?.sfSymbol ?? "cloud.fill")
                Text(entry.snapshot.map { "\($0.currentTemp)°" } ?? "–")
                    .font(.headline)
                Spacer()
                Text(entry.snapshot.map { "↑\($0.highTemp)° ↓\($0.lowTemp)°" } ?? "")
                    .font(.caption2)
            }
            Text(entry.snapshot?.rainSummary ?? "Keine Daten")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var inline: some View {
        Label(
            entry.snapshot.map { "\($0.currentTemp)° · \($0.rainSummary)" } ?? "WeatherMat",
            systemImage: entry.snapshot?.sfSymbol ?? "cloud.fill"
        )
    }

    private var corner: some View {
        Text(entry.snapshot.map { "\($0.currentTemp)°" } ?? "–")
            .font(.title2)
            .widgetLabel {
                Text(entry.snapshot?.rainSummary ?? "")
            }
    }
}

struct WeatherComplication: Widget {
    let kind = "WeatherMatComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeatherTimelineProvider()) { entry in
            WeatherComplicationView(entry: entry)
        }
        .configurationDisplayName("WeatherMat")
        .description("Aktuelle Temperatur, Tages-Min/Max und Regenvorhersage.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
