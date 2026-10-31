// WeatherViewModel.swift
import Foundation
import CoreLocation
import Observation

/// Typed load failures — the view maps these to icon/title/detail without
/// string matching on message text.
enum WeatherLoadError {
    case timeout
    case noData
    case gpsUnavailable

    var message: String {
        switch self {
        case .timeout:        return "Zeitüberschreitung – Verbindung prüfen"
        case .noData:         return "Keine Wetterdaten – Verbindung prüfen"
        case .gpsUnavailable: return "GPS nicht verfügbar"
        }
    }
}

/// Loads, caches, and refreshes weather data for the active location.
/// Location state/CRUD/GPS acquisition lives in `LocationStore` (injected);
/// this view model reacts to location changes — restoring the cache,
/// loading fresh data, pre-warming radar via `RadarPrewarmController` — as
/// thin orchestration, rather than owning those sub-features' logic itself.
@MainActor
@Observable
final class WeatherViewModel {

    // MARK: - Weather data
    var weatherData:   EnsembleWeatherData?
    var isLoading      = false
    var isRefreshing   = false
    var loadError:     WeatherLoadError?
    var feedbackMessage: String?
    var where2GoSpots: [Where2GoSpot] = []
    var where2GoWindow: Where2GoWindow = .tomorrow
    var where2GoSortMode: Where2GoSortMode = .nearest
    var where2GoRadiusKm: Int = 150
    var isLoadingWhere2Go = false
    var where2GoError: String?
    var selectedDayIndex: Int? = nil

    // MARK: - Dependencies
    private let locationStore: LocationStore
    private let ensembleService: EnsembleServiceProtocol
    private let where2Go = Where2GoService.shared

    // MARK: - Constants
    private let refreshCooldown: TimeInterval = 600

    /// Per-location refresh timestamps — populated from persisted cache on init/switch
    private var lastRefreshByLocation: [UUID: Date] = [:]
    /// Prevents duplicate parallel fetches for the same location
    private var loadingLocationIDs: Set<UUID> = []
    private var lastWhere2GoRequest: Where2GoRequest?
    private var where2GoRefreshTask: Task<Void, Never>?

    // MARK: - Init
    init(locationStore: LocationStore, ensembleService: EnsembleServiceProtocol = EnsembleService.shared) {
        self.locationStore = locationStore
        self.ensembleService = ensembleService
        // Restore cached weather + fetchedAt for the active location — no spinner on relaunch
        if let loc = locationStore.activeLocation {
            restoreCache(for: loc)
        }
    }

    // MARK: - Computed
    var activeLocation: SavedLocation? { locationStore.activeLocation }

    var selectedDay: DailyEntry? {
        guard let i = selectedDayIndex else { return nil }
        return weatherData?.daily[safe: i]
    }

    /// Hourly entries for the currently selected day (or full list for today).
    var hourlyForActiveView: [HourlyEntry] {
        guard let data = weatherData else { return [] }
        guard let day = selectedDay else { return Array(data.hourly.prefix(24)) }
        let cal = Calendar.current
        return data.hourly.filter { cal.isDate($0.time, inSameDayAs: day.date) }
    }

    /// Coarse outlook for the active day ("kräftiger Regen ab 16:00", "Gewitter
    /// möglich") — nil when nothing beyond light rain is expected, so the UI
    /// stays silent on ordinary days instead of showing a permanent "all
    /// clear" chip.
    var hourlyOutlook: HourlyOutlook? {
        EnsembleService.hourlyOutlook(hourly: hourlyForActiveView)
    }

    /// Human-readable label for the hourly strip.
    var hourlyLabel: String {
        guard let idx = selectedDayIndex, idx > 0, let day = selectedDay else {
            return "Stündliche Vorhersage"
        }
        return day.date.formatted(.dateTime.weekday(.wide).locale(.init(identifier: "de_DE")))
    }

    // MARK: - Cache helpers
    private func restoreCache(for loc: SavedLocation) {
        guard let entry = WeatherCacheStore.load(for: loc.id) else { return }
        weatherData = entry.data
        lastRefreshByLocation[loc.id] = entry.fetchedAt
    }

    private func saveCache(_ result: EnsembleWeatherData, fetchedAt: Date, for loc: SavedLocation) {
        lastRefreshByLocation[loc.id] = fetchedAt
        WeatherCacheStore.save(result, fetchedAt: fetchedAt, for: loc.id)
    }

    // MARK: - Load weather
    @MainActor
    func loadWeather(for loc: SavedLocation, force: Bool = false) async {
        guard force || needsRefresh(for: loc) else { return }
        guard !loadingLocationIDs.contains(loc.id) else { return }  // deduplicate

        loadingLocationIDs.insert(loc.id)
        defer { loadingLocationIDs.remove(loc.id) }

        // Only update loading indicators for the currently visible location
        if activeLocation?.id == loc.id {
            isLoading    = weatherData == nil
            isRefreshing = weatherData != nil
            loadError    = nil
        }

        let clLoc  = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        let result: EnsembleWeatherData? = await withTaskTimeout(seconds: 25) { [ensembleService] in
            await ensembleService.fetch(for: clLoc)
        }

        guard let result else {
            if activeLocation?.id == loc.id {
                loadError = .timeout
                isLoading    = false
                isRefreshing = false
            }
            return
        }

        if result.activeModels.isEmpty {
            if activeLocation?.id == loc.id {
                loadError = .noData
            }
        } else {
            let fetchedAt = Date()
            saveCache(result, fetchedAt: fetchedAt, for: loc)

            // Update the visible UI only if this location is still active
            if activeLocation?.id == loc.id {
                weatherData = result
                NotificationService.shared.pruneSeenIDs(keepingFrom: result.warnings)
                await NotificationService.shared.checkWarnings(result.warnings)
                await LiveActivityController.updateRain(result.rain, locationName: loc.name)
                await LiveActivityController.updateWarning(result.warnings, locationName: loc.name)
                loadWhere2GoIfNeeded()
            }
        }

        if activeLocation?.id == loc.id {
            isLoading    = false
            isRefreshing = false
        }
    }

    private func needsRefresh(for loc: SavedLocation) -> Bool {
        guard let last = lastRefreshByLocation[loc.id] else { return true }
        return Date().timeIntervalSince(last) > refreshCooldown
    }

    // MARK: - Refresh
    @MainActor
    func refresh() async {
        guard let loc = activeLocation else { return }
        await loadWeather(for: loc, force: true)
    }

    // MARK: - Foreground refresh + radar prewarm
    private let foregroundRefreshCooldown: TimeInterval = 120
    private var lastForegroundRefresh: Date?

    /// Called when the app becomes active (cold start and foreground return):
    /// re-acquires the current GPS position (same "always show here" policy
    /// as refreshOnLaunch — that one only fires on a true cold start, since
    /// ContentView's .task doesn't re-run when the app is merely resumed
    /// from the background) so no manual pull-to-refresh is needed, and
    /// pre-warms radar tiles in the background.
    @MainActor
    func refreshOnForeground() async {
        guard let loc = activeLocation else { return }
        // Retried here too (not just on save) since WCSession activation is
        // async and may not be ready yet at cold launch.
        WatchConnectivityService.shared.syncLocations(locationStore.savedLocations)
        RadarPrewarmController.prewarmIfNeeded(for: loc)
        if let last = lastForegroundRefresh,
           Date().timeIntervalSince(last) < foregroundRefreshCooldown {
            return
        }
        lastForegroundRefresh = Date()
        await useGPSLocation(makeActive: true)
    }

    // MARK: - Location actions
    // Thin orchestration over `LocationStore`: these call into the store for
    // the actual state change, then react on the weather side (cache
    // restore/reset, reload, radar prewarm) — `LocationStore` itself knows
    // nothing about weather data or radar.

    @MainActor
    func addLocation(_ loc: SavedLocation) {
        locationStore.addLocation(loc)
        selectedDayIndex = nil
        RadarPrewarmController.warmAll(locationStore.savedLocations)
        Task { await loadWeather(for: loc, force: true) }
    }

    @MainActor
    func removeLocation(at index: Int) {
        guard let removed = locationStore.removeLocation(at: index) else { return }
        WeatherCacheStore.remove(for: removed.id)
        lastRefreshByLocation.removeValue(forKey: removed.id)
        selectedDayIndex = nil
        RadarPrewarmController.warmAll(locationStore.savedLocations)
        if let loc = activeLocation { Task { await loadWeather(for: loc) } }
    }

    @MainActor
    func switchLocation(to index: Int) {
        locationStore.switchLocation(to: index)
        selectedDayIndex = nil

        // Restore cached data instantly — no blank state during background refresh
        weatherData = nil
        guard let loc = activeLocation else { return }
        restoreCache(for: loc)

        where2GoSpots = []
        where2GoError = nil
        lastWhere2GoRequest = nil
        RadarPrewarmController.prewarmIfNeeded(for: loc)
        Task { await loadWeather(for: loc) }
    }

    // MARK: - Day selection
    func selectDay(_ index: Int) {
        selectedDayIndex = selectedDayIndex == index ? nil : index
    }

    // MARK: - GPS

    /// Called on app launch: always shows the current GPS location, so the
    /// app opens on today's weather where the user actually is rather than
    /// whichever saved city was last open.
    @MainActor
    func refreshOnLaunch() async {
        RadarPrewarmController.warmAll(locationStore.savedLocations)
        await useGPSLocation(makeActive: true)
    }

    /// Refreshes the GPS location. When `makeActive` is false the current
    /// selection is preserved (the GPS entry is still updated in the
    /// background), so launching the app keeps the last-shown location.
    @MainActor
    func useGPSLocation(makeActive: Bool = true) async {
        switch locationStore.gpsQuickCheck(makeActive: makeActive) {
        case .busy:
            return
        case .usesCachedFix(let loc):
            await loadWeather(for: loc)
            return
        case .needsFreshFix:
            break
        }

        // Only show the global spinner when GPS is actually taking over the
        // view; keeping the current location must not blank it out.
        if makeActive { isLoading = true }
        switch await locationStore.acquireFreshGPSLocation(makeActive: makeActive) {
        case .success(let location, let replacedLocationID, let shouldResetDaySelection):
            if let replacedLocationID {
                WeatherCacheStore.remove(for: replacedLocationID)
                lastRefreshByLocation.removeValue(forKey: replacedLocationID)
            }
            if shouldResetDaySelection { selectedDayIndex = nil }
            RadarPrewarmController.prewarmIfNeeded(for: location)
            await loadWeather(for: location, force: true)
        case .failure:
            if makeActive { isLoading = false }
            if let loc = activeLocation {
                await loadWeather(for: loc)
            } else {
                loadError = .gpsUnavailable
            }
        }
    }

    // MARK: - Swipe between locations
    @MainActor func swipeNext() {
        if locationStore.activeLocationIndex < locationStore.savedLocations.count - 1 {
            switchLocation(to: locationStore.activeLocationIndex + 1)
        }
    }
    @MainActor func swipePrev() {
        if locationStore.activeLocationIndex > 0 {
            switchLocation(to: locationStore.activeLocationIndex - 1)
        }
    }

    // MARK: - Weather cache / calibration

    @MainActor
    func clearWeatherCache() {
        for loc in locationStore.savedLocations {
            WeatherCacheStore.remove(for: loc.id)
        }
        lastRefreshByLocation.removeAll()
        weatherData = nil
        if let loc = activeLocation {
            Task { await loadWeather(for: loc, force: true) }
        }
    }

    func resetCalibrationData() {
        ForecastCalibrationStore.shared.reset()
    }

    @MainActor
    func submitWeatherFeedback(_ feedback: WeatherFeedback) {
        guard let loc = activeLocation else { return }
        let key = calibrationKey(for: loc)
        ForecastCalibrationStore.shared.recordFeedback(for: key, feedback: feedback)
        feedbackMessage = feedback == .matches
            ? "Danke, das stärkt passende Modelle."
            : "Danke, die Rückmeldung fließt lokal in die Modellgewichtung ein."
    }

    private func calibrationKey(for loc: SavedLocation) -> String {
        let lat = (loc.latitude * 10).rounded() / 10
        let lon = (loc.longitude * 10).rounded() / 10
        return String(format: "%.1f,%.1f", lat, lon)
    }

    // MARK: - Where2Go

    @MainActor
    func loadWhere2GoIfNeeded() {
        refreshWhere2Go(force: false, debounce: false)
    }

    @MainActor
    func refreshWhere2Go(force: Bool = false, debounce: Bool = true) {
        guard let loc = activeLocation else { return }
        let radius = min(300, max(50, where2GoRadiusKm))
        where2GoRadiusKm = radius
        let request = Where2GoRequest(locationID: loc.id, radiusKm: radius, window: where2GoWindow, sortMode: where2GoSortMode)
        guard force || request != lastWhere2GoRequest else { return }

        where2GoRefreshTask?.cancel()
        where2GoRefreshTask = Task { [where2Go] in
            if debounce {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
            }

            await MainActor.run {
                isLoadingWhere2Go = true
                where2GoError = nil
            }

            let spots = await where2Go.findSpots(
                from: loc,
                radiusKm: radius,
                window: request.window,
                sortMode: request.sortMode
            )
            guard !Task.isCancelled else { return }

            await MainActor.run {
                isLoadingWhere2Go = false
                if activeLocation?.id == request.locationID,
                   where2GoRadiusKm == request.radiusKm,
                   where2GoWindow == request.window,
                   where2GoSortMode == request.sortMode {
                    where2GoSpots = spots
                    where2GoError = spots.isEmpty ? "Keine Ziele gefunden – später erneut versuchen." : nil
                    lastWhere2GoRequest = request
                }
            }
        }
    }

    private struct Where2GoRequest: Equatable {
        let locationID: UUID
        let radiusKm: Int
        let window: Where2GoWindow
        let sortMode: Where2GoSortMode
    }
}
