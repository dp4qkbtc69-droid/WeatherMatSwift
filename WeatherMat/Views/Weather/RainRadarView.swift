// RainRadarView.swift
import SwiftUI
import MapKit

private let rainRadarHomeRegion = MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: 51.1, longitude: 10.4),
    span: MKCoordinateSpan(latitudeDelta: 8.5, longitudeDelta: 11.0)
)

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
                        .font(.system(.callout, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(.subheadline, weight: .bold))
                }
                .foregroundStyle(.white)

                HStack(alignment: .bottom, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(location?.name ?? "Aktueller Ort")
                            .font(.system(.title2, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(rain.text.isEmpty ? "Radar und Zugrichtung ansehen" : rain.text)
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(.white.opacity(0.80))
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
                            .font(.system(.headline, weight: .bold))
                            .foregroundStyle(Color(hex: "#2f4fa7"))
                            .offset(x: 24, y: 18)
                    }
                    .frame(width: 118, height: 82)
                    .clipped()
                }
            }
            .padding(16)
            .glassCard()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Regenradar öffnen")
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

struct RainRadarScreen: View {
    let location: SavedLocation?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = RadarV2Store()
    @State private var mapRegion = rainRadarHomeRegion
    @State private var regionRevision = 0
    @State private var enabledLayers: Set<DwdWMSLayer> = [.lightningDensity]
    @State private var showsLegend = false
    @State private var noticeText: String?
    // Chrome visibility state: header + rail hide after inactivity during
    // playback; the timeline stays as a semi-transparent anchor.
    @State private var chromeHidden = false
    @State private var chromeHideTask: Task<Void, Never>?

    /// Initial radar view: ~65 km around the location, so the most relevant
    /// tiles load first. The wider map fills in as the user zooms/pans out.
    private static let localSpanMeters: CLLocationDistance = 130_000

    init(location: SavedLocation?) {
        self.location = location
        _mapRegion = State(initialValue: Self.initialRegion(for: location))
    }

    private static func initialRegion(for location: SavedLocation?) -> MKCoordinateRegion {
        guard let location else { return rainRadarHomeRegion }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
            latitudinalMeters: localSpanMeters,
            longitudinalMeters: localSpanMeters
        )
    }

    private var userCoordinate: CLLocationCoordinate2D? {
        guard let location else { return nil }
        return CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
    }

    var body: some View {
        ZStack(alignment: .top) {
            RadarV2MapView(
                region: mapRegion,
                regionRevision: regionRevision,
                request: store.renderRequest,
                enabledLayers: enabledLayers,
                timelineFrame: store.selectedFrame,
                isPlaying: store.isPlaying,
                userCoordinate: userCoordinate,
                onUserInteraction: { registerInteraction() }
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
                Spacer()
                // Legend docks directly above the timeline instead of
                // floating over the map.
                VStack(spacing: 8) {
                    if showsLegend {
                        RadarLegendView(
                            attribution: store.timeline?.attribution,
                            isFallbackSource: store.timeline?.source == .rainViewer
                        ) {
                            withRadarAnimation(.quick) {
                                showsLegend = false
                            }
                            registerInteraction()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    timeline
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
                .opacity(chromeHidden ? 0.72 : 1)
            }

            controls
                .padding(.top, 58)
                .padding(.trailing, 12)
                .opacity(chromeHidden ? 0 : 1)
                .allowsHitTesting(!chromeHidden)

            // Persistent time anchor: appears exactly when the header hides
            // during playback, so you always know which time is on screen.
            // Its own glass keeps it legible over any part of the map; taps
            // pass through so touching it still brings the chrome back.
            if chromeHidden {
                Text(store.compactWhenLabel)
                    .font(.system(.footnote, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.45))
                    .background(.ultraThinMaterial.opacity(0.7))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let noticeText {
                Text(noticeText)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.38))
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .task { await store.load() }
        .task(id: location?.id) {
            guard let location else { return }
            await RainRadarService.warmLocation(latitude: location.latitude, longitude: location.longitude)
        }
        .task(id: store.isPlaying) {
            guard store.isPlaying else { return }
            while store.isPlaying {
                try? await Task.sleep(nanoseconds: store.nextPlaybackDelayNanoseconds)
                guard !Task.isCancelled else { return }
                if let nextFrame = store.nextPlaybackFrame {
                    // Motion spec: hold/stall on unready frames rather than
                    // jumping to empty tiles. First a quiet wait, then a
                    // visible buffering hold, then advance regardless so a
                    // broken frame can never freeze playback entirely.
                    let ready = await RadarTileReadinessCenter.shared.waitUntilReady(
                        nextFrame.id, timeoutNanoseconds: 1_200_000_000
                    )
                    if !ready, !Task.isCancelled, store.isPlaying {
                        store.isBuffering = true
                        await RadarTileReadinessCenter.shared.waitUntilReady(
                            nextFrame.id, timeoutNanoseconds: 1_800_000_000
                        )
                        store.isBuffering = false
                    }
                }
                guard !Task.isCancelled else { return }
                store.advance()
            }
            store.isBuffering = false
        }
        .onChange(of: store.isPlaying) { _, playing in
            if playing {
                scheduleChromeHide()
            } else {
                showChrome()
            }
        }
        .onChange(of: showsLegend) { _, open in
            // Legend keeps chrome visible while open.
            if open { showChrome() }
        }
        .onDisappear {
            chromeHideTask?.cancel()
        }
        .statusBarHidden(false)
    }

    // MARK: - Chrome visibility states
    // Playback mode: map maximal, chrome reduced after 3 s inactivity.
    // Inspect mode: any tap/pan/zoom brings everything back.
    // Legend/error/loading: no auto-hide.

    private func registerInteraction() {
        showChrome()
    }

    private func showChrome() {
        chromeHideTask?.cancel()
        if chromeHidden {
            withRadarAnimation(.reveal) {
                chromeHidden = false
            }
        }
        if store.isPlaying {
            scheduleChromeHide()
        }
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: DesignTokens.Motion.chromeIdleDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard store.isPlaying,
                  !showsLegend,
                  store.errorMessage == nil,
                  !store.isLoading else { return }
            withRadarAnimation(.hide) {
                chromeHidden = true
            }
        }
    }

    private enum RadarAnimationKind {
        case quick
        case reveal
        case hide
        case map

        var duration: Double {
            switch self {
            case .quick: return DesignTokens.Motion.quick
            case .reveal: return DesignTokens.Motion.chromeReveal
            case .hide: return DesignTokens.Motion.chromeHide
            case .map: return DesignTokens.Motion.standard
            }
        }
    }

    private func withRadarAnimation(_ kind: RadarAnimationKind, _ changes: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: kind.duration), changes)
    }

    // Single-line instrument header: back · title/location · time.
    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.subheadline, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.10), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
            .accessibilityLabel("Radar schließen")

            RadarHeaderTitle(locationName: location?.name ?? "Deutschland")
                .frame(maxWidth: 172, alignment: .leading)
                .layoutPriority(0)

            Spacer(minLength: 4)

            Text(store.selectedDateTimeLabel)
                .font(.system(.caption, weight: .semibold))
                .monospacedDigit()
                .opacity(0.85)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minWidth: 132, alignment: .trailing)
                .layoutPriority(3)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(AppColors.Surface.instrumentDark)
        .background(.ultraThinMaterial.opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppColors.Stroke.faint).frame(height: 1)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            RadarRoundButton(icon: "location.fill", accessibilityLabel: "Zum aktuellen Ort springen") {
                guard let userCoordinate else {
                    showNotice("Kein Ort verfügbar")
                    return
                }
                withRadarAnimation(.map) {
                    mapRegion = MKCoordinateRegion(
                        center: userCoordinate,
                        latitudinalMeters: Self.localSpanMeters,
                        longitudinalMeters: Self.localSpanMeters
                    )
                    regionRevision += 1
                }
            }
            RadarRoundButton(icon: "drop.fill", selected: true, accessibilityLabel: "Radar aktiv") {
                showNotice("Radar aktiv")
            }
            RadarRoundButton(icon: "bolt.fill", selected: enabledLayers.contains(.lightningDensity), accessibilityLabel: "Blitzdichte umschalten") {
                withRadarAnimation(.quick) {
                    toggleLayer(.lightningDensity)
                }
                showNotice(enabledLayers.contains(.lightningDensity) ? "DWD-Blitzdichte aktiv" : "DWD-Blitzdichte aus")
            }
            RadarRoundButton(icon: "info.circle.fill", selected: showsLegend, accessibilityLabel: "Legende umschalten") {
                withRadarAnimation(.quick) {
                    showsLegend.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Rail taps count as interaction — keeps chrome visible during playback.
        .simultaneousGesture(TapGesture().onEnded { registerInteraction() })
    }

    @ViewBuilder
    private var timeline: some View {
        if let error = store.errorMessage {
            HStack(spacing: 12) {
                Text(error)
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    Task { await store.retry() }
                } label: {
                    Text("Erneut versuchen")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppColors.selectionText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(AppColors.selection)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .instrumentPanel()
        } else if !store.visibleFrames.isEmpty {
            RadarTimelineControl(
                frames: store.visibleFrames,
                selectedIndex: Binding(
                    get: { store.selectedIndex },
                    set: {
                        store.isPlaying = false
                        store.selectedIndex = $0
                    }
                ),
                isPlaying: Binding(
                    get: { store.isPlaying },
                    set: { store.isPlaying = $0 }
                ),
                selectedTimeLabel: store.selectedTimeLabel,
                selectedDateLabel: store.selectedDateLabel,
                kindLabel: store.selectedFrameKindLabel,
                isBuffering: store.isBuffering
            )
        } else {
            // Loading state lives in the timeline slot — no big spinner
            // covering the map.
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                Text("Lade Radar…")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .instrumentPanel()
        }
    }

    private func showNotice(_ text: String) {
        withRadarAnimation(.quick) {
            noticeText = text
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if noticeText == text {
                withRadarAnimation(.quick) {
                    noticeText = nil
                }
            }
        }
    }

    private func toggleLayer(_ layer: DwdWMSLayer) {
        if enabledLayers.contains(layer) {
            enabledLayers.remove(layer)
        } else {
            enabledLayers.insert(layer)
        }
    }
}

private struct RadarHeaderTitle: View {
    let locationName: String

    var body: some View {
        HStack(spacing: 0) {
            MarqueeText(locationName)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.90))
        }
    }
}

private struct MarqueeText: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var animate = false

    init(_ text: String) {
        self.text = text
    }

    private var shouldScroll: Bool {
        textWidth > containerWidth + 4 && !reduceMotion
    }

    private var travelDistance: CGFloat {
        max(0, textWidth - containerWidth + 28)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            HStack(spacing: 28) {
                measuredText
                if shouldScroll {
                    measuredText
                }
            }
            .offset(x: shouldScroll && animate ? -travelDistance : 0)
            .animation(
                shouldScroll ? .linear(duration: max(5.5, Double(text.count) * 0.18)).repeatForever(autoreverses: false) : nil,
                value: animate
            )
            .frame(width: width, alignment: .leading)
            .clipped()
            .onAppear {
                containerWidth = width
                animate = shouldScroll
            }
            .onChange(of: width) { _, newValue in
                containerWidth = newValue
                animate = shouldScroll
            }
            .onChange(of: textWidth) { _, _ in
                animate = shouldScroll
            }
        }
        .frame(height: 22)
    }

    private var measuredText: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { textWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            textWidth = newValue
                        }
                }
            )
    }
}
