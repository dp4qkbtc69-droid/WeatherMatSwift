// WeatherView.swift
import SwiftUI

struct WeatherView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Binding var showLocations: Bool

    @State private var isPullRefreshing = false
    @State private var dragOffset: CGFloat = 0
    @State private var showRainRadar = false

    var body: some View {
        ZStack(alignment: .top) {
            if vm.isLoading && vm.weatherData == nil {
                LoadingView()
            } else if let data = vm.weatherData {
                mainScrollView(data: data)
            } else if let error = vm.loadError {
                ErrorView(error: error) {
                    Task { await vm.refresh() }
                } openLocations: {
                    showLocations = true
                }
            } else {
                EmptyStateView(showLocations: $showLocations)
            }

            // Pull-to-refresh indicator
            if isPullRefreshing {
                PullRefreshIndicator()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: vm.weatherData != nil) {
            guard vm.weatherData != nil else { return }
            // Preload radar timeline in background so radar opens instantly
            Task.detached(priority: .background) {
                await RainRadarService.preloadIfNeeded()
            }
        }
    }

    // MARK: - Main scroll content
    private func mainScrollView(data: EnsembleWeatherData) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                // Top bar with location name + pager dots
                TopBarView(showLocations: $showLocations) {
                    showRainRadar = true
                }
                    .padding(.top, 56)
                    .simultaneousGesture(locationSwipeGesture)

                // Hero: temperature + condition icon
                HeroView(current: data.current, today: data.today)
                    .simultaneousGesture(locationSwipeGesture)

                // DWD Warnings
                if !data.warnings.isEmpty {
                    WarningsBannerView(warnings: data.warnings)
                        .padding(.horizontal)
                        .simultaneousGesture(locationSwipeGesture)
                }

                // Rain analysis banner
                RainBannerView(rain: data.rain)
                    .padding(.horizontal)
                    .simultaneousGesture(locationSwipeGesture)

                // Coarse day outlook (kräftiger Regen/Gewitter) — silent on
                // ordinary days, only surfaces above-light-rain events.
                DayOutlookView(outlook: vm.hourlyOutlook)
                    .padding(.horizontal)
                    .simultaneousGesture(locationSwipeGesture)

                // Hourly forecast
                HourlyView(entries: vm.hourlyForActiveView, label: vm.hourlyLabel)

                // 7-day daily forecast
                DailyView(entries: data.daily, confidenceBands: data.confidenceBands)
                    .padding(.horizontal)
                    .simultaneousGesture(locationSwipeGesture)

                if !data.current.stationObservations.isEmpty {
                    NetatmoStationPanelView(
                        observations: data.current.stationObservations,
                        current: data.current,
                        selectedDay: vm.selectedDay ?? data.today
                    )
                    .padding(.horizontal)
                    .simultaneousGesture(locationSwipeGesture)
                }

                Where2GoView()
                    .padding(.horizontal)
                    .simultaneousGesture(locationSwipeGesture)

                // Fallback when no Netatmo station is connected; otherwise details live in the Netatmo card.
                if data.current.stationObservations.isEmpty {
                    StatsView(current: data.current, selectedDay: vm.selectedDay ?? data.today)
                        .padding(.horizontal)
                        .simultaneousGesture(locationSwipeGesture)
                }

                Spacer(minLength: 100)
            }
            .animation(.easeInOut(duration: 0.25), value: vm.selectedDayIndex)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await vm.refresh()
        }
        .fullScreenCover(isPresented: $showRainRadar) {
            RainRadarScreen(location: vm.activeLocation)
        }
    }

    // Horizontal swipe between locations. It is attached to content sections
    // individually so the hourly forecast can keep its own horizontal scroll.
    private var locationSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { val in
                let h = val.translation.width
                let v = val.translation.height
                guard abs(h) > abs(v) * 2.0, val.translation.height < 20 else { return }
                Task { @MainActor in
                    HapticService.impact(.medium)
                    if h < -60 { vm.swipeNext() }
                    else if h > 60 { vm.swipePrev() }
                }
            }
    }
}

// MARK: - Loading
struct LoadingView: View {
    @Environment(WeatherViewModel.self) private var vm
    @State private var showRetry = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.white)
                .scaleEffect(1.4)
            Text("Lade Wetterdaten…")
                .foregroundStyle(.white.opacity(0.82))
                .font(.system(.callout, weight: .medium))
            if showRetry {
                Button("Erneut versuchen") {
                    Task { await vm.refresh() }
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // If still loading after 10 s, show the retry button
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            withAnimation { showRetry = true }
        }
    }
}

// MARK: - Error
struct ErrorView: View {
    let error: WeatherLoadError
    let retry: () -> Void
    let openLocations: () -> Void

    private var message: String { error.message }

    private var presentation: (icon: String, title: String, detail: String) {
        switch error {
        case .gpsUnavailable:
            return (
                "location.slash.fill",
                "Standort nicht verfügbar",
                "Prüfe die Standortfreigabe oder wähle einen gespeicherten Ort aus."
            )
        case .timeout:
            return (
                "wifi.exclamationmark",
                "Verbindung langsam",
                "Die Wetterdienste antworten gerade nicht zuverlässig. Ein neuer Versuch lädt alle Quellen frisch."
            )
        case .noData:
            return (
                "cloud.slash.fill",
                "Keine Wetterdaten",
                "Für diesen Ort haben die Modelle gerade keine verwertbare Vorhersage geliefert."
            )
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: presentation.icon)
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.78))

            Text(presentation.title)
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(.callout, weight: .medium))
                .foregroundStyle(.white.opacity(0.84))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.68))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            VStack(spacing: 10) {
                Button("Erneut versuchen") { retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)

                Button("Ort wechseln") { openLocations() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Empty state (no location)
struct EmptyStateView: View {
    @Binding var showLocations: Bool
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white.opacity(0.7))
            Text("Kein Ort ausgewählt")
                .font(.system(.title2, weight: .semibold))
                .foregroundStyle(.white)
            Text("Wähle einen Ort oder nutze GPS, damit die App die passenden Wettermodelle laden kann.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Button("Ort hinzufügen") { showLocations = true }
                .buttonStyle(.borderedProminent)
                .tint(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pull indicator
struct PullRefreshIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text("Aktualisiere…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.top, 56)
    }
}
