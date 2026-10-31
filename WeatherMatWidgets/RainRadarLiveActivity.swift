// RainRadarLiveActivity.swift
// Lock Screen / Dynamic Island UI for the rain-radar countdown Live Activity.
// Content comes entirely from `RainRadarActivityAttributes.ContentState`,
// which `LiveActivityController` (main app) keeps updated — this file has no
// network/service dependencies of its own.
import ActivityKit
import WidgetKit
import SwiftUI

struct RainRadarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RainRadarActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: context.state.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.statusText)
                        .font(.headline)
                    if !context.state.subText.isEmpty {
                        Text(context.state.subText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(context.attributes.locationName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.sfSymbol)
                        .foregroundStyle(.blue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.locationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.statusText)
                            .font(.headline)
                        if !context.state.subText.isEmpty {
                            Text(context.state.subText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
