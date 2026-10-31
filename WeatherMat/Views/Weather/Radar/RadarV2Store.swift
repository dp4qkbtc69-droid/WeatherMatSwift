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
    /// True while playback is holding for an unready frame — the timeline
    /// shows a subtle readiness indicator instead of jumping to empty tiles.
    var isBuffering = false
    var errorMessage: String?
    private var cachedVisibleFrames: [RainRadarFrame] = []
    /// Region-pack frame id -> timeline frame id, for signaling
    /// `RadarTileReadinessCenter` once a region image finishes rendering.
    /// Rebuilt only here, when the timeline itself actually changes — not on
    /// every render-window recomputation (which used to happen on a 220 ms
    /// timer regardless of whether anything changed).
    private(set) var regionFrameIDToTimelineFrameID: [String: String] = [:]

    // `var`, not `let`: mutating `preloadedTimeline` through an existential
    // protocol value requires the holder itself to be mutable, even though
    // the production conformer (a class) only ever mutates its own state.
    private var rainRadarService: RainRadarServiceProtocol

    init(rainRadarService: RainRadarServiceProtocol = RainRadarService.shared) {
        self.rainRadarService = rainRadarService
    }

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
            // The DWD timeline response always sets this (currently up to
            // 14 — see RadarProxy's TILE_MAX_ZOOM); this default only
            // matters for the near-impossible case of a malformed response.
            tileMaxZoom: timeline.tileMaxZoom ?? 14,
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

    // User-facing wording distinguishes observations, radar nowcast, and
    // model frames because their reliability differs visibly.
    /// Compact "when" for the persistent time anchor shown while the chrome
    /// is auto-hidden during playback, e.g. "Heute 14:00", "Morgen 09:00",
    /// "Sa. 14:00".
    var compactWhenLabel: String {
        guard let selectedFrame else { return "--:--" }
        let time = selectedFrame.time.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
        let calendar = Calendar.current
        if calendar.isDateInToday(selectedFrame.time) { return "Heute \(time)" }
        if calendar.isDateInTomorrow(selectedFrame.time) { return "Morgen \(time)" }
        let day = selectedFrame.time.formatted(.dateTime.weekday(.abbreviated).locale(.init(identifier: "de_DE")))
        return "\(day) \(time)"
    }

    var selectedFrameKindLabel: String {
        guard let selectedFrame else { return "Radar" }
        if selectedFrame.precipitationType == .snow {
            return "Schnee"
        }
        if selectedFrame.sourceKind == .iconEuRaw {
            return "Modell"
        }
        if selectedFrame.sourceKind == .dwdRadar, selectedFrame.isForecast {
            return "Nowcast"
        }
        return selectedFrame.isForecast ? "Vorhersage" : "Radar"
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
        if let cached = rainRadarService.loadCachedTimeline() {
            apply(cached, preservingSelection: false)
            Task { await refreshAndExtend(over: cached) }
            return
        }

        if let preloaded = rainRadarService.preloadedTimeline {
            apply(preloaded, preservingSelection: false)
            Task { await refreshAndExtend(over: preloaded) }
            return
        }

        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await rainRadarService.fetchTimeline()
            rainRadarService.preloadedTimeline = loaded
            rainRadarService.saveTimelineCache(loaded)
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
        guard let fresh = try? await rainRadarService.fetchTimeline() else { return }
        rainRadarService.preloadedTimeline = fresh
        rainRadarService.saveTimelineCache(fresh)
        apply(fresh, preservingSelection: true)
    }

    private func apply(_ next: RainRadarTimeline, preservingSelection: Bool) {
        let selectedTime = preservingSelection ? selectedFrame?.time : nil
        timeline = next
        cachedVisibleFrames = Self.visibleFrames(in: next)
        var readinessLookup: [String: String] = [:]
        readinessLookup.reserveCapacity(cachedVisibleFrames.count)
        for frame in cachedVisibleFrames {
            readinessLookup[RegionPackService.regionFrameID(from: frame)] = frame.id
        }
        regionFrameIDToTimelineFrameID = readinessLookup
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
        // Forward-biased order: the immediate next playback frames are prefetched
        // first so playback never advances onto an unwarmed frame, then a few
        // backward frames for scrubbing.
        return [1, 2, 3, 4, 5, 6, -1, -2, -3, -4]
            .compactMap { offset -> RainRadarFrame? in
                let nextIndex = index + offset
                return visibleFrames.indices.contains(nextIndex) ? visibleFrames[nextIndex] : nil
            }
    }

    /// Ordered list of frames to keep rendered for the region-pack overlay:
    /// the current selection first, then alternating forward/backward
    /// neighbors out to `radius` (closest first). Used by `RegionPackController`
    /// to decide which pre-rendered images to keep warm whenever the
    /// selection changes — a different radius/ordering than `prewarmFrames`,
    /// which is about tile prefetching for playback, not region-pack images.
    func regionRenderWindow(radius: Int) -> [RainRadarFrame] {
        guard !visibleFrames.isEmpty else {
            return selectedFrame.map { [$0] } ?? []
        }
        var ordered: [RainRadarFrame] = []
        if let selectedFrame { ordered.append(selectedFrame) }
        let start = min(selectedIndex, visibleFrames.count - 1)
        for offset in 1...radius {
            let forwardIndex = start + offset
            if visibleFrames.indices.contains(forwardIndex) {
                ordered.append(visibleFrames[forwardIndex])
            }
            let backwardIndex = start - offset
            if visibleFrames.indices.contains(backwardIndex) {
                ordered.append(visibleFrames[backwardIndex])
            }
        }
        return ordered
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
