// RegionPackController.swift
// Owns region-pack loading and incremental per-frame image rendering for the
// radar screen. Strictly event-driven: `load` is called from map-region
// settling (already debounced upstream in RadarV2MapView.Coordinator), and
// `ensureRendered` is called whenever the wanted frame window actually
// changes (timeline selection, playback advance, or a freshly loaded pack) —
// never from a polling timer. Already-rendered images are cached and reused
// across calls so scrubbing/playback never re-renders a frame twice, and no
// task of any kind keeps running once a call has nothing left to do.
import CoreGraphics
import Foundation
import MapKit
import Observation

struct RegionPackRequest: Sendable {
    let center: CLLocationCoordinate2D
    let kilometers: Double

    func isClose(to nextCenter: CLLocationCoordinate2D, kilometers nextKilometers: Double) -> Bool {
        abs(center.latitude - nextCenter.latitude) < 0.08 &&
        abs(center.longitude - nextCenter.longitude) < 0.08 &&
        abs(kilometers - nextKilometers) < 20
    }
}

@MainActor
@Observable
final class RegionPackController {
    /// How many frames around the requested window are kept warm when the
    /// caller has no explicit window yet (e.g. the pack arrived before the
    /// timeline did).
    static let fallbackWindowFrameCount = 17

    private(set) var pack: RadarRegionPack?
    private(set) var renderSet: RadarRegionRenderSet?
    private(set) var isLoading = false
    private(set) var lastRequest: RegionPackRequest?
    /// Time span actually spanned by the loaded pack's frames (not the
    /// requested start/end — the server may clamp or have gaps). Used by
    /// `covers(windowStart:windowEnd:)` to decide whether the caller needs a
    /// fresh `load()` instead of just a render.
    private(set) var loadedWindowStart: Date?
    private(set) var loadedWindowEnd: Date?

    private var framesByID: [String: RadarRegionPack.Frame] = [:]
    private var images: [String: CGImage] = [:]
    private var loadTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private let regionPackService: RegionPackServiceProtocol

    init(regionPackService: RegionPackServiceProtocol = RegionPackService.shared) {
        self.regionPackService = regionPackService
    }

    /// `startTime`/`endTime` scope the pack to the actively visible timeline
    /// window (see `RainRadarScreen.desiredTimeWindow()`); leave both `nil`
    /// to let the server apply its own default window around "now".
    func load(
        center: CLLocationCoordinate2D,
        kilometers: Double,
        keepsExistingOverlay: Bool,
        startTime: Date? = nil,
        endTime: Date? = nil
    ) {
        loadTask?.cancel()
        renderTask?.cancel()
        if !keepsExistingOverlay {
            pack = nil
            renderSet = nil
            images = [:]
            framesByID = [:]
        }
        let kilometers = min(400, max(40, kilometers))
        lastRequest = RegionPackRequest(center: center, kilometers: kilometers)
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched = try await self.regionPackService.fetchRegionPack(
                    latitude: center.latitude, longitude: center.longitude, km: kilometers,
                    startTime: startTime, endTime: endTime
                )
                guard !Task.isCancelled else { return }
                self.pack = fetched
                self.framesByID = Dictionary(uniqueKeysWithValues: fetched.frames.map { ($0.id, $0) })
                let times = fetched.frames.map(\.time)
                self.loadedWindowStart = times.min()
                self.loadedWindowEnd = times.max()
                // A new pack means new frame identities — any images carried
                // over from a previous pack no longer apply.
                self.images = [:]
            } catch {
                guard !Task.isCancelled else { return }
                if !keepsExistingOverlay {
                    self.renderSet = nil
                    self.loadedWindowStart = nil
                    self.loadedWindowEnd = nil
                }
                self.isLoading = false
                self.lastRequest = nil
            }
        }
    }

    /// Renders exactly the frames the caller currently wants (closest first),
    /// reusing cached images for anything already rendered and dropping
    /// images that fell outside the window. Call this whenever the wanted
    /// window changes; it does one bounded pass and then stops — it never
    /// re-checks on its own.
    func ensureRendered(orderedRegionFrameIDs: [String], readinessFrameIDs: [String: String]) {
        guard let pack else { return }
        renderTask?.cancel()

        var frames: [RadarRegionPack.Frame] = []
        var seen = Set<String>()
        for id in orderedRegionFrameIDs where seen.insert(id).inserted {
            if let frame = framesByID[id] {
                frames.append(frame)
            }
        }
        if frames.isEmpty {
            frames = Array(pack.frames.prefix(Self.fallbackWindowFrameCount))
        }

        let wantedIDs = Set(frames.map(\.id))
        let previousCount = images.count
        images = images.filter { wantedIDs.contains($0.key) }
        if images.count != previousCount {
            publish(pack: pack)
        }

        let missing = frames.filter { images[$0.id] == nil }
        guard !missing.isEmpty else {
            isLoading = false
            return
        }

        renderTask = Task { [weak self] in
            guard let self else { return }
            for frame in missing {
                guard !Task.isCancelled else { return }
                guard let rendered = await RadarRegionImageRenderer.renderFrame(frame, pack: pack) else { continue }
                guard !Task.isCancelled else { return }
                self.images[rendered.frameID] = rendered.image
                self.publish(pack: pack)
                self.isLoading = false
                if let readinessFrameID = readinessFrameIDs[rendered.frameID] {
                    await RadarTileReadinessCenter.shared.markReady(readinessFrameID)
                }
            }
        }
    }

    /// True when the loaded pack's own time span encompasses the wanted
    /// window. Checking the span (not per-frame-id presence) means a single
    /// missing frame inside an otherwise-covered range — a normal data gap —
    /// is just a render gap, not a reason to refetch forever; only a
    /// selection that moved outside the span triggers a reload.
    func covers(windowStart: Date, windowEnd: Date) -> Bool {
        guard let loadedWindowStart, let loadedWindowEnd else { return false }
        return loadedWindowStart <= windowStart && loadedWindowEnd >= windowEnd
    }

    /// Stops every in-flight task. Called when the radar screen disappears
    /// so nothing keeps running once it's not visible.
    func cancelAll() {
        loadTask?.cancel()
        renderTask?.cancel()
    }

    private func publish(pack: RadarRegionPack) {
        renderSet = RadarRegionRenderSet(pack: pack, images: images)
    }
}
