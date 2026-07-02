// LocationsView.swift
import SwiftUI

struct LocationsView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    @State private var searchText  = ""
    @State private var results:    [GeocodedLocation] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var searchID = UUID()
    @State private var isReordering = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Consistent dark-sky gradient matching the app's night tone
                LinearGradient(
                    colors: [Color(hex: "#1a2540"), Color(hex: "#0a0f1e")],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if isReordering {
                        reorderList
                    } else {
                        SearchBar(text: $searchText)
                            .padding(.horizontal)
                            .padding(.top, 8)
                            .padding(.bottom, 14)
                            .onChange(of: searchText) { _, newVal in
                                scheduleSearch(newVal)
                            }
                    }

                    if isReordering {
                        EmptyView()
                    } else if isSearching {
                        ProgressView()
                            .tint(.white)
                            .padding(.top, 40)
                        Spacer()
                    } else if !searchText.isEmpty && results.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46))
                            Text("Keine Ergebnisse")
                                .font(.system(.body, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))
                            Text("Prüfe die Schreibweise oder suche nach einer größeren Stadt in der Nähe.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.64))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 36)
                        }
                        .padding(.top, 42)
                        Spacer()
                    } else if !results.isEmpty {
                        searchResultsList
                    } else {
                        mainScrollContent
                    }
                }
            }
            .navigationTitle("Orte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Schließen") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Task { await vm.useGPSLocation(); dismiss() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                            Text("GPS")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.cyan)
                    }
                    .disabled(isReordering)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if vm.savedLocations.count > 1 {
                        Button(isReordering ? "Fertig" : "Sortieren") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isReordering.toggle()
                                searchText = ""
                                results = []
                                isSearching = false
                                searchTask?.cancel()
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private var reorderList: some View {
        List {
            ForEach(vm.savedLocations) { loc in
                HStack(spacing: 12) {
                    Image(systemName: loc.isGPS ? "location.fill" : "mappin.circle.fill")
                        .font(.system(.headline, weight: .semibold))
                        .foregroundStyle(loc.id == vm.activeLocation?.id ? .cyan : .white.opacity(0.58))
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(loc.name)
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(.white)
                        if !loc.subtitle.isEmpty {
                            Text(loc.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.62))
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.white.opacity(0.08))
                .moveDisabled(loc.isGPS)
            }
            .onMove { source, destination in
                vm.moveLocations(from: source, to: destination)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .listStyle(.plain)
    }

    // MARK: - Main scroll content (locations + settings)
    private var mainScrollContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 16) {
                // Saved locations
                if vm.savedLocations.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(vm.savedLocations.enumerated()), id: \.element.id) { i, loc in
                            LocationCardView(loc: loc, isActive: i == vm.activeLocationIndex)
                                .onTapGesture {
                                    HapticService.impact(.light)
                                    vm.switchLocation(to: i)
                                    dismiss()
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        vm.removeLocation(at: i)
                                    } label: {
                                        Label("Entfernen", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                // Settings section
                SettingsSectionView()
            }
            .padding(.horizontal)
            .padding(.bottom, 110)
        }
    }

    // MARK: - Search results
    private var searchResultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                ForEach(results) { result in
                    Button { addResult(result) } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(.white.opacity(0.12))
                                    .frame(width: 38, height: 38)
                                Image(systemName: "mappin.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.name)
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(.white)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.cyan.opacity(0.8))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.08))
                        .background(.ultraThinMaterial.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 110)
        }
    }

    // MARK: - Empty state
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 48))
                .foregroundStyle(.white.opacity(0.25))
            Text("Noch keine Orte gespeichert")
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
            Text("Suche nach einer Stadt oder nutze GPS")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.64))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Actions
    private func scheduleSearch(_ query: String) {
        searchTask?.cancel()
        let id = UUID()
        searchID = id
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            isSearching = false
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms debounce
            guard !Task.isCancelled, searchID == id else { return }
            isSearching = true
            let found = await GeocodingService.shared.search(query)
            guard !Task.isCancelled, searchID == id else { return }
            results = found
            isSearching = false
        }
    }

    private func addResult(_ r: GeocodedLocation) {
        let loc = SavedLocation(
            name:      r.name,
            country:   r.country,
            state:     r.state,
            latitude:  r.lat,
            longitude: r.lon,
            sortOrder: vm.savedLocations.count
        )
        vm.addLocation(loc)
        searchText = ""
        results    = []
        dismiss()
    }
}

// MARK: - Settings section
struct SettingsSectionView: View {
    @Environment(WeatherViewModel.self) private var vm
    @AppStorage("appTheme") private var themeName: String = AppTheme.system.rawValue
    @State private var showResetCalibrationConfirm = false
    @State private var showClearCacheConfirm = false
    @State private var isConnectingNetatmo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.66))
                Text("Einstellungen")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 10) {
                Text("Darstellung")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))

                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases) { t in
                        ThemeOptionButton(
                            theme: t,
                            isSelected: themeName == t.rawValue
                        ) {
                            HapticService.impact(.light)
                            withAnimation(.easeInOut(duration: 0.2)) {
                                themeName = t.rawValue
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.white.opacity(0.07))
            .background(.ultraThinMaterial.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            DataSourceStatusView(activeModels: vm.weatherData?.activeModels ?? [])

            VStack(spacing: 0) {
                SettingsActionRow(
                    icon: "sensor.tag.radiowaves.forward.fill",
                    title: "Netatmo verbinden",
                    subtitle: isConnectingNetatmo ? "Anmeldung läuft" : "Station als lokale Messquelle nutzen",
                    tint: .green
                ) {
                    isConnectingNetatmo = true
                    Task {
                        defer { Task { @MainActor in isConnectingNetatmo = false } }
                        try? await NetatmoService.shared.authenticate()
                        await vm.refresh()
                    }
                }

                Divider()
                    .background(.white.opacity(0.08))
                    .padding(.leading, 58)

                SettingsActionRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Wettercache leeren",
                    subtitle: "Aktive Wetterdaten neu aus allen Quellen laden",
                    tint: .cyan
                ) {
                    showClearCacheConfirm = true
                }

                Divider()
                    .background(.white.opacity(0.08))
                    .padding(.leading, 58)

                SettingsActionRow(
                    icon: "chart.line.downtrend.xyaxis",
                    title: "Lerndaten zurücksetzen",
                    subtitle: "Lokale Modell-Kalibrierung neu starten",
                    tint: .orange
                ) {
                    showResetCalibrationConfirm = true
                }
            }
            .background(.white.opacity(0.07))
            .background(.ultraThinMaterial.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .confirmationDialog("Wettercache leeren?", isPresented: $showClearCacheConfirm, titleVisibility: .visible) {
            Button("Cache leeren") {
                HapticService.impact(.medium)
                vm.clearWeatherCache()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die aktuelle Vorhersage wird anschließend frisch geladen.")
        }
        .confirmationDialog("Lerndaten zurücksetzen?", isPresented: $showResetCalibrationConfirm, titleVisibility: .visible) {
            Button("Lerndaten zurücksetzen", role: .destructive) {
                HapticService.impact(.medium)
                vm.resetCalibrationData()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die App verwirft nur lokale Gewichtungen. Wetterdaten und Orte bleiben erhalten.")
        }
    }
}

struct DataSourceStatusView: View {
    @AppStorage("weatherKitLastStatus_v1") private var weatherKitLastStatus = ""
    @AppStorage("netatmoLastStatus_v1") private var netatmoLastStatus = ""
    let activeModels: [String]

    private var weatherKitActive: Bool {
        activeModels.contains("WeatherKit")
    }

    private var weatherKitSubtitle: String {
        if weatherKitActive { return "aktiv" }
        if activeModels.isEmpty { return "wartet" }
        if !weatherKitLastStatus.isEmpty { return weatherKitLastStatus }
        return "nicht geladen"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Datenquellen")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))

            StatusPill(
                icon: weatherKitActive ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                title: "WeatherKit",
                subtitle: weatherKitSubtitle,
                tint: weatherKitActive ? .green : .orange
            )

            HStack(spacing: 10) {
                StatusPill(
                    icon: activeModels.isEmpty ? "clock.fill" : "checkmark.circle.fill",
                    title: "Modelle",
                    subtitle: activeModels.isEmpty ? "warte" : "\(activeModels.count) aktiv",
                    tint: activeModels.isEmpty ? .orange : .cyan
                )
                StatusPill(
                    icon: netatmoLastStatus == "aktiv" ? "checkmark.circle.fill" : "sensor.tag.radiowaves.forward.fill",
                    title: "Netatmo",
                    subtitle: netatmoLastStatus.isEmpty ? "nicht verbunden" : netatmoLastStatus,
                    tint: netatmoLastStatus == "aktiv" ? .green : .orange
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.white.opacity(0.07))
        .background(.ultraThinMaterial.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct StatusPill: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(subtitle)
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct SettingsActionRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(tint)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.64))
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Location card (no map, just info row)
struct LocationCardView: View {
    let loc:      SavedLocation
    let isActive: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(isActive ? .white.opacity(0.18) : .white.opacity(0.08))
                    .frame(width: 40, height: 40)
                Image(systemName: loc.isGPS ? "location.fill" : "mappin")
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(loc.isGPS ? .cyan : .white.opacity(0.65))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(loc.name)
                    .font(.system(size: 17, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(.white)
                if !loc.subtitle.isEmpty {
                    Text(loc.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                }
            }

            Spacer()

            if isActive {
                Label("Aktiv", systemImage: "checkmark.circle.fill")
                    .font(.system(.footnote, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(isActive ? 0.12 : 0.07))
        .background(.ultraThinMaterial.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isActive ? Color.white.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
    }
}

// MARK: - Search bar
struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
            TextField("Stadt suchen…", text: $text)
                .font(.body)
                .foregroundStyle(.white)
                .tint(.cyan)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                }
                .accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(.white.opacity(0.1))
        .background(.ultraThinMaterial.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
