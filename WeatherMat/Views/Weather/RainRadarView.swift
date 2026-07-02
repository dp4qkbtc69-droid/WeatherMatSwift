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
    @State private var store = RadarV2Store()
    @State private var mapRegion = rainRadarHomeRegion
    @State private var regionRevision = 0
    @State private var enabledLayers = Set<DwdWMSLayer>()
    @State private var showsLegend = false
    @State private var noticeText: String?

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
                userCoordinate: userCoordinate
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .tint(.white)
                        .padding(14)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                Spacer()
                timeline
            }

            controls
                .padding(.top, 64)
                .padding(.trailing, 16)

            if showsLegend {
                RadarLegendView(attribution: store.timeline?.attribution) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showsLegend = false
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 132)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                    // Wait until the next frame's tiles are warmed. Returns
                    // immediately once ready; the timeout only caps how long we
                    // hold for slow follow-up-day frames before advancing.
                    await RadarTileReadinessCenter.shared.waitUntilReady(nextFrame.id, timeoutNanoseconds: 1_200_000_000)
                }
                guard !Task.isCancelled else { return }
                store.advance()
            }
        }
        .statusBarHidden(false)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(.title3, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 1))
            .accessibilityLabel("Radar schließen")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("Radar")
                        .font(.system(.headline, weight: .bold))
                    Image(systemName: "location.fill")
                        .font(.system(.caption2, weight: .bold))
                        .opacity(0.9)
                    Text(location?.name ?? "Deutschland")
                        .font(.system(.footnote, weight: .semibold))
                        .opacity(0.9)
                        .lineLimit(1)
                }
                Text(store.selectedDateTimeLabel)
                    .font(.system(.caption, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.80)
            }

            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(Color.black.opacity(0.10))
        .background(.white.opacity(0.10))
        .background(.ultraThinMaterial.opacity(0.78))
        .overlay(alignment: .bottom) {
            Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            RadarRoundButton(icon: "location.fill", accessibilityLabel: "Zum aktuellen Ort springen") {
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
            RadarRoundButton(icon: "drop.fill", selected: true, accessibilityLabel: "Radar aktiv") {
                showNotice("Radar aktiv")
            }
            RadarRoundButton(icon: "bolt.fill", selected: enabledLayers.contains(.lightningDensity), accessibilityLabel: "Blitzdichte umschalten") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    toggleLayer(.lightningDensity)
                }
                showNotice(enabledLayers.contains(.lightningDensity) ? "DWD-Blitzdichte aktiv" : "DWD-Blitzdichte aus")
            }
            RadarRoundButton(icon: "info.circle.fill", selected: showsLegend, accessibilityLabel: "Legende umschalten") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showsLegend.toggle()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                            .foregroundStyle(Color(hex: "#5f4500"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color(hex: "#ffd166"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
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
                    kindLabel: store.selectedFrameKindLabel
                )
            } else {
                Text("Lade Radar...")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .background(.black.opacity(0.28))
        .background(.ultraThinMaterial.opacity(0.72))
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

    private func toggleLayer(_ layer: DwdWMSLayer) {
        if enabledLayers.contains(layer) {
            enabledLayers.remove(layer)
        } else {
            enabledLayers.insert(layer)
        }
    }
}
