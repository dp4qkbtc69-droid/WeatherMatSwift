// RainRadarLiveActivity.swift
// Lock Screen / Dynamic Island UI for the rain-radar countdown Live Activity.
// Content comes entirely from `RainRadarActivityAttributes.ContentState`,
// which `LiveActivityController` (main app) keeps updated — this file has no
// network/service dependencies of its own.
import ActivityKit
import WidgetKit
import SwiftUI

/// Combines the status subtext with the estimated-duration hint, e.g.
/// "2.3 mm/h · noch ca. 25 Min." — nil when there's nothing to show.
private func subtitle(for state: RainRadarActivityAttributes.ContentState) -> String? {
    var parts: [String] = []
    if !state.subText.isEmpty { parts.append(state.subText) }
    if let duration = state.estimatedDurationMinutes {
        parts.append(state.minutesUntilRain == 0 ? "noch ca. \(duration) Min." : "ca. \(duration) Min. Dauer")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

struct RainRadarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainRadarActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: context.state.sfSymbol)
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.statusText)
                            .font(.headline)
                        if let subtitle = subtitle(for: context.state) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(context.attributes.locationName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let progress = context.state.progress {
                    ProgressView(value: progress)
                        .tint(.blue)
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.sfSymbol)
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let intensity = context.state.rainIntensity {
                            Text(intensity.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(context.attributes.locationName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.state.statusText)
                            .font(.headline)
                        if let subtitle = subtitle(for: context.state) {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let progress = context.state.progress {
                            ProgressView(value: progress)
                                .tint(.blue)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.sfSymbol)
            } compactTrailing: {
                if let mins = context.state.minutesUntilRain {
                    Text("\(mins)m")
                        .font(.caption2)
                } else {
                    Image(systemName: "checkmark")
                }
            } minimal: {
                Image(systemName: context.state.sfSymbol)
            }
        }
    }
}
