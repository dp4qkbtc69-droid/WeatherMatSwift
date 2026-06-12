import SwiftUI
import MapKit

struct Where2GoView: View {
    @Environment(WeatherViewModel.self) private var vm
    @State private var selectedSpot: Where2GoSpot?

    var body: some View {
        @Bindable var vm = vm

        VStack(alignment: .leading, spacing: 14) {
            header

            Picker("Zeitfenster", selection: $vm.where2GoWindow) {
                ForEach(Where2GoWindow.allCases) { window in
                    Label(window.label, systemImage: window.icon).tag(window)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.where2GoWindow) { _, _ in vm.refreshWhere2Go() }

            radiusControl

            sortControl

            scoreLegend

            if vm.isLoadingWhere2Go {
                loadingRows
            } else if let error = vm.where2GoError {
                errorRow(error)
            } else if vm.where2GoSpots.isEmpty {
                emptyRow
            } else {
                VStack(spacing: 10) {
                    ForEach(vm.where2GoSpots) { spot in
                        Button {
                            selectedSpot = spot
                            HapticService.impact(.light)
                        } label: {
                            spotRow(spot)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.11))
        .background(.ultraThinMaterial.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .task {
            vm.loadWhere2GoIfNeeded()
        }
        .sheet(item: $selectedSpot) { spot in
            Where2GoMapSheet(origin: vm.activeLocation, spot: spot)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            VStack(alignment: .leading, spacing: 2) {
                Text("Wohin?")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Beste Sonne im Umkreis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }

            Spacer()

            Button {
                vm.refreshWhere2Go(force: true)
                HapticService.impact(.light)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.82))
            .background(.white.opacity(0.12))
            .clipShape(Circle())
            .accessibilityLabel("Wohin aktualisieren")
        }
    }

    private var radiusControl: some View {
        @Bindable var vm = vm

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Radius", systemImage: "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("\(vm.where2GoRadiusKm) km")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }

            Slider(
                value: Binding(
                    get: { Double(vm.where2GoRadiusKm) },
                    set: { vm.where2GoRadiusKm = Int(($0 / 25).rounded() * 25) }
                ),
                in: 50...300,
                step: 25
            ) {
                Text("Radius")
            }
            .tint(.white)
            .onChange(of: vm.where2GoRadiusKm) { _, _ in vm.refreshWhere2Go() }
        }
    }

    private var sortControl: some View {
        @Bindable var vm = vm

        return Picker("Sortierung", selection: $vm.where2GoSortMode) {
            ForEach(Where2GoSortMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: vm.where2GoSortMode) { _, _ in vm.refreshWhere2Go(debounce: false) }
    }

    private var scoreLegend: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .padding(.top, 1)
            Text("Score bewertet Sonne, Regen, Wind und Temperatur. „Beste“ zeigt den stärksten Wettertreffer zuerst, „Nächste“ sortiert dieselben Top-Ziele nach Entfernung.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var loadingRows: some View {
        VStack(spacing: 10) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.white.opacity(0.18))
                        .frame(height: 46)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var emptyRow: some View {
        Text("Noch keine Ziele berechnet.")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.white.opacity(0.75))
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private func spotRow(_ spot: Where2GoSpot) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(scoreColor(spot.score).opacity(0.28))
                VStack(spacing: 1) {
                    Text("\(spot.score)")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Score")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.66))
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: spot.condition.sfSymbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(spot.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text("\(spot.dateLabel) · \(spot.direction) · \(spot.distanceKm) km · \(String(format: "%.1f h Sonne", spot.sunshineHours))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))

                HStack(spacing: 10) {
                    metric("sun.max.fill", String(format: "%.1f h", spot.sunshineHours))
                    metric("drop.fill", "\(spot.precipitationProbability)%")
                    metric("thermometer.medium", "\(spot.temperature)°")
                    metric("wind", "\(spot.windSpeed)")
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.08))
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    private func metric(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(value)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.68))
    }

    private func scoreColor(_ score: Int) -> Color {
        switch score {
        case 80...100: return Color(hex: "#69d48f")
        case 62..<80:  return Color(hex: "#f5d76e")
        default:       return Color(hex: "#f08a68")
        }
    }
}

private struct Where2GoMapSheet: View {
    let origin: SavedLocation?
    let spot: Where2GoSpot

    @Environment(\.dismiss) private var dismiss

    private var mapRegion: MKCoordinateRegion {
        guard let origin else {
            return MKCoordinateRegion(
                center: spot.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2)
            )
        }

        let originCoordinate = CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
        let center = CLLocationCoordinate2D(
            latitude: (originCoordinate.latitude + spot.coordinate.latitude) / 2,
            longitude: (originCoordinate.longitude + spot.coordinate.longitude) / 2
        )
        let latDelta = max(abs(originCoordinate.latitude - spot.coordinate.latitude) * 1.7, 0.8)
        let lonDelta = max(abs(originCoordinate.longitude - spot.coordinate.longitude) * 1.7, 0.8)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: min(latDelta, 8), longitudeDelta: min(lonDelta, 8))
        )
    }

    var body: some View {
        NavigationStack {
            Map(initialPosition: .region(mapRegion)) {
                if let origin {
                    Marker(
                        origin.name,
                        systemImage: "location.fill",
                        coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)
                    )
                    .tint(.blue)
                }

                Marker(
                    spot.name,
                    systemImage: "sun.max.fill",
                    coordinate: spot.coordinate
                )
                .tint(.orange)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(spot.name)
                                .font(.system(size: 18, weight: .semibold))
                            Text("\(spot.direction) · \(spot.distanceKm) km · \(spot.dateLabel) · \(String(format: "%.1f h Sonne", spot.sunshineHours))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(spacing: 1) {
                            Text("\(spot.score)")
                                .font(.system(size: 20, weight: .bold))
                            Text("Score")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        mapMetric("sun.max.fill", String(format: "%.1f h Sonne", spot.sunshineHours))
                        mapMetric("drop.fill", "\(spot.precipitationProbability)% Regen")
                        mapMetric("thermometer.medium", "\(spot.temperature)°")
                        mapMetric("wind", "\(spot.windSpeed) km/h")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                }
                .padding(16)
                .background(.regularMaterial)
            }
            .navigationTitle("Wohin?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
    }

    private func mapMetric(_ icon: String, _ value: String) -> some View {
        Label(value, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}
