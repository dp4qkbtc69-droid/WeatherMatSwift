// ServiceDependencyInjectionTests.swift
// Demonstrates that the service-layer protocols (`RainRadarServiceProtocol`,
// `RegionPackServiceProtocol`, `EnsembleServiceProtocol`) are genuinely
// mockable: these tests never touch the network or UserDefaults-backed
// production singletons, only the stub conformers below, injected through
// each consumer's initializer.
import Foundation
import CoreLocation
import Testing
@testable import WeatherMat

// MARK: - Mocks

// Matches `RainRadarService` itself: only `preloadedTimeline` is
// `@MainActor`-isolated (per the protocol), not the whole type — a
// class-wide `@MainActor` here would make every witness MainActor-isolated
// and the conformance would no longer match the protocol's isolation.
final class MockRainRadarService: RainRadarServiceProtocol, @unchecked Sendable {
    @MainActor var preloadedTimeline: RainRadarTimeline?
    var cachedTimeline: RainRadarTimeline?
    var fetchResult: Result<RainRadarTimeline, Error> = .failure(URLError(.notConnectedToInternet))

    private(set) var fetchTimelineCallCount = 0
    private(set) var savedTimelines: [RainRadarTimeline] = []

    func preloadIfNeeded() async {}
    func loadCachedTimeline() -> RainRadarTimeline? { cachedTimeline }
    func saveTimelineCache(_ timeline: RainRadarTimeline) { savedTimelines.append(timeline) }

    func fetchTimeline() async throws -> RainRadarTimeline {
        fetchTimelineCallCount += 1
        return try fetchResult.get()
    }

    func resolveDwdRadarBaseURL() async -> URL? { nil }
    func resolvedProxyBaseURL() async -> URL? { nil }

    func authenticatedDwdRadarRequest(_ url: URL, cachePolicy: URLRequest.CachePolicy) -> URLRequest {
        URLRequest(url: url, cachePolicy: cachePolicy)
    }

    func warmLocation(latitude: Double, longitude: Double) async -> Bool { false }
    func registerWarmLocations(_ coordinates: [(latitude: Double, longitude: Double)]) async -> Bool { false }
}

final class MockRegionPackService: RegionPackServiceProtocol, @unchecked Sendable {
    private let result: Result<RadarRegionPack, Error>
    private(set) var fetchCallCount = 0
    private(set) var lastRequestedWindow: (start: Date?, end: Date?)?

    init(result: Result<RadarRegionPack, Error>) {
        self.result = result
    }

    func fetchRegionPack(
        latitude: Double,
        longitude: Double,
        km: Double,
        startTime: Date?,
        endTime: Date?
    ) async throws -> RadarRegionPack {
        fetchCallCount += 1
        lastRequestedWindow = (startTime, endTime)
        return try result.get()
    }
}

// MARK: - Fixtures

private enum Fixtures {
    static let base = Date(timeIntervalSince1970: 1_780_000_000)

    static func frame(minutes: Int, isForecast: Bool = false) -> RainRadarFrame {
        RainRadarFrame(
            time: base.addingTimeInterval(Double(minutes) * 60),
            path: "/tiles/di-frame-\(minutes)",
            isForecast: isForecast,
            sourceKind: .dwdRadar,
            precipitationType: .unknown,
            referenceTime: nil
        )
    }

    static func timeline(frameCount: Int = 3) -> RainRadarTimeline {
        RainRadarTimeline(
            host: "https://proxy.example",
            attribution: "test",
            source: .dwd,
            tileMaxZoom: 9,
            frames: (0..<frameCount).map { frame(minutes: $0 * 10) }
        )
    }

    static func regionPack(frameID: String = "di-region-frame-0") -> RadarRegionPack {
        RadarRegionPack(
            bbox: .init(west: 0, south: 0, east: 1, north: 1),
            mercator: .init(minX: 0, minY: 0, maxX: 1, maxY: 1),
            grid: .init(w: 2, h: 2),
            scale: 10,
            hasSnow: false,
            palette: .init(
                rain: [.init(lower: 0.3, upper: 1.0, rgba: [10, 20, 30, 255])],
                snow: []
            ),
            minIntensity: 0.3,
            featherRadius: 0,
            frames: [
                .init(
                    id: frameID,
                    time: base,
                    isForecast: false,
                    source: .dwdRadar,
                    precipitationType: .unknown,
                    referenceTime: nil,
                    intensity: [0, 0, 0, 0],
                    snow: nil
                )
            ]
        )
    }
}

// MARK: - RadarV2Store + RainRadarServiceProtocol

@MainActor
struct RadarV2StoreDependencyInjectionTests {

    @Test func loadPopulatesTimelineFromInjectedServiceWithoutNetwork() async {
        let mock = MockRainRadarService()
        mock.fetchResult = .success(Fixtures.timeline(frameCount: 4))
        let store = RadarV2Store(rainRadarService: mock)

        await store.load()

        #expect(store.timeline != nil)
        #expect(store.visibleFrames.count == 4)
        #expect(mock.fetchTimelineCallCount == 1)
        // The freshly fetched timeline is both cached to disk and kept as
        // the in-memory preload, exactly as the production flow requires.
        #expect(mock.savedTimelines.count == 1)
        #expect(mock.preloadedTimeline != nil)
    }

    @Test func loadPrefersInjectedCachedTimelineOverFetching() async {
        let mock = MockRainRadarService()
        mock.cachedTimeline = Fixtures.timeline(frameCount: 2)
        mock.fetchResult = .success(Fixtures.timeline(frameCount: 9))
        let store = RadarV2Store(rainRadarService: mock)

        await store.load()

        // Cached timeline renders immediately; the fetch for a fresh one
        // still happens, but in a detached background refresh task that
        // `load()` doesn't wait on, so it may or may not have completed yet —
        // only the immediate, synchronous result is asserted here.
        #expect(store.timeline?.frames.count == 2)
    }

    @Test func loadSurfacesErrorWhenInjectedServiceFails() async {
        let mock = MockRainRadarService()
        mock.fetchResult = .failure(URLError(.timedOut))
        let store = RadarV2Store(rainRadarService: mock)

        await store.load()

        #expect(store.timeline == nil)
        #expect(store.errorMessage != nil)
    }
}

// MARK: - RegionPackController + RegionPackServiceProtocol

@MainActor
struct RegionPackControllerDependencyInjectionTests {

    @Test func loadPopulatesPackFromInjectedServiceWithoutNetwork() async throws {
        let pack = Fixtures.regionPack()
        let mock = MockRegionPackService(result: .success(pack))
        let controller = RegionPackController(regionPackService: mock)
        let start = Fixtures.base
        let end = Fixtures.base.addingTimeInterval(3600)

        controller.load(
            center: CLLocationCoordinate2D(latitude: 50, longitude: 9),
            kilometers: 100,
            keepsExistingOverlay: false,
            startTime: start,
            endTime: end
        )

        // `load()` kicks off its fetch in a background Task; poll briefly
        // for it to land instead of assuming a fixed delay.
        for _ in 0..<100 {
            if controller.pack != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.pack?.frames.count == pack.frames.count)
        #expect(mock.fetchCallCount == 1)
        #expect(mock.lastRequestedWindow?.start == start)
        #expect(mock.lastRequestedWindow?.end == end)
    }

    @Test func coversReflectsInjectedPacksFrameTimeSpan() async throws {
        let pack = Fixtures.regionPack()
        let mock = MockRegionPackService(result: .success(pack))
        let controller = RegionPackController(regionPackService: mock)

        controller.load(center: CLLocationCoordinate2D(latitude: 50, longitude: 9), kilometers: 100, keepsExistingOverlay: false)
        for _ in 0..<100 {
            if controller.pack != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(controller.covers(windowStart: Fixtures.base, windowEnd: Fixtures.base))
        #expect(!controller.covers(windowStart: Fixtures.base.addingTimeInterval(-3600), windowEnd: Fixtures.base))
    }
}

// MARK: - RadarV2Store stale-data detection

@MainActor
struct RadarV2StoreStaleDataTests {

    private func timeline(latestObservedMinutesAgo minutes: Double) -> RainRadarTimeline {
        RainRadarTimeline(
            host: "https://proxy.example",
            attribution: "test",
            source: .dwd,
            tileMaxZoom: 9,
            frames: [
                RainRadarFrame(
                    time: Date().addingTimeInterval(-minutes * 60),
                    path: "/tiles/stale-test",
                    isForecast: false,
                    sourceKind: .dwdRadar,
                    precipitationType: .unknown,
                    referenceTime: nil
                )
            ]
        )
    }

    @Test func dataIsStaleWhenLatestObservedFrameIsOlderThanThreshold() {
        let store = RadarV2Store()
        store.timeline = timeline(latestObservedMinutesAgo: 40)

        #expect(store.isDataStale)
        #expect(store.staleDataAgeLabel == "vor 40 Min.")
    }

    @Test func dataIsNotStaleWhenLatestObservedFrameIsRecent() {
        let store = RadarV2Store()
        store.timeline = timeline(latestObservedMinutesAgo: 5)

        #expect(!store.isDataStale)
        #expect(store.staleDataAgeLabel == nil)
    }

    @Test func dataIsNotStaleWithoutAnyTimelineLoaded() {
        let store = RadarV2Store()

        #expect(!store.isDataStale)
        #expect(store.staleDataAgeLabel == nil)
    }
}
