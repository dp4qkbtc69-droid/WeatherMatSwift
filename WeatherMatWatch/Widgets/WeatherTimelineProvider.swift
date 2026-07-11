// WeatherTimelineProvider.swift
import WidgetKit

struct WeatherEntry: TimelineEntry {
    let date:     Date
    let snapshot: WatchWeatherSnapshot?
}

/// Bridges the non-Sendable completion handler required by `TimelineProvider`
/// into an unstructured `Task` — a plain closure capture there fails Swift 6's
/// sending-parameter check, but a boxed reference type is fine to transfer.
private final class CompletionBox<Value>: @unchecked Sendable {
    let call: (Value) -> Void
    init(_ call: @escaping (Value) -> Void) { self.call = call }
}

struct WeatherTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WeatherEntry {
        WeatherEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WeatherEntry) -> Void) {
        completion(WeatherEntry(date: Date(), snapshot: currentSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeatherEntry>) -> Void) {
        let box = CompletionBox(completion)
        Task {
            if let locationID = activeLocationID,
               let location = WatchSharedStore.locations.first(where: { $0.id == locationID }),
               let fresh = try? await WeatherKitFetcher.fetchSnapshot(for: location) {
                WatchSharedStore.saveSnapshot(fresh, for: locationID)
            }
            let entry = WeatherEntry(date: Date(), snapshot: currentSnapshot())
            let refreshDate = Date().addingTimeInterval(30 * 60)
            box.call(Timeline(entries: [entry], policy: .after(refreshDate)))
        }
    }

    /// The GPS entry's lat/lon is kept current by the watch app each time it
    /// gets a fix — the widget extension reads it rather than requesting its
    /// own location fix (unreliable within a widget's short execution budget).
    private var activeLocationID: String? {
        WatchSharedStore.selectedLocationID ?? WatchSharedStore.locations.first?.id
    }

    private func currentSnapshot() -> WatchWeatherSnapshot? {
        guard let id = activeLocationID else { return nil }
        return WatchSharedStore.snapshot(for: id)
    }
}
