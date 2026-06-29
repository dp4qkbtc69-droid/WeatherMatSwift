// RainRadarView.swift
import SwiftUI
import MapKit
import UIKit

private let rainRadarHomeRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.1, longitude: 10.4),
    span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 11.0)
)

private enum DwdWMSLayer: String, Identifiable {
    case lightningDensity = "Blitzdichte"

    var id: String { rawValue }

    var style: String { "blitzdichte" }
}

private enum RainRadarRange: String, CaseIterable, Identifiable {
    case day = "-24h"
    case radar = "-2h/+2h"
    case twoDays = "+48h"
    case week = "+7d"

    var id: String { rawValue }

    var isRadarAvailable: Bool {
        switch self {
        case .day, .radar: return true
        case .twoDays, .week: return false
        }
    }
}

@MainActor
@Observable
private final class RainRadarViewModel {
    var timeline: RainRadarTimeline?
    var selectedIndex = 0
    var isPlaying = false
    var isLoading = false
    var errorMessage: String?
    var selectedRange: RainRadarRange = .radar

    var selectedFrame: RainRadarFrame? {
        let frames = visibleFrames
        guard !frames.isEmpty else { return nil }
        return frames[min(selectedIndex, frames.count - 1)]
    }

    var visibleFrames: [RainRadarFrame] {
        guard let frames = timeline?.frames, !frames.isEmpty else { return [] }
        guard let latestObserved = timeline?.latestObservedFrame else { return frames }
        switch selectedRange {
        case .day:
            let cutoff = latestObserved.time.addingTimeInterval(-24 * 60 * 60)
            return frames.filter { $0.time >= cutoff && $0.time <= latestObserved.time }
        case .radar:
            let cutoff = latestObserved.time.addingTimeInterval(-2 * 60 * 60)
            return frames.filter { $0.time >= cutoff }
        case .twoDays, .week:
            return frames.filter { $0.time >= latestObserved.time }
        }
    }

    var selectedTimeLabel: String {
        guard let selectedFrame else { return "--:--" }
        return selectedFrame.time.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
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
        } catch {
            errorMessage = "Radar konnte nicht geladen werden."
        }
        isLoading = false
    }

    func advanceFrame() {
        let frames = visibleFrames
        guard !frames.isEmpty else { return }
        selectedIndex = selectedIndex >= frames.count - 1 ? 0 : selectedIndex + 1
    }

    func selectRange(_ range: RainRadarRange) {
        guard range.isRadarAvailable else { return }
        selectedRange = range
        let frames = visibleFrames
        guard !frames.isEmpty else {
            selectedIndex = 0
            return
        }
        if let latest = timeline?.latestObservedFrame,
           let latestIndex = frames.firstIndex(of: latest) {
            selectedIndex = latestIndex
        } else {
            selectedIndex = min(selectedIndex, frames.count - 1)
        }
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
                .padding(.top, 150)
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
                    .padding(.top, 152)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await viewModel.load() }
        .task(id: viewModel.isPlaying) {
            guard viewModel.isPlaying else { return }
            while viewModel.isPlaying {
                try? await Task.sleep(nanoseconds: 720_000_000)
                guard !Task.isCancelled else { return }
                viewModel.advanceFrame()
            }
        }
        .statusBarHidden(false)
    }

    private var header: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Niederschlag")
                        .font(.system(size: 30, weight: .bold))
                    Text(dateLine)
                        .font(.system(size: 19, weight: .medium))
                        .monospacedDigit()
                        .opacity(0.88)
                }

                Spacer()

                Image(systemName: "ellipsis")
                    .font(.system(size: 26, weight: .bold))
                    .frame(width: 44, height: 44)
            }
            .padding(.horizontal, 18)
            .padding(.top, 46)
        }
        .foregroundStyle(.white)
        .padding(.bottom, 18)
        .background(Color(hex: "#304f9f"))
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
                showNotice("Niederschlag aktiv")
            }
            RadarRoundButton(icon: "bolt.fill", selected: dwdLayers.contains(.lightningDensity)) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggleDwdLayer(.lightningDensity)
                }
                showNotice(dwdLayers.contains(.lightningDensity) ? "DWD-Blitzdichte aktiv" : "DWD-Blitzdichte aus")
            }
            RadarRoundButton(icon: "house.fill") {
                withAnimation(.easeInOut(duration: 0.25)) {
                    mapRegion = rainRadarHomeRegion
                    regionRevision += 1
                }
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
                RainRadarRangePicker(
                    selectedRange: Binding(
                        get: { viewModel.selectedRange },
                        set: { viewModel.selectRange($0) }
                    )
                )

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
                    selectedTimeLabel: viewModel.selectedTimeLabel
                )

                Text(viewModel.selectedFrame?.isForecast == true ? "Nowcast" : "Aktuell")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))

                Text("Radar: \(viewModel.timeline?.attribution ?? "Radarquelle")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.66))
            } else {
                Text("Lade Radar...")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
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

        if let host, let frame {
            let layerID = "\(host)\(frame.path)"
            if context.coordinator.currentLayerID != layerID {
                let overlay: MKTileOverlay = source == .dwd
                    ? DwdRadarTileOverlay(host: host, framePath: frame.path, sourceMaxZoom: tileMaxZoom ?? 8)
                    : ClampedRainTileOverlay(host: host, framePath: frame.path)
                overlay.canReplaceMapContent = false
                overlay.minimumZ = 3
                overlay.maximumZ = 22
                context.coordinator.replaceRadarOverlay(with: overlay, id: layerID, in: mapView)
            }
        }

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

        mapView.removeAnnotations(mapView.annotations)
        if let userCoordinate {
            let pin = MKPointAnnotation()
            pin.coordinate = userCoordinate
            pin.title = "Dein Ort"
            mapView.addAnnotation(pin)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var radarOverlay: MKTileOverlay?
        var dwdOverlays: [String: MKTileOverlay] = [:]
        var currentLayerID: String?
        var lastAppliedRegionRevision = 0

        func replaceRadarOverlay(with overlay: MKTileOverlay, id: String, in mapView: MKMapView) {
            let oldOverlay = radarOverlay
            radarOverlay = overlay
            currentLayerID = id
            mapView.addOverlay(overlay, level: .aboveLabels)
            if let oldOverlay {
                mapView.removeOverlay(oldOverlay)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: tileOverlay)
                renderer.alpha = tileOverlay is DwdWMSTileOverlay ? 0.74 : 0.82
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            let identifier = "RadarLocation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = UIColor(Color(hex: "#304f9f"))
                marker.glyphImage = UIImage(systemName: "location.fill")
            }
            return view
        }

        func regionApproximatelyMatches(_ lhs: MKCoordinateRegion, _ rhs: MKCoordinateRegion) -> Bool {
            abs(lhs.center.latitude - rhs.center.latitude) < 0.2 &&
            abs(lhs.center.longitude - rhs.center.longitude) < 0.2 &&
            abs(lhs.span.latitudeDelta - rhs.span.latitudeDelta) < 0.4 &&
            abs(lhs.span.longitudeDelta - rhs.span.longitudeDelta) < 0.4
        }
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
                .foregroundStyle(selected ? .white : Color(hex: "#566073"))
                .frame(width: 58, height: 58)
                .background(selected ? Color(hex: "#304f9f") : Color.white.opacity(0.96))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
    }
}

private final class ClampedRainTileOverlay: MKTileOverlay {
    private let host: String
    private let framePath: String
    private let sourceMaxZoom = 9

    init(host: String, framePath: String) {
        self.host = host
        self.framePath = framePath
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        sourceURL(for: path)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let handler = TileResultHandler(result)
        let url = sourceURL(for: path)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        let maxZoom = sourceMaxZoom
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data else {
                handler.finish(data: nil, error: error)
                return
            }
            guard path.z > maxZoom,
                  let image = UIImage(data: data),
                  let cropped = Self.croppedTileData(from: image, path: path, sourceMaxZoom: maxZoom)
            else {
                handler.finish(data: data, error: nil)
                return
            }
            handler.finish(data: cropped, error: nil)
        }.resume()
    }

    private func sourceURL(for path: MKTileOverlayPath) -> URL {
        let delta = max(0, path.z - sourceMaxZoom)
        let sourceZ = min(path.z, sourceMaxZoom)
        let sourceX = delta == 0 ? path.x : path.x >> delta
        let sourceY = delta == 0 ? path.y : path.y >> delta
        return URL(string: "\(host)\(framePath)/512/\(sourceZ)/\(sourceX)/\(sourceY)/2/1_1.png")!
    }

    fileprivate static func croppedTileData(from image: UIImage, path: MKTileOverlayPath, sourceMaxZoom: Int) -> Data? {
        let delta = path.z - sourceMaxZoom
        guard delta > 0 else { return image.pngData() }

        let divisions = CGFloat(1 << min(delta, 12))
        let sourceSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let cropWidth = sourceSize.width / divisions
        let cropHeight = sourceSize.height / divisions
        let localX = CGFloat(path.x & ((1 << min(delta, 12)) - 1))
        let localY = CGFloat(path.y & ((1 << min(delta, 12)) - 1))
        let cropRect = CGRect(x: localX * cropWidth, y: localY * cropHeight, width: cropWidth, height: cropHeight)

        guard let cgImage = image.cgImage?.cropping(to: cropRect) else { return image.pngData() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        return rendered.pngData()
    }
}

private final class DwdRadarTileOverlay: MKTileOverlay {
    private let host: String
    private let framePath: String
    private let sourceMaxZoom: Int

    init(host: String, framePath: String, sourceMaxZoom: Int) {
        self.host = host
        self.framePath = framePath
        self.sourceMaxZoom = sourceMaxZoom
        super.init(urlTemplate: nil)
        tileSize = CGSize(width: 512, height: 512)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        sourceURL(for: path)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let handler = TileResultHandler(result)
        let url = sourceURL(for: path)
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        let maxZoom = sourceMaxZoom
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let data else {
                handler.finish(data: Self.emptyTileData(), error: nil)
                return
            }
            guard path.z > maxZoom,
                  let image = UIImage(data: data),
                  let cropped = ClampedRainTileOverlay.croppedTileData(from: image, path: path, sourceMaxZoom: maxZoom)
            else {
                handler.finish(data: data, error: nil)
                return
            }
            handler.finish(data: cropped, error: nil)
        }.resume()
    }

    private func sourceURL(for path: MKTileOverlayPath) -> URL {
        let delta = max(0, path.z - sourceMaxZoom)
        let sourceZ = min(path.z, sourceMaxZoom)
        let sourceX = delta == 0 ? path.x : path.x >> delta
        let sourceY = delta == 0 ? path.y : path.y >> delta
        return URL(string: "\(host)\(framePath)/\(sourceZ)/\(sourceX)/\(sourceY).png")!
    }

    private static func emptyTileData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { _ in }
        return image.pngData() ?? Data()
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

private final class TileResultHandler: @unchecked Sendable {
    private let result: (Data?, (any Error)?) -> Void

    init(_ result: @escaping (Data?, (any Error)?) -> Void) {
        self.result = result
    }

    func finish(data: Data?, error: (any Error)?) {
        result(data, error)
    }
}

private struct RainRadarRangePicker: View {
    @Binding var selectedRange: RainRadarRange

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RainRadarRange.allCases) { range in
                Button {
                    selectedRange = range
                } label: {
                    Text(range.rawValue)
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(rangeForeground(range))
                        .frame(minWidth: 64)
                        .padding(.vertical, 9)
                        .background(rangeBackground(range))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!range.isRadarAvailable)
            }
        }
    }

    private func rangeForeground(_ range: RainRadarRange) -> Color {
        if !range.isRadarAvailable { return .white.opacity(0.46) }
        return selectedRange == range ? Color(hex: "#304f9f") : .white
    }

    private func rangeBackground(_ range: RainRadarRange) -> Color {
        if !range.isRadarAvailable { return .black.opacity(0.18) }
        return selectedRange == range ? .white.opacity(0.94) : .white.opacity(0.16)
    }
}

private struct RainRadarTimelineControl: View {
    let frames: [RainRadarFrame]
    @Binding var selectedIndex: Int
    @Binding var isPlaying: Bool
    let selectedTimeLabel: String

    private var maxIndex: Int { max(frames.count - 1, 0) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color(hex: "#304f9f"))
                        .frame(width: 44, height: 38)
                        .background(.white.opacity(0.96))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)

                Text(selectedTimeLabel)
                    .font(.system(size: 18, weight: .bold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color(hex: "#304f9f"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Spacer()
                Text("\(relativeLabel(for: frames.first?.time)) / \(relativeLabel(for: frames.last?.time))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .monospacedDigit()

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let progress = maxIndex == 0 ? 0 : CGFloat(selectedIndex) / CGFloat(maxIndex)
                let knobX = min(max(progress * width, 10), width - 10)

                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.62))
                        .frame(height: 2)
                        .offset(y: 17)

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(frames.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                Rectangle()
                                    .fill(.white.opacity(index == selectedIndex ? 0.98 : 0.72))
                                    .frame(width: 2, height: index % 3 == 0 ? 22 : 13)
                                if index % 3 == 0 {
                                    Text(frames[index].time.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE"))))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.86))
                                        .monospacedDigit()
                                        .fixedSize()
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Circle()
                        .fill(Color(hex: "#304f9f"))
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 22, height: 22)
                        .position(x: knobX, y: 18)

                    Rectangle()
                        .fill(Color(hex: "#304f9f"))
                        .frame(width: 3, height: 60)
                        .position(x: knobX, y: 42)
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
            .frame(height: 70)
        }
    }

    private func relativeLabel(for date: Date?) -> String {
        guard let date else { return "--" }
        let seconds = date.timeIntervalSinceNow
        if abs(seconds) < 90 { return "Jetzt" }
        let minutes = Int((seconds / 60).rounded())
        if abs(minutes) < 60 {
            return minutes > 0 ? "+\(minutes)m" : "\(minutes)m"
        }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours > 0 ? "+\(hours)h" : "\(hours)h"
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
