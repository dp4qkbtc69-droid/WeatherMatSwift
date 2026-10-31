// WeatherWarningLiveActivity.swift
// Lock Screen / Dynamic Island UI for active DWD weather warnings.
import ActivityKit
import WidgetKit
import SwiftUI

struct WeatherWarningLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WeatherWarningActivityAttributes.self) { context in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: context.state.isExtreme ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(context.state.isExtreme ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.headline)
                    Text(context.state.headline)
                        .font(.subheadline)
                    Text(context.attributes.locationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isExtreme ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(context.state.isExtreme ? .red : .orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.locationName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.headline)
                        .font(.headline)
                }
            } compactLeading: {
                Image(systemName: context.state.isExtreme ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(context.state.isExtreme ? .red : .orange)
            } compactTrailing: {
                Text(context.state.title)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}
