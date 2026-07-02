// RadarV2Store.swift
import Foundation
import Observation

@MainActor
@Observable
final class RadarV2Store {
    var timeline: RainRadarTimeline?
    var selectedIndex = 0
    var isPlaying = false
    var isLoading = false
    var errorMessage: String?
    private var cachedVisibleFrames: [RainRadarFrame] = []

    var visibleFrames: [RainRadarFrame] {
        cachedVisibleFrames
    }

    var selectedFrame: RainRadarFrame? {
        guard !visibleFrames.isEmpty else { return nil }
        return visibleFrames[min(selectedIndex, visibleFrames.count - 1)]
    }

    var renderRequest: RadarV2RenderRequest? {
        guard let timeline, let selectedFrame else { return nil }
        return RadarV2RenderRequest(
            host: timeline.host,
            source: timeline.source,
            tileMaxZoom: timeline.tileMaxZoom ?? 8,
            frame: selectedFrame,
            neighborFrames: prewarmFrames(around: selectedFrame)
        )
    }

    var selectedTimeLabel: String {
        guard let selectedFrame else { return "--:--" }
        return selectedFrame.time.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
    }

    var selectedDateLabel: String {
        guard let selectedFrame else { return "--" }
        return selectedFrame.time.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(.init(identifier: "de_DE")))
    }

    var selectedDateTimeLabel: String {
        guard let selectedFrame else {
            return Date().formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute().locale(.init(identifier: "de_DE")))
        }
        return selectedFrame.time.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute().locale(.init(identifier: "de_DE")))
    }

    var selectedFrameKindLabel: String {
        guard let selectedFrame else { return "Radar" }
        if selectedFrame.precipitationType == .snow {
            return "Schnee"
        }
        switch selectedFrame.sourceKind {
        case .iconEuRaw, .iconEu:
            return "ICON-EU"
        case .dwdRadar, .rainViewer, .unknown:
            return selectedFrame.isForecast ? "Prognose" : "Radar"
        }
    }

    var isAtEnd: Bool {
        selectedIndex >= max(visibleFrames.count - 1, 0)
    }

    var nextPlaybackFrame: RainRadarFrame? {
        guard !visibleFrames.isEmpty else { return nil }
        let nextIndex = isAtEnd ? 0 : selectedIndex + 1
        return visibleFrames[min(nextIndex, visibleFrames.count - 1)]
    }

    var nextPlaybackDelayNanoseconds: UInt64 {
        guard !isAtEnd,
              visibleFrames.indices.contains(selectedIndex),
              visibleFrames.indices.contains(selectedIndex + 1) else {
            return 950_000_000
        }
        return Self.playbackDelayNanoseconds(
            current: visibleFrames[selectedIndex],
            next: visibleFrames[selectedIndex + 1]
        )
    }

    func load() async {
        guard timeline == nil else { return }
        if let cached = RainRadarService.loadCachedTimeline() {
            apply(cached, preservingSelection: false)
            Task { await refreshAndExtend(over: cached) }
            return
        }

        if let preloaded = RainRadarService.preloadedTimeline {
            apply(preloaded, preservingSelection: false)
            Task { await refreshAndExtend(over: preloaded) }
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await RainRadarService.fetchTimeline()
            RainRadarService.preloadedTimeline = loaded
            RainRadarService.saveTimelineCache(loaded)
            apply(loaded, preservingSelection: false)
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = "Radar konnte nicht geladen werden."
        }
    }

    func retry() async {
        timeline = nil
        cachedVisibleFrames = []
        errorMessage = nil
        selectedIndex = 0
        await load()
    }

    func advance() {
        guard !visibleFrames.isEmpty else { return }
        selectedIndex = isAtEnd ? 0 : selectedIndex + 1
    }

    private func refreshAndExtend(over prior: RainRadarTimeline) async {
        guard let fresh = try? await RainRadarService.fetchTimeline() else { return }
        RainRadarService.preloadedTimeline = fresh
        RainRadarService.saveTimelineCache(fresh)
        apply(fresh, preservingSelection: true)
    }

    private func apply(_ next: RainRadarTimeline, preservingSelection: Bool) {
        let selectedTime = preservingSelection ? selectedFrame?.time : nil
        timeline = next
        cachedVisibleFrames = Self.visibleFrames(in: next)
        let frames = visibleFrames
        if let selectedTime,
           let nearest = frames.indices.min(by: {
               abs(frames[$0].time.timeIntervalSince(selectedTime)) < abs(frames[$1].time.timeIntervalSince(selectedTime))
           }) {
            selectedIndex = nearest
        } else if let latest = next.latestObservedFrame,
                  let index = frames.firstIndex(of: latest) {
            selectedIndex = index
        } else {
            selectedIndex = min(selectedIndex, max(frames.count - 1, 0))
        }
    }

    private func prewarmFrames(around frame: RainRadarFrame) -> [RainRadarFrame] {
        guard let index = visibleFrames.firstIndex(of: frame) else { return [] }
        return [-4, -3, -2, -1, 1, 2, 3, 4, 5, 6]
            .compactMap { offset -> RainRadarFrame? in
                let nextIndex = index + offset
                return visibleFrames.indices.contains(nextIndex) ? visibleFrames[nextIndex] : nil
            }
    }

    // Keeps 24 h of history before the newest observation and up to 120 h of
    // forecast after it; anything outside is dropped from the scrubber.
    nonisolated static func visibleFrames(in timeline: RainRadarTimeline) -> [RainRadarFrame] {
        let frames = timeline.frames
        guard !frames.isEmpty else { return [] }
        guard let latest = timeline.latestObservedFrame else { return frames }
        let lower = latest.time.addingTimeInterval(-24 * 3600)
        let upper = latest.time.addingTimeInterval(120 * 3600)
        return frames.filter { $0.time >= lower && $0.time <= upper }
    }

    nonisolated static func playbackDelayNanoseconds(current: RainRadarFrame, next: RainRadarFrame) -> UInt64 {
        if current.sourceKind != next.sourceKind {
            return 760_000_000
        }
        let minutes = max(1, next.time.timeIntervalSince(current.time) / 60)
        let seconds = min(0.78, max(0.34, 0.30 + minutes / 120.0))
        return UInt64(seconds * 1_000_000_000)
    }
}
