// RadarMapView.swift
import SwiftUI
@preconcurrency import MapKit
import UIKit

enum DwdWMSLayer: String, Identifiable {
    case lightningDensity = "dwd:Blitzdichte"

    var id: String { rawValue }
    var style: String { "" }
}

extension Date {
    var roundedDownToFiveMinuteBucket: Date {
        Date(timeIntervalSince1970: floor(timeIntervalSince1970 / 300.0) * 300.0)
    }
}

actor RadarTileReadinessCenter {
    static let shared = RadarTileReadinessCenter()

    private var readyFrameIDs = Set<String>()
    private var continuations: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]

    func markReady(_ frameID: String) {
        readyFrameIDs.insert(frameID)
        let waiting = continuations.removeValue(forKey: frameID).map { Array($0.values) } ?? []
        waiting.forEach { $0.resume() }
    }

    func invalidateAll() {
        readyFrameIDs.removeAll()
        let waiting = continuations.values.flatMap { Array($0.values) }
        continuations.removeAll()
        waiting.forEach { $0.resume() }
    }

    func isReady(_ frameID: String) -> Bool {
        readyFrameIDs.contains(frameID)
    }

    /// Waits until the frame's tiles are prefetched. Returns true when ready,
    /// false when the timeout elapsed first — callers can then decide to
    /// stall further instead of advancing onto empty tiles.
    @discardableResult
    func waitUntilReady(_ frameID: String, timeoutNanoseconds: UInt64) async -> Bool {
        if readyFrameIDs.contains(frameID) { return true }
        let waitID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if readyFrameIDs.contains(frameID) {
                    continuation.resume()
                } else {
                    continuations[frameID, default: [:]][waitID] = continuation
                    Task {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        await self.resumeContinuation(for: frameID, waitID: waitID)
                    }
                }
            }
        } onCancel: {
            Task {
                await self.resumeContinuation(for: frameID, waitID: waitID)
            }
        }
        return readyFrameIDs.contains(frameID)
    }

    private func resumeContinuation(for frameID: String, waitID: UUID) {
        guard let continuation = continuations[frameID]?.removeValue(forKey: waitID) else { return }
        if continuations[frameID]?.isEmpty == true {
            continuations[frameID] = nil
        }
        continuation.resume()
    }
}

struct RadarV2RenderRequest: Equatable {
    let host: String
    let source: RainRadarSource
    let tileMaxZoom: Int
    let frame: RainRadarFrame
    let neighborFrames: [RainRadarFrame]

    var id: String {
        "\(host)|\(source)|\(frame.id)|z\(tileMaxZoom)"
    }
}

struct RadarV2MapView: UIViewRepresentable {
    let region: MKCoordinateRegion
    let regionRevision: Int
    let request: RadarV2RenderRequest?
    let regionRenderSet: RadarRegionRenderSet?
    let suppressesTilePrefetch: Bool
    let enabledLayers: Set<DwdWMSLayer>
    let timelineFrame: RainRadarFrame?
    let isPlaying: Bool
    let userCoordinate: CLLocationCoordinate2D?
    /// Fired on tap/pan/zoom — the screen uses this to bring back
    /// auto-hidden chrome.
    var onUserInteraction: (() -> Void)? = nil
    var onRegionSettled: ((CLLocationCoordinate2D, MKMapRect) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        // Light base following the app theme (a dark base was tried and
        // rejected — colors read worse and the break from the main screen was
        // too hard). POIs stay off: the radar is the content here.
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.setRegion(region, animated: false)
        // Tap recognizer so the screen can bring back auto-hidden chrome;
        // works alongside MapKit's own gestures.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleMapTap))
        tap.delegate = context.coordinator
        mapView.addGestureRecognizer(tap)
        context.coordinator.lastAppliedRegionRevision = regionRevision
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.lastAppliedRegionRevision != regionRevision,
           !context.coordinator.regionApproximatelyMatches(mapView.region, region) {
            mapView.setRegion(region, animated: true)
            context.coordinator.lastAppliedRegionRevision = regionRevision
        }

        context.coordinator.onUserInteraction = onUserInteraction
        context.coordinator.onRegionSettled = onRegionSettled
        context.coordinator.update(
            request,
            regionRenderSet: regionRenderSet,
            suppressesTilePrefetch: suppressesTilePrefetch,
            in: mapView
        )
        context.coordinator.sync(layerIDs: enabledLayers, timelineFrame: timelineFrame, isPlaying: isPlaying, in: mapView)
        context.coordinator.syncUserAnnotation(userCoordinate, in: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onUserInteraction: (() -> Void)?
        var onRegionSettled: ((CLLocationCoordinate2D, MKMapRect) -> Void)?

        @objc func handleMapTap() {
            onUserInteraction?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Pan/zoom counts as interaction — bring chrome back.
            onUserInteraction?()
        }

        private var request: RadarV2RenderRequest?
        private var activeTileOverlay: RadarV2TileOverlay?
        private var activeTileOverlayKey: String?
        private var activeTileRenderer: MKTileOverlayRenderer?
        private var previousTileOverlay: RadarV2TileOverlay?
        private var previousTileRenderer: MKTileOverlayRenderer?
        private var regionRenderSet: RadarRegionRenderSet?
        private var activeRegionOverlay: RadarRegionOverlay?
        private var activeRegionOverlayKey: String?
        private var prewarmTask: Task<Void, Never>?
        private var dwdOverlays: [String: MKTileOverlay] = [:]
        private var regionChangeTask: Task<Void, Never>?
        private var frozenWMSLayerTime: Date?
        private var userAnnotation: MKPointAnnotation?
        private var suppressesTilePrefetch = false
        var lastAppliedRegionRevision = 0

        func update(
            _ request: RadarV2RenderRequest?,
            regionRenderSet: RadarRegionRenderSet?,
            suppressesTilePrefetch: Bool,
            in mapView: MKMapView
        ) {
            guard let request else {
                clearRadar(in: mapView)
                self.request = nil
                self.regionRenderSet = nil
                self.suppressesTilePrefetch = false
                return
            }
            self.request = request
            self.regionRenderSet = regionRenderSet
            self.suppressesTilePrefetch = suppressesTilePrefetch
            if updateRegionOverlayIfPossible(for: request, in: mapView) {
                clearTileRadar(in: mapView)
                Task { await RadarTileReadinessCenter.shared.markReady(request.frame.id) }
            } else if shouldSuppressTileFallback(for: request, in: mapView) {
                clearTileRadar(in: mapView)
            } else {
                updateTileOverlay(for: request, in: mapView)
                prewarmNativeTiles(for: request, in: mapView)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            Task { await RadarTileReadinessCenter.shared.invalidateAll() }
            regionChangeTask?.cancel()
            if let request {
                regionChangeTask = Task { [weak self, weak mapView] in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard !Task.isCancelled, let self, let mapView else { return }
                    await MainActor.run {
                        if self.updateRegionOverlayIfPossible(for: request, in: mapView) {
                            self.clearTileRadar(in: mapView)
                        } else if self.shouldSuppressTileFallback(for: request, in: mapView) {
                            self.clearTileRadar(in: mapView)
                        } else {
                            self.prewarmNativeTiles(for: request, in: mapView)
                        }
                        self.onRegionSettled?(mapView.region.center, mapView.visibleMapRect)
                    }
                }
            } else {
                onRegionSettled?(mapView.region.center, mapView.visibleMapRect)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is RadarRegionOverlay {
                return RadarRegionOverlayRenderer(overlay: overlay)
            }
            if let tileOverlay = overlay as? RadarV2TileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = previousTileOverlay == nil && tileOverlay === activeTileOverlay ? 0.84 : 0
                if tileOverlay === activeTileOverlay {
                    activeTileRenderer = renderer
                    let frameID = tileOverlay.requestFrameID
                    Task { [weak self, weak mapView, weak tileOverlay] in
                        guard await RadarTileReadinessCenter.shared.isReady(frameID) else { return }
                        await MainActor.run {
                            guard let self, let mapView, let tileOverlay, tileOverlay === self.activeTileOverlay else { return }
                            self.crossfadeTileOverlayIfNeeded(in: mapView)
                        }
                    }
                }
                return renderer
            }
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = 0.84
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "RadarV2Location"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = UIColor(Color(hex: "#1a9be8"))
                marker.glyphImage = UIImage(systemName: "location.fill")
            }
            return view
        }

        func sync(layerIDs layers: Set<DwdWMSLayer>, timelineFrame: RainRadarFrame?, isPlaying: Bool, in mapView: MKMapView) {
            // During playback the WMS layer time is frozen: reloading an
            // uncached GetMap overlay per animation frame flickers and hammers
            // the DWD GeoServer. Layer toggles still apply immediately.
            let baseTime: Date?
            if isPlaying, let frozenWMSLayerTime {
                baseTime = frozenWMSLayerTime
            } else {
                baseTime = timelineFrame?.time
                frozenWMSLayerTime = baseTime
            }

            let currentIDs = Set(layers.map { overlayKey(for: $0, baseTime: baseTime) })
            for (id, overlay) in dwdOverlays where !currentIDs.contains(id) {
                mapView.removeOverlay(overlay)
                dwdOverlays[id] = nil
            }
            for layer in layers {
                let key = overlayKey(for: layer, baseTime: baseTime)
                guard dwdOverlays[key] == nil else { continue }
                let overlay = DwdWMSTileOverlay(layer: layer, time: overlayTime(for: layer, baseTime: baseTime))
                overlay.canReplaceMapContent = false
                overlay.minimumZ = 3
                overlay.maximumZ = 18
                dwdOverlays[key] = overlay
                mapView.addOverlay(overlay, level: .aboveLabels)
            }
        }

        private func overlayKey(for layer: DwdWMSLayer, baseTime: Date?) -> String {
            "\(layer.id)|\(overlayTime(for: layer, baseTime: baseTime)?.timeIntervalSince1970 ?? 0)"
        }

        private func overlayTime(for layer: DwdWMSLayer, baseTime: Date?) -> Date? {
            guard let baseTime else { return nil }
            switch layer {
            case .lightningDensity:
                // The DWD lightning density product is published on a 5-minute
                // grid; exact intermediate times return empty tiles.
                return baseTime.roundedDownToFiveMinuteBucket
            }
        }

        func syncUserAnnotation(_ coordinate: CLLocationCoordinate2D?, in mapView: MKMapView) {
            guard let coordinate else {
                if let userAnnotation {
                    mapView.removeAnnotation(userAnnotation)
                    self.userAnnotation = nil
                }
                return
            }
            if let userAnnotation {
                let current = userAnnotation.coordinate
                let changed = abs(current.latitude - coordinate.latitude) > 0.0001 ||
                    abs(current.longitude - coordinate.longitude) > 0.0001
                guard changed else { return }
                userAnnotation.coordinate = coordinate
                return
            }
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Dein Ort"
            userAnnotation = annotation
            mapView.addAnnotation(annotation)
        }

        private func updateTileOverlay(for request: RadarV2RenderRequest, in mapView: MKMapView) {
            let key = request.id
            guard activeTileOverlayKey != key else { return }

            if let orphan = previousTileOverlay, orphan !== activeTileOverlay {
                mapView.removeOverlay(orphan)
            }

            previousTileOverlay = activeTileOverlay
            previousTileRenderer = activeTileRenderer
            let overlay = RadarV2TileOverlay(request: request)
            overlay.canReplaceMapContent = false
            overlay.tileSize = CGSize(width: 512, height: 512)
            overlay.minimumZ = 3
            overlay.maximumZ = request.tileMaxZoom
            activeTileOverlay = overlay
            activeTileRenderer = nil
            activeTileOverlayKey = key
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        private func updateRegionOverlayIfPossible(for request: RadarV2RenderRequest, in mapView: MKMapView) -> Bool {
            guard request.source == .dwd,
                  let regionRenderSet,
                  regionRenderSet.pack.mapRect.regionContains(mapView.visibleMapRect),
                  mapView.visibleMapRect.width >= regionRenderSet.pack.mapRect.width / 8.0,
                  let image = regionRenderSet.image(for: request.frame) else {
                return false
            }
            let key = "\(request.frame.id)|\(regionRenderSet.pack.mercator.minX)|\(regionRenderSet.pack.mercator.minY)"
            guard activeRegionOverlayKey != key else { return true }
            clearRegionRadar(in: mapView)
            let overlay = RadarRegionOverlay(mapRect: regionRenderSet.pack.mapRect, image: image)
            activeRegionOverlay = overlay
            activeRegionOverlayKey = key
            mapView.addOverlay(overlay, level: .aboveLabels)
            return true
        }

        private func shouldSuppressTileFallback(for request: RadarV2RenderRequest, in mapView: MKMapView) -> Bool {
            guard suppressesTilePrefetch, request.source == .dwd else { return false }
            guard let regionRenderSet else { return true }
            return regionRenderSet.pack.mapRect.regionContains(mapView.visibleMapRect) &&
                mapView.visibleMapRect.width >= regionRenderSet.pack.mapRect.width / 8.0 &&
                regionRenderSet.image(for: request.frame) != nil
        }

        private func prewarmNativeTiles(for request: RadarV2RenderRequest, in mapView: MKMapView) {
            prewarmTask?.cancel()
            guard let plan = RadarV2TilePrefetchPlan(mapView: mapView, request: request) else { return }
            prewarmTask = Task(priority: .utility) { [weak self, weak mapView] in
                await plan.fetch()
                guard !Task.isCancelled, let self, let mapView else { return }
                await MainActor.run {
                    self.crossfadeTileOverlayIfNeeded(in: mapView)
                }
            }
        }

        private func crossfadeTileOverlayIfNeeded(in mapView: MKMapView) {
            guard let nextRenderer = activeTileRenderer else { return }
            let oldOverlay = previousTileOverlay
            let oldRenderer = previousTileRenderer
            previousTileOverlay = nil
            previousTileRenderer = nil

            CATransaction.begin()
            CATransaction.setAnimationDuration(DesignTokens.Motion.radarCrossfade)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            oldRenderer?.alpha = 0
            nextRenderer.alpha = 0.84
            CATransaction.setCompletionBlock { [weak self, weak mapView, weak oldOverlay] in
                guard let mapView else { return }
                if let oldOverlay {
                    mapView.removeOverlay(oldOverlay)
                }
                self?.clearRegionRadar(in: mapView)
            }
            CATransaction.commit()
        }

        private func clearRadar(in mapView: MKMapView) {
            prewarmTask?.cancel()
            regionChangeTask?.cancel()
            clearRegionRadar(in: mapView)
            clearTileRadar(in: mapView)
        }

        private func clearTileRadar(in mapView: MKMapView) {
            prewarmTask?.cancel()
            if let activeTileOverlay {
                mapView.removeOverlay(activeTileOverlay)
            }
            if let previousTileOverlay {
                mapView.removeOverlay(previousTileOverlay)
            }
            activeTileOverlay = nil
            activeTileRenderer = nil
            previousTileOverlay = nil
            previousTileRenderer = nil
            activeTileOverlayKey = nil
        }

        private func clearRegionRadar(in mapView: MKMapView) {
            if let activeRegionOverlay {
                mapView.removeOverlay(activeRegionOverlay)
            }
            activeRegionOverlay = nil
            activeRegionOverlayKey = nil
        }

        func regionApproximatelyMatches(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.2 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.2 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.4 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.4
        }
    }
}

extension MKMapRect {
    func regionContains(_ other: MKMapRect) -> Bool {
        minX <= other.minX &&
        minY <= other.minY &&
        maxX >= other.maxX &&
        maxY >= other.maxY
    }
}

struct RadarV2FrameURLGroup: Sendable {
    let frameID: String
    let urls: [URL]
}

struct RadarV2TilePrefetchPlan {
    let frameURLGroups: [RadarV2FrameURLGroup]

    @MainActor
    init?(mapView: MKMapView, request: RadarV2RenderRequest) {
        guard mapView.bounds.width > 0, mapView.bounds.height > 0 else { return nil }
        let mapRect = mapView.visibleMapRect
        guard mapRect.width > 0, mapRect.height > 0 else { return nil }

        let zoomScale = Double(mapView.bounds.width) / mapRect.width
        let visibleZoom = min(max(Int(floor(log2(zoomScale) + 20.0)), 3), min(request.tileMaxZoom, 18))
        // Prefetch the displayed zoom and one coarser level only. The finer
        // visibleZoom+1 level costs 4× the tiles for a zoom the user isn't
        // viewing yet and slows frame readiness during playback.
        let zooms = Array(Set([visibleZoom, max(3, visibleZoom - 1)])).sorted()
        let frames = [request.frame] + request.neighborFrames

        var groups: [RadarV2FrameURLGroup] = []
        var globalSeen = Set<String>()
        for frame in frames {
            var frameURLs: [URL] = []
            for zoom in zooms {
                let range = Self.tileRange(for: mapRect, zoom: zoom)
                for x in range.x {
                    for y in range.y {
                        guard let url = Self.url(for: frame, request: request, zoom: zoom, x: x, y: y) else { continue }
                        let key = url.absoluteString
                        if globalSeen.insert(key).inserted {
                            frameURLs.append(url)
                        }
                    }
                }
            }
            if !frameURLs.isEmpty {
                let limit = frame == request.frame ? 72 : 48
                groups.append(RadarV2FrameURLGroup(frameID: frame.id, urls: Array(frameURLs.prefix(limit))))
            }
        }
        frameURLGroups = groups
    }

    func fetch() async {
        let groups = frameURLGroups
        guard let current = groups.first else { return }
        // Priority wave: current frame, then the two immediate forward frames,
        // sequentially — these are what playback needs next, so they must not
        // compete with the wider prefetch for bandwidth.
        await Self.fetchAndMark(current)
        for frameGroup in groups.dropFirst().prefix(2) {
            await Self.fetchAndMark(frameGroup)
        }
        // Remaining neighbors fill in parallel afterwards.
        let rest = Array(groups.dropFirst(3).prefix(8))
        await withTaskGroup(of: Void.self) { group in
            for frameGroup in rest {
                group.addTask {
                    await Self.fetchAndMark(frameGroup)
                }
            }
        }
    }

    private static func fetchAndMark(_ frameGroup: RadarV2FrameURLGroup) async {
        let loaded = await fetch(urls: frameGroup.urls)
        if loaded >= max(1, frameGroup.urls.count / 2) {
            await RadarTileReadinessCenter.shared.markReady(frameGroup.frameID)
        }
    }

    private static func fetch(urls: [URL]) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for url in urls {
                group.addTask {
                    var request = RainRadarService.authenticatedDwdRadarRequest(url, cachePolicy: .returnCacheDataElseLoad)
                    request.timeoutInterval = 8
                    do {
                        let (_, response) = try await URLSession.shared.data(for: request)
                        return (response as? HTTPURLResponse)?.statusCode == 200
                    } catch {
                        return false
                    }
                }
            }
            var loaded = 0
            for await ok in group {
                if ok {
                    loaded += 1
                }
            }
            return loaded
        }
    }

    private static func url(for frame: RainRadarFrame, request: RadarV2RenderRequest, zoom: Int, x: Int, y: Int) -> URL? {
        switch request.source {
        case .dwd:
            guard let url = URL(string: "\(request.host)\(frame.path)/\(zoom)/\(x)/\(y).png") else { return nil }
            return url
        case .rainViewer:
            return URL(string: "\(request.host)\(frame.path)/512/\(zoom)/\(x)/\(y)/2/1_1.png")
        }
    }

    private static func tileRange(for mapRect: MKMapRect, zoom: Int) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let tileCount = Int(pow(2.0, Double(zoom)))
        let tileMapSize = MKMapSize.world.width / Double(tileCount)
        let minX = min(max(Int(floor(mapRect.minX / tileMapSize)), 0), tileCount - 1)
        let maxX = min(max(Int(floor((mapRect.maxX - 1) / tileMapSize)), 0), tileCount - 1)
        let minY = min(max(Int(floor(mapRect.minY / tileMapSize)), 0), tileCount - 1)
        let maxY = min(max(Int(floor((mapRect.maxY - 1) / tileMapSize)), 0), tileCount - 1)
        return (minX...max(minX, maxX), minY...max(minY, maxY))
    }
}

final class RadarV2TileOverlay: MKTileOverlay {
    private let request: RadarV2RenderRequest

    var requestFrameID: String {
        request.frame.id
    }

    init(request: RadarV2RenderRequest) {
        self.request = request
        super.init(urlTemplate: nil)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        switch request.source {
        case .dwd:
            return tileURL(for: path) ?? URL(string: "about:blank")!
        case .rainViewer:
            return URL(string: "\(request.host)\(request.frame.path)/512/\(path.z)/\(path.x)/\(path.y)/2/1_1.png")
                ?? URL(string: "about:blank")!
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping @Sendable (Data?, Error?) -> Void) {
        guard request.source == .dwd, let url = tileURL(for: path) else {
            super.loadTile(at: path, result: result)
            return
        }
        var tileRequest = RainRadarService.authenticatedDwdRadarRequest(url, cachePolicy: .returnCacheDataElseLoad)
        tileRequest.timeoutInterval = 10
        URLSession.shared.dataTask(with: tileRequest) { data, response, error in
            if let error {
                result(nil, error)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                result(nil, URLError(.badServerResponse))
                return
            }
            guard let data, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
                result(nil, URLError(.cannotDecodeContentData))
                return
            }
            result(data, error)
        }.resume()
    }

    private func tileURL(for path: MKTileOverlayPath) -> URL? {
        URL(string: "\(request.host)\(request.frame.path)/\(path.z)/\(path.x)/\(path.y).png")
    }
}

final class DwdWMSTileOverlay: MKTileOverlay {
    private let layer: DwdWMSLayer
    private let time: Date?
    private let originShift = 20_037_508.342789244

    private static let timeFormat = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)

    init(layer: DwdWMSLayer, time: Date?) {
        self.layer = layer
        self.time = time
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let bbox = webMercatorBBOX(for: path)
        var components = URLComponents(string: "https://maps.dwd.de/geoserver/dwd/ows")!
        components.queryItems = [
            URLQueryItem(name: "SERVICE", value: "WMS"),
            URLQueryItem(name: "VERSION", value: "1.3.0"),
            URLQueryItem(name: "REQUEST", value: "GetMap"),
            URLQueryItem(name: "FORMAT", value: "image/png"),
            URLQueryItem(name: "TRANSPARENT", value: "true"),
            URLQueryItem(name: "LAYERS", value: layer.rawValue),
            URLQueryItem(name: "STYLES", value: layer.style),
            URLQueryItem(name: "CRS", value: "EPSG:3857"),
            URLQueryItem(name: "BBOX", value: bbox),
            URLQueryItem(name: "WIDTH", value: "512"),
            URLQueryItem(name: "HEIGHT", value: "512"),
        ]
        if let time {
            components.queryItems?.append(
                URLQueryItem(name: "TIME", value: Self.wmsTimeString(time))
            )
        }
        return components.url!
    }

    private static func wmsTimeString(_ date: Date) -> String {
        date.formatted(timeFormat).replacingOccurrences(of: "Z", with: ".000Z")
    }

    private func webMercatorBBOX(for path: MKTileOverlayPath) -> String {
        let tileCount = pow(2.0, Double(path.z))
        let tileMeters = originShift * 2.0 / tileCount
        let minX = -originShift + Double(path.x) * tileMeters
        let maxX = minX + tileMeters
        let maxY = originShift - Double(path.y) * tileMeters
        let minY = maxY - tileMeters
        return "\(minX),\(minY),\(maxX),\(maxY)"
    }
}
