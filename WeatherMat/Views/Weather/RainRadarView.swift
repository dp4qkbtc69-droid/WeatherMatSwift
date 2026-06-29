// RainRadarView.swift
import SwiftUI
import MapKit
import UIKit
import ImageIO

private let rainRadarHomeRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.1, longitude: 10.4),
    span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 11.0)
)

private enum DwdWMSLayer: String, Identifiable {
    case lightningDensity = "Blitzdichte"

    var id: String { rawValue }

    var style: String { "blitzdichte" }
}

@MainActor
@Observable
private final class RainRadarViewModel {
    var timeline: RainRadarTimeline?
    var selectedIndex = 0
    var isPlaying = false
    var isLoading = false
    var errorMessage: String?

    var selectedFrame: RainRadarFrame? {
        let frames = visibleFrames
        guard !frames.isEmpty else { return nil }
        return frames[min(selectedIndex, frames.count - 1)]
    }

    var visibleFrames: [RainRadarFrame] {
        guard let frames = timeline?.frames, !frames.isEmpty else { return [] }
        guard let latestObserved = timeline?.latestObservedFrame else { return frames }
        let lowerBound = latestObserved.time.addingTimeInterval(-24 * 60 * 60)
        let upperBound = latestObserved.time.addingTimeInterval(120 * 60 * 60)
        return frames.filter { $0.time >= lowerBound && $0.time <= upperBound }
    }

    var selectedTimeLabel: String {
        guard let selectedFrame else { return "--:--" }
        return selectedFrame.time.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
    }

    var selectedDateLabel: String {
        guard let selectedFrame else { return "--" }
        return selectedFrame.time.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).locale(.init(identifier: "de_DE")))
    }

    var availableRangeLabel: String {
        guard let first = visibleFrames.first?.time,
              let last = visibleFrames.last?.time,
              let latest = timeline?.latestObservedFrame?.time else {
            return "Zeitverlauf"
        }
        return "\(relativeLabel(for: first, relativeTo: latest)) bis \(relativeLabel(for: last, relativeTo: latest))"
    }

    func load() async {
        guard timeline == nil else { return }
        isLoading = true
        errorMessage = nil
        do {
            let loaded = try await RainRadarService.fetchTimeline()
            timeline = loaded
            if let latest = loaded.latestObservedFrame,
               let index = visibleFrames.firstIndex(of: latest) {
                selectedIndex = index
            }
            isLoading = false
            // Extend with ICON-EU in background – radar is already visible
            Task { await appendIconEuFrames(to: loaded) }
        } catch {
            errorMessage = "Radar konnte nicht geladen werden."
            isLoading = false
        }
    }

    private func appendIconEuFrames(to radarTimeline: RainRadarTimeline) async {
        guard let meta = try? await DwdIconForecastService.fetchForecastMeta() else { return }
        let radarEnd = radarTimeline.latestObservedFrame?.time ?? Date()
        let cutoff = radarEnd.addingTimeInterval(1800)
        let iconFrames = meta.availableTimes
            .filter { $0 > cutoff }
            .map { time in
                RainRadarFrame(
                    time: time,
                    path: "\(meta.layerName)|\(DwdIconForecastService.isoFormatter.string(from: time))",
                    isForecast: true,
                    frameSource: .dwdIconEu(layerName: meta.layerName)
                )
            }
        guard !iconFrames.isEmpty else { return }
        timeline = RainRadarTimeline(
            host: radarTimeline.host,
            attribution: radarTimeline.attribution + " · ICON-EU DWD",
            source: radarTimeline.source,
            tileMaxZoom: radarTimeline.tileMaxZoom,
            frames: radarTimeline.frames + iconFrames
        )
    }

    func advanceFrame() {
        let frames = visibleFrames
        guard !frames.isEmpty else { return }
        selectedIndex = selectedIndex >= frames.count - 1 ? 0 : selectedIndex + 1
    }

    private func relativeLabel(for date: Date, relativeTo reference: Date) -> String {
        let seconds = date.timeIntervalSince(reference)
        if abs(seconds) < 90 { return "jetzt" }
        let hours = Int((seconds / 3600).rounded())
        if abs(hours) < 24 {
            return hours > 0 ? "+\(hours)h" : "\(hours)h"
        }
        let days = Int((Double(hours) / 24).rounded())
        return days > 0 ? "+\(days)d" : "\(days)d"
    }
}

struct RainRadarCardView: View {
    let location: SavedLocation?
    let rain: RainAnalysis
    let openRadar: () -> Void

    var body: some View {
        Button {
            HapticService.impact(.light)
            openRadar()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Regenradar", systemImage: "map.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(.white)

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(location?.name ?? "Aktueller Ort")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(rain.text.isEmpty ? "Radar und Zugrichtung ansehen" : rain.text)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(2)
                    }

                    Spacer()

                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#dff0f7"), Color(hex: "#f8fafb")],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                        RadarPreviewShape()
                            .fill(RadarGradient())
                            .frame(width: 88, height: 72)
                            .offset(x: -8, y: 2)
                        Image(systemName: "location.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(hex: "#2f4fa7"))
                            .offset(x: 24, y: 18)
                    }
                    .frame(width: 118, height: 82)
                    .clipped()
                }
            }
            .padding(16)
            .background(Color.black.opacity(0.08))
            .background(.white.opacity(0.11))
            .background(.ultraThinMaterial.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Regenradar öffnen")
    }
}

struct RainRadarScreen: View {
    let location: SavedLocation?
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = RainRadarViewModel()
    @State private var mapRegion = rainRadarHomeRegion
    @State private var regionRevision = 0
    @State private var dwdLayers = Set<DwdWMSLayer>()
    @State private var noticeText: String?

    private var userCoordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var body: some View {
        ZStack(alignment: .top) {
            RadarMapRepresentable(
                region: mapRegion,
                regionRevision: regionRevision,
                host: viewModel.timeline?.host,
                frames: viewModel.visibleFrames,
                frame: viewModel.selectedFrame,
                source: viewModel.timeline?.source,
                tileMaxZoom: viewModel.timeline?.tileMaxZoom,
                dwdLayers: dwdLayers,
                userCoordinate: userCoordinate
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                Spacer()
                timeline
            }

            mapControls
                .padding(.top, 132)
                .padding(.trailing, 16)

            if let noticeText {
                Text(noticeText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.38))
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 134)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await viewModel.load() }
        .task(id: viewModel.isPlaying) {
            guard viewModel.isPlaying else { return }
            while viewModel.isPlaying {
                let isLastFrame = viewModel.selectedIndex >= viewModel.visibleFrames.count - 1
                try? await Task.sleep(nanoseconds: isLastFrame ? 1_600_000_000 : 520_000_000)
                guard !Task.isCancelled else { return }
                viewModel.advanceFrame()
            }
        }
        .statusBarHidden(false)
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.12), in: Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Radar")
                        .font(.system(size: 28, weight: .bold))
                    HStack(spacing: 6) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(location?.name ?? "Deutschland")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .opacity(0.88)
                    Text(dateLine)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.70)
                }

                Spacer()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 46)
        .padding(.bottom, 14)
        .background(Color.black.opacity(0.10))
        .background(.white.opacity(0.10))
        .background(.ultraThinMaterial.opacity(0.78))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.18))
                .frame(height: 1)
        }
    }

    private var mapControls: some View {
        VStack(spacing: 12) {
            RadarRoundButton(icon: "location.fill") {
                guard let userCoordinate else {
                    showNotice("Kein Ort verfügbar")
                    return
                }
                withAnimation(.easeInOut(duration: 0.25)) {
                    mapRegion = MKCoordinateRegion(
                        center: userCoordinate,
                        span: MKCoordinateSpan(latitudeDelta: 2.6, longitudeDelta: 2.6)
                    )
                    regionRevision += 1
                }
            }
            RadarRoundButton(icon: "drop.fill", selected: true) {
                showNotice("Radar aktiv")
            }
            RadarRoundButton(icon: "bolt.fill", selected: dwdLayers.contains(.lightningDensity)) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggleDwdLayer(.lightningDensity)
                }
                showNotice(dwdLayers.contains(.lightningDensity) ? "DWD-Blitzdichte aktiv" : "DWD-Blitzdichte aus")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func showNotice(_ text: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            noticeText = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if noticeText == text {
                withAnimation(.easeInOut(duration: 0.18)) {
                    noticeText = nil
                }
            }
        }
    }

    private func toggleDwdLayer(_ layer: DwdWMSLayer) {
        if dwdLayers.contains(layer) {
            dwdLayers.remove(layer)
        } else {
            dwdLayers.insert(layer)
        }
    }

    @ViewBuilder
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
            } else if !viewModel.visibleFrames.isEmpty {
                RainRadarTimelineControl(
                    frames: viewModel.visibleFrames,
                    selectedIndex: Binding(
                        get: { viewModel.selectedIndex },
                        set: {
                            viewModel.isPlaying = false
                            viewModel.selectedIndex = $0
                        }
                    ),
                    isPlaying: Binding(
                        get: { viewModel.isPlaying },
                        set: { viewModel.isPlaying = $0 }
                    ),
                    selectedTimeLabel: viewModel.selectedTimeLabel,
                    selectedDateLabel: viewModel.selectedDateLabel,
                    rangeLabel: viewModel.availableRangeLabel
                )

                HStack {
                    Text(viewModel.selectedFrame?.isForecast == true ? "Prognose" : "Radar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Spacer()
                    Text(viewModel.timeline?.attribution ?? "Radarquelle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }
            } else {
                Text("Lade Radar...")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(.black.opacity(0.28))
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var dateLine: String {
        guard let frame = viewModel.selectedFrame else {
            return Date().formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute().locale(.init(identifier: "de_DE")))
        }
        return frame.time.formatted(.dateTime.weekday(.abbreviated).day().month(.wide).hour().minute().locale(.init(identifier: "de_DE")))
    }
}

private struct RadarMapRepresentable: UIViewRepresentable {
    let region: MKCoordinateRegion
    let regionRevision: Int
    let host: String?
    let frames: [RainRadarFrame]
    let frame: RainRadarFrame?
    let source: RainRadarSource?
    let tileMaxZoom: Int?
    let dwdLayers: Set<DwdWMSLayer>
    let userCoordinate: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .mutedStandard
        mapView.pointOfInterestFilter = .includingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.setRegion(region, animated: false)
        context.coordinator.lastAppliedRegionRevision = regionRevision
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.lastAppliedRegionRevision != regionRevision,
           !context.coordinator.regionApproximatelyMatches(mapView.region, region) {
            mapView.setRegion(region, animated: true)
            context.coordinator.lastAppliedRegionRevision = regionRevision
        }

        context.coordinator.updateRadarRequest(
            host: host,
            frames: frames,
            selectedFrame: frame,
            source: source ?? .dwd,
            tileMaxZoom: tileMaxZoom ?? 8,
            in: mapView
        )

        let currentLayerIDs = Set(dwdLayers.map(\.id))
        for (id, overlay) in context.coordinator.dwdOverlays where !currentLayerIDs.contains(id) {
            mapView.removeOverlay(overlay)
            context.coordinator.dwdOverlays[id] = nil
        }
        for layer in dwdLayers where context.coordinator.dwdOverlays[layer.id] == nil {
            let overlay = DwdWMSTileOverlay(layer: layer)
            overlay.canReplaceMapContent = false
            overlay.minimumZ = 3
            overlay.maximumZ = 18
            context.coordinator.dwdOverlays[layer.id] = overlay
            mapView.addOverlay(overlay, level: .aboveLabels)
        }

        context.coordinator.syncUserAnnotation(userCoordinate, in: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private let compositor = RadarFrameCompositor()
        private var radarRequest: RadarFrameRequest?
        private var activeRadarOverlay: RadarFrameImageOverlay?
        private var activeRadarRenderer: RadarFrameImageRenderer?
        private var pendingPreviousOverlay: RadarFrameImageOverlay?
        private var pendingPreviousRenderer: RadarFrameImageRenderer?
        private var rendererByOverlay: [ObjectIdentifier: RadarFrameImageRenderer] = [:]
        private var currentRenderContextID: String?
        private var renderedFrameKey: String?
        private var renderTask: Task<Void, Never>?
        private var prewarmTask: Task<Void, Never>?
        var dwdOverlays: [String: MKTileOverlay] = [:]
        var lastAppliedRegionRevision = 0
        private var userAnnotation: MKPointAnnotation?

        func updateRadarRequest(
            host: String?,
            frames: [RainRadarFrame],
            selectedFrame: RainRadarFrame?,
            source: RainRadarSource,
            tileMaxZoom: Int,
            in mapView: MKMapView
        ) {
            guard let host, let selectedFrame, !frames.isEmpty else {
                clearRadar(in: mapView)
                return
            }
            radarRequest = RadarFrameRequest(
                host: host,
                frames: frames,
                selectedFrame: selectedFrame,
                source: source,
                tileMaxZoom: tileMaxZoom
            )
            refreshRadar(in: mapView)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let radarOverlay = overlay as? RadarFrameImageOverlay {
                let renderer = RadarFrameImageRenderer(overlay: radarOverlay)
                renderer.alpha = 0
                rendererByOverlay[ObjectIdentifier(radarOverlay)] = renderer
                if radarOverlay === activeRadarOverlay {
                    activeRadarRenderer = renderer
                    triggerRadarCrossfade(nextOverlay: radarOverlay, nextRenderer: renderer, in: mapView)
                }
                return renderer
            }
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = 0.74
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard radarRequest != nil else { return }
            currentRenderContextID = nil
            renderedFrameKey = nil
            refreshRadar(in: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "RadarLocation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = UIColor(Color(hex: "#1a9be8"))
                marker.glyphImage = UIImage(systemName: "location.fill")
            }
            return view
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

        private func refreshRadar(in mapView: MKMapView) {
            guard let request = radarRequest,
                  let context = RadarFrameRenderContext(mapView: mapView, request: request)
            else { return }

            if currentRenderContextID != context.id {
                currentRenderContextID = context.id
                renderedFrameKey = nil
                compositor.removeAllImages()
                prewarmFrames(for: request, context: context)
            }

            let frameKey = context.cacheKey(for: request.selectedFrame)
            guard renderedFrameKey != frameKey else { return }

            if let image = compositor.image(for: frameKey) {
                applyRadarImage(image, frameKey: frameKey, context: context, in: mapView)
                prewarmFrames(for: request, context: context)
                return
            }

            renderTask?.cancel()
            renderTask = Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView else { return }
                do {
                    let image = try await compositor.image(for: request.selectedFrame, context: context)
                    guard !Task.isCancelled else { return }
                    applyRadarImage(image, frameKey: frameKey, context: context, in: mapView)
                    prewarmFrames(for: request, context: context)
                } catch {
                    // Keep the previous complete frame visible rather than flashing an empty radar layer.
                }
            }
        }

        private func prewarmFrames(for request: RadarFrameRequest, context: RadarFrameRenderContext) {
            prewarmTask?.cancel()
            prewarmTask = Task { @MainActor [compositor] in
                for frame in request.framesForPrewarm {
                    guard !Task.isCancelled else { return }
                    _ = try? await compositor.image(for: frame, context: context)
                }
            }
        }

        private func applyRadarImage(
            _ image: CGImage,
            frameKey: String,
            context: RadarFrameRenderContext,
            in mapView: MKMapView
        ) {
            guard renderedFrameKey != frameKey else { return }

            if let orphanOverlay = pendingPreviousOverlay,
               orphanOverlay !== activeRadarOverlay {
                mapView.removeOverlay(orphanOverlay)
                rendererByOverlay[ObjectIdentifier(orphanOverlay)] = nil
            }

            pendingPreviousOverlay = activeRadarOverlay
            pendingPreviousRenderer = activeRadarRenderer
            let nextOverlay = RadarFrameImageOverlay(
                image: image,
                boundingMapRect: context.boundingMapRect,
                targetAlpha: 0.82
            )

            activeRadarOverlay = nextOverlay
            activeRadarRenderer = nil
            renderedFrameKey = frameKey
            mapView.addOverlay(nextOverlay, level: .aboveLabels)
        }

        private func triggerRadarCrossfade(
            nextOverlay: RadarFrameImageOverlay,
            nextRenderer: RadarFrameImageRenderer,
            in mapView: MKMapView
        ) {
            let previousOverlay = pendingPreviousOverlay
            let previousRenderer = pendingPreviousRenderer
            pendingPreviousOverlay = nil
            pendingPreviousRenderer = nil

            CATransaction.begin()
            CATransaction.setAnimationDuration(0.26)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            previousRenderer?.alpha = 0
            nextRenderer.alpha = nextOverlay.targetAlpha
            CATransaction.setCompletionBlock { [weak self, weak mapView, weak previousOverlay] in
                guard let mapView, let previousOverlay else { return }
                mapView.removeOverlay(previousOverlay)
                self?.rendererByOverlay[ObjectIdentifier(previousOverlay)] = nil
            }
            CATransaction.commit()
        }

        private func clearRadar(in mapView: MKMapView) {
            renderTask?.cancel()
            prewarmTask?.cancel()
            renderedFrameKey = nil
            currentRenderContextID = nil
            if let activeRadarOverlay {
                mapView.removeOverlay(activeRadarOverlay)
            }
            if let pendingPreviousOverlay {
                mapView.removeOverlay(pendingPreviousOverlay)
            }
            activeRadarOverlay = nil
            activeRadarRenderer = nil
            pendingPreviousOverlay = nil
            pendingPreviousRenderer = nil
            rendererByOverlay.removeAll()
        }

        func regionApproximatelyMatches(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.2 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.2 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.4 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.4
        }
    }
}

private struct RadarFrameRequest {
    let host: String
    let frames: [RainRadarFrame]
    let selectedFrame: RainRadarFrame
    let source: RainRadarSource
    let tileMaxZoom: Int

    var framesForPrewarm: [RainRadarFrame] {
        guard let selectedIndex = frames.firstIndex(of: selectedFrame) else { return Array(frames.prefix(8)) }
        let upcoming = frames[selectedIndex...]
        let previous = frames[..<selectedIndex]
        return Array((upcoming + previous).prefix(8))
    }
}

private struct RadarFrameRenderContext {
    let host: String
    let source: RainRadarSource
    let sourceZoom: Int
    let xRange: ClosedRange<Int>
    let yRange: ClosedRange<Int>
    let boundingMapRect: MKMapRect
    let id: String

    private static let tilePixelSize = 512

    @MainActor
    init?(mapView: MKMapView, request: RadarFrameRequest) {
        let mapRect = mapView.visibleMapRect
        guard mapView.bounds.width > 0,
              mapView.bounds.height > 0,
              mapRect.width > 0,
              mapRect.height > 0 else {
            return nil
        }

        let zoomScale = Double(mapView.bounds.width) / mapRect.width
        var zoom = min(max(Int(floor(log2(zoomScale) + 20.0)), 3), max(3, request.tileMaxZoom))
        var tileRange = Self.tileRange(for: mapRect, zoom: zoom)
        while (tileRange.x.count > 10 || tileRange.y.count > 14), zoom > 3 {
            zoom -= 1
            tileRange = Self.tileRange(for: mapRect, zoom: zoom)
        }

        let tileMapSize = MKMapSize.world.width / pow(2.0, Double(zoom))
        let rect = MKMapRect(
            x: Double(tileRange.x.lowerBound) * tileMapSize,
            y: Double(tileRange.y.lowerBound) * tileMapSize,
            width: Double(tileRange.x.count) * tileMapSize,
            height: Double(tileRange.y.count) * tileMapSize
        )

        host = request.host
        source = request.source
        sourceZoom = zoom
        xRange = tileRange.x
        yRange = tileRange.y
        boundingMapRect = rect
        id = "\(request.host)|\(request.source)|z\(zoom)|x\(tileRange.x.lowerBound)-\(tileRange.x.upperBound)|y\(tileRange.y.lowerBound)-\(tileRange.y.upperBound)"
    }

    var imageSize: CGSize {
        CGSize(width: xRange.count * Self.tilePixelSize, height: yRange.count * Self.tilePixelSize)
    }

    func cacheKey(for frame: RainRadarFrame) -> String {
        "\(id)|\(frame.id)"
    }

    func url(for frame: RainRadarFrame, x: Int, y: Int) -> URL? {
        if case .dwdIconEu(let layerName) = frame.frameSource {
            return DwdIconForecastService.tileURL(layerName: layerName, time: frame.time,
                                                   x: x, y: y, zoom: sourceZoom)
        }
        switch source {
        case .dwd:
            return URL(string: "\(host)\(frame.path)/\(sourceZoom)/\(x)/\(y).png")
        case .rainViewer:
            return URL(string: "\(host)\(frame.path)/512/\(sourceZoom)/\(x)/\(y)/2/1_1.png")
        }
    }

    func drawRect(for x: Int, y: Int) -> CGRect {
        CGRect(
            x: (x - xRange.lowerBound) * Self.tilePixelSize,
            y: (y - yRange.lowerBound) * Self.tilePixelSize,
            width: Self.tilePixelSize,
            height: Self.tilePixelSize
        )
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

@MainActor
private final class RadarFrameCompositor {
    private let cache = NSCache<NSString, RadarCachedImage>()
    private var inFlight: [String: Task<CGImage, Error>] = [:]

    init() {
        cache.countLimit = 48
    }

    func image(for key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    func image(for frame: RainRadarFrame, context: RadarFrameRenderContext) async throws -> CGImage {
        let key = context.cacheKey(for: frame)
        if let cached = cache.object(forKey: key as NSString)?.image {
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }

        let task = Task<CGImage, Error> {
            try await Self.compose(frame: frame, context: context)
        }
        inFlight[key] = task

        do {
            let image = try await task.value
            cache.setObject(RadarCachedImage(image), forKey: key as NSString)
            inFlight[key] = nil
            return image
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func removeAllImages() {
        cache.removeAllObjects()
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
    }

    private static func compose(frame: RainRadarFrame, context: RadarFrameRenderContext) async throws -> CGImage {
        let tilePayloads = await loadTiles(frame: frame, context: context)
        let width = Int(context.imageSize.width)
        let height = Int(context.imageSize.height)
        guard let drawingContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw URLError(.cannotDecodeContentData)
        }

        drawingContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        drawingContext.translateBy(x: 0, y: CGFloat(height))
        drawingContext.scaleBy(x: 1, y: -1)
        for payload in tilePayloads {
            drawingContext.draw(payload.image, in: context.drawRect(for: payload.x, y: payload.y))
        }
        guard let image = drawingContext.makeImage() else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    private static func loadTiles(frame: RainRadarFrame, context: RadarFrameRenderContext) async -> [RadarTilePayload] {
        await withTaskGroup(of: RadarTilePayload?.self) { group in
            for x in context.xRange {
                for y in context.yRange {
                    guard let url = context.url(for: frame, x: x, y: y) else { continue }
                    group.addTask {
                        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
                        do {
                            let (data, response) = try await URLSession.shared.data(for: request)
                            guard (response as? HTTPURLResponse)?.statusCode == 200,
                                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                                return nil
                            }
                            return RadarTilePayload(x: x, y: y, image: image)
                        } catch {
                            return nil
                        }
                    }
                }
            }

            var payloads: [RadarTilePayload] = []
            for await payload in group {
                if let payload {
                    payloads.append(payload)
                }
            }
            return payloads
        }
    }
}

private final class RadarCachedImage {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}

private struct RadarTilePayload: Sendable {
    let x: Int
    let y: Int
    let image: CGImage
}

private final class RadarFrameImageOverlay: NSObject, MKOverlay {
    let image: CGImage
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    let targetAlpha: CGFloat

    init(image: CGImage, boundingMapRect: MKMapRect, targetAlpha: CGFloat) {
        self.image = image
        self.boundingMapRect = boundingMapRect
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.targetAlpha = targetAlpha
    }
}

private final class RadarFrameImageRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? RadarFrameImageOverlay else { return }
        let drawRect = rect(for: overlay.boundingMapRect)
        context.saveGState()
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(
            x: drawRect.width / CGFloat(overlay.image.width),
            y: -drawRect.height / CGFloat(overlay.image.height)
        )
        context.draw(
            overlay.image,
            in: CGRect(x: 0, y: 0, width: overlay.image.width, height: overlay.image.height)
        )
        context.restoreGState()
    }
}

private struct RadarRoundButton: View {
    let icon: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(selected ? Color(hex: "#5f4500") : .white.opacity(0.90))
                .frame(width: 58, height: 58)
                .background(selected ? Color(hex: "#ffd166") : Color.black.opacity(0.10))
                .background(.white.opacity(selected ? 0.0 : 0.13))
                .background(.ultraThinMaterial.opacity(0.74))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(.white.opacity(selected ? 0.54 : 0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }
}

private final class DwdWMSTileOverlay: MKTileOverlay {
    private let layer: DwdWMSLayer
    private let originShift = 20_037_508.342789244

    init(layer: DwdWMSLayer) {
        self.layer = layer
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
            URLQueryItem(name: "TIME", value: "current")
        ]
        return components.url!
    }

    private func webMercatorBBOX(for path: MKTileOverlayPath) -> String {
        let tiles = pow(2.0, Double(path.z))
        let tileMeters = originShift * 2.0 / tiles
        let minX = -originShift + Double(path.x) * tileMeters
        let maxX = minX + tileMeters
        let maxY = originShift - Double(path.y) * tileMeters
        let minY = maxY - tileMeters
        return "\(minX),\(minY),\(maxX),\(maxY)"
    }
}

private struct RainRadarTimelineControl: View {
    let frames: [RainRadarFrame]
    @Binding var selectedIndex: Int
    @Binding var isPlaying: Bool
    let selectedTimeLabel: String
    let selectedDateLabel: String
    let rangeLabel: String
    private let daySegments: [RadarTimelineDaySegment]
    private let forecastStartIndex: Int?
    private let iconEuStartIndex: Int?

    private var maxIndex: Int { max(frames.count - 1, 0) }

    init(
        frames: [RainRadarFrame],
        selectedIndex: Binding<Int>,
        isPlaying: Binding<Bool>,
        selectedTimeLabel: String,
        selectedDateLabel: String,
        rangeLabel: String
    ) {
        self.frames = frames
        _selectedIndex = selectedIndex
        _isPlaying = isPlaying
        self.selectedTimeLabel = selectedTimeLabel
        self.selectedDateLabel = selectedDateLabel
        self.rangeLabel = rangeLabel
        daySegments = Self.makeDaySegments(for: frames)
        forecastStartIndex = frames.firstIndex(where: \.isForecast)
        iconEuStartIndex = frames.firstIndex(where: {
            if case .dwdIconEu = $0.frameSource { return true }
            return false
        })
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: "#5f4500"))
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.84))
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(.white.opacity(0.58), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTimeLabel)
                        .font(.system(size: 20, weight: .bold))
                        .monospacedDigit()
                    Text(selectedDateLabel)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    Text(rangeLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(1)
                }

                Spacer()

                Text(activeFrameKind)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.16))
                    .background(.ultraThinMaterial.opacity(0.75))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.24), lineWidth: 1)
                    )
                    .lineLimit(1)
            }
            .foregroundStyle(.white)

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let progress = maxIndex == 0 ? 0 : CGFloat(selectedIndex) / CGFloat(maxIndex)
                let knobX = min(max(progress * width, 12), width - 12)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(.white.opacity(0.10))
                        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(.white.opacity(0.24), lineWidth: 1)
                        )
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 18)
                                .fill(.white.opacity(0.18))
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                                .padding(.top, 1)
                        }

                    ForEach(daySegments) { segment in
                        RoundedRectangle(cornerRadius: 14)
                            .fill(daySegmentColor(segment.ordinal).opacity(segment.containsSelectedIndex(selectedIndex) ? 0.26 : 0.15))
                            .frame(width: daySegmentWidth(segment, totalWidth: width), height: 32)
                            .position(x: daySegmentMidX(segment, totalWidth: width), y: 35)
                    }

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.20))
                            .frame(height: 7)

                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.88), .white.opacity(0.46)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: max(8, knobX), height: 7)
                    }
                    .padding(.horizontal, 12)
                    .offset(y: 20)

                    if let forecastStartIndex {
                        let forecastX = timelineX(for: forecastStartIndex, totalWidth: width)
                        Rectangle()
                            .fill(Color(hex: "#ffd166").opacity(0.88))
                            .frame(width: 2, height: 43)
                            .position(x: forecastX, y: 36)

                        Text("Prognose")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: "#5f4500"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(hex: "#ffd166").opacity(0.94))
                            .clipShape(Capsule())
                            .position(x: min(max(forecastX + 34, 42), width - 42), y: 49)
                    }

                    if let iconEuStartIndex {
                        let iconX = timelineX(for: iconEuStartIndex, totalWidth: width)
                        Rectangle()
                            .fill(Color(hex: "#9ee8c1").opacity(0.88))
                            .frame(width: 2, height: 43)
                            .position(x: iconX, y: 36)

                        Text("ICON-EU")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: "#1a4d35"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(hex: "#9ee8c1").opacity(0.94))
                            .clipShape(Capsule())
                            .position(x: min(max(iconX + 38, 46), width - 46), y: 49)
                    }

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(frames.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.white.opacity(index == selectedIndex ? 1 : 0.58))
                                    .frame(width: 2, height: tickHeight(for: index))
                                if shouldShowLabel(at: index) {
                                    Text(tickLabel(for: index))
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.74))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .offset(y: 2)

                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.22))
                            .background(.ultraThinMaterial, in: Circle())
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(.white.opacity(0.70), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 5)
                        Circle()
                            .fill(Color(hex: "#ffd166"))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(.white.opacity(0.90), lineWidth: 2)
                            )
                    }
                    .position(x: knobX, y: 23)

                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "#ffd166"), Color(hex: "#ffd166").opacity(0.18)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 2, height: 40)
                        .position(x: knobX, y: 45)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clampedX = min(max(value.location.x, 0), width)
                            let nextIndex = Int((clampedX / width * CGFloat(maxIndex)).rounded())
                            selectedIndex = min(max(nextIndex, 0), maxIndex)
                        }
                )
            }
            .frame(height: 62)

        }
        .padding(10)
        .background(.white.opacity(0.08))
        .background(.ultraThinMaterial.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.20), lineWidth: 1)
        )
    }

    private var activeFrameKind: String {
        guard frames.indices.contains(selectedIndex) else { return "Radar" }
        return frames[selectedIndex].isForecast ? "Prognose" : "Radar"
    }

    private static func makeDaySegments(for frames: [RainRadarFrame]) -> [RadarTimelineDaySegment] {
        guard !frames.isEmpty else { return [] }
        var segments: [RadarTimelineDaySegment] = []
        var startIndex = 0
        var ordinal = 0
        let calendar = Calendar.current

        for index in frames.indices.dropFirst() {
            if !calendar.isDate(frames[index].time, inSameDayAs: frames[startIndex].time) {
                segments.append(
                    RadarTimelineDaySegment(
                        startIndex: startIndex,
                        endIndex: index - 1,
                        date: frames[startIndex].time,
                        ordinal: ordinal
                    )
                )
                startIndex = index
                ordinal += 1
            }
        }

        segments.append(
            RadarTimelineDaySegment(
                startIndex: startIndex,
                endIndex: frames.count - 1,
                date: frames[startIndex].time,
                ordinal: ordinal
            )
        )
        return segments
    }

    private func tickHeight(for index: Int) -> CGFloat {
        if index == selectedIndex { return 22 }
        return shouldShowLabel(at: index) ? 17 : 10
    }

    private func shouldShowLabel(at index: Int) -> Bool {
        guard frames.count > 1 else { return true }
        if index == 0 || index == maxIndex { return true }
        if daySegments.contains(where: { $0.startIndex == index }) { return true }

        let date = frames[index].time
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        guard components.minute == 0, let hour = components.hour else { return false }
        return hour.isMultiple(of: frames.count > 36 ? 6 : 3)
    }

    private func tickLabel(for index: Int) -> String {
        guard frames.indices.contains(index) else { return "" }
        let date = frames[index].time
        if daySegments.contains(where: { $0.startIndex == index }) {
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits).locale(.init(identifier: "de_DE")))
        }
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
        }
        return date.formatted(.dateTime.day().month(.twoDigits).locale(.init(identifier: "de_DE")))
    }

    private func daySegmentWidth(_ segment: RadarTimelineDaySegment, totalWidth: CGFloat) -> CGFloat {
        let innerWidth = max(1, totalWidth - 24)
        guard maxIndex > 0 else { return innerWidth }
        let start = CGFloat(segment.startIndex) / CGFloat(maxIndex)
        let end = CGFloat(segment.endIndex) / CGFloat(maxIndex)
        return max(8, (end - start) * innerWidth)
    }

    private func daySegmentMidX(_ segment: RadarTimelineDaySegment, totalWidth: CGFloat) -> CGFloat {
        let innerWidth = max(1, totalWidth - 24)
        guard maxIndex > 0 else { return totalWidth / 2 }
        let start = CGFloat(segment.startIndex) / CGFloat(maxIndex)
        let end = CGFloat(segment.endIndex) / CGFloat(maxIndex)
        return 12 + ((start + end) / 2) * innerWidth
    }

    private func timelineX(for index: Int, totalWidth: CGFloat) -> CGFloat {
        let innerWidth = max(1, totalWidth - 24)
        guard maxIndex > 0 else { return totalWidth / 2 }
        return 12 + CGFloat(index) / CGFloat(maxIndex) * innerWidth
    }

    private func daySegmentColor(_ ordinal: Int) -> Color {
        let colors = [
            Color(hex: "#73c7ff"),
            Color(hex: "#9ee8c1"),
            Color(hex: "#ffd66b"),
            Color(hex: "#f4a3bf")
        ]
        return colors[ordinal % colors.count]
    }
}

private struct RadarTimelineDaySegment: Identifiable {
    let startIndex: Int
    let endIndex: Int
    let date: Date
    let ordinal: Int

    var id: String { "\(startIndex)-\(endIndex)-\(Int(date.timeIntervalSince1970))" }

    func containsSelectedIndex(_ index: Int) -> Bool {
        index >= startIndex && index <= endIndex
    }
}

private struct RadarPreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.midY - 26))
        path.addCurve(to: CGPoint(x: rect.midX - 2, y: rect.midY - 10),
                      control1: CGPoint(x: rect.minX + 26, y: rect.minY + 2),
                      control2: CGPoint(x: rect.midX - 18, y: rect.minY + 8))
        path.addCurve(to: CGPoint(x: rect.midX + 12, y: rect.midY + 30),
                      control1: CGPoint(x: rect.midX + 20, y: rect.midY + 2),
                      control2: CGPoint(x: rect.midX - 6, y: rect.midY + 20))
        path.addCurve(to: CGPoint(x: rect.maxX - 4, y: rect.midY + 6),
                      control1: CGPoint(x: rect.maxX - 8, y: rect.maxY - 8),
                      control2: CGPoint(x: rect.maxX - 12, y: rect.midY + 24))
        path.addCurve(to: CGPoint(x: rect.midX + 6, y: rect.midY - 4),
                      control1: CGPoint(x: rect.maxX - 22, y: rect.midY - 4),
                      control2: CGPoint(x: rect.midX + 24, y: rect.midY - 18))
        path.addCurve(to: CGPoint(x: rect.minX + 8, y: rect.midY - 26),
                      control1: CGPoint(x: rect.midX - 12, y: rect.midY + 8),
                      control2: CGPoint(x: rect.minX + 14, y: rect.midY - 6))
        return path
    }
}

private struct RadarGradient: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: Color(hex: "#00d5cc"), location: 0.0),
                .init(color: Color(hex: "#15b759"), location: 0.28),
                .init(color: Color(hex: "#f6de21"), location: 0.54),
                .init(color: Color(hex: "#ff8d18"), location: 0.75),
                .init(color: Color(hex: "#e32b24"), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
