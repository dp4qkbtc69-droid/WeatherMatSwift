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

    // MARK: - Location state
    var savedLocations:        [SavedLocation] = []
    var activeLocationIndex:   Int             = 0
    var selectedDayIndex:      Int?            = nil

    // MARK: - Services
    private let geocoding = GeocodingService.shared
    private let where2Go = Where2GoService.shared

    // MARK: - Constants
    private let refreshCooldown: TimeInterval = 600
    private let udKey = "savedLocations_v1"
    private let activeLocationIndexKey = "activeLocationIndex_v1"

    /// Per-location refresh timestamps — populated from persisted cache on init/switch
    private var lastRefreshByLocation: [UUID: Date] = [:]
    /// Prevents duplicate parallel fetches for the same location
    private var loadingLocationIDs: Set<UUID> = []
    private var lastWhere2GoRequest: Where2GoRequest?
    private var where2GoRefreshTask: Task<Void, Never>?

    // MARK: - Cache wrapper (stores fetchedAt alongside weather data)
    private struct CachedEntry: Codable {
        let data:      EnsembleWeatherData
        let fetchedAt: Date
    }

    private func cacheKey(for loc: SavedLocation) -> String {
        "weatherCache_\(loc.id.uuidString)"
    }

    // MARK: - Init
    init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: udKey),
           let locs  = try? JSONDecoder().decode([SavedLocation].self, from: data) {
            savedLocations = locs.sorted { $0.sortOrder < $1.sortOrder }
        }
        if !savedLocations.isEmpty {
            let storedIndex = ud.integer(forKey: activeLocationIndexKey)
            activeLocationIndex = min(max(0, storedIndex), savedLocations.count - 1)
        }
        // Restore cached weather + fetchedAt for the active location — no spinner on relaunch
        restoreCache(for: activeLocationIndex)
    }

    // MARK: - Computed
    var activeLocation: SavedLocation? { savedLocations[safe: activeLocationIndex] }

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

    /// Human-readable label for the hourly strip.
    var hourlyLabel: String {
        guard let idx = selectedDayIndex, idx > 0, let day = selectedDay else {
            return "Stündliche Vorhersage"
        }
        return day.date.formatted(.dateTime.weekday(.wide).locale(.init(identifier: "de_DE")))
    }

    // MARK: - Cache helpers
    private func restoreCache(for index: Int) {
        guard let loc  = savedLocations[safe: index],
              let data  = UserDefaults.standard.data(forKey: cacheKey(for: loc)),
              let entry = try? JSONDecoder().decode(CachedEntry.self, from: data)
        else { return }
        weatherData = entry.data
        lastRefreshByLocation[loc.id] = entry.fetchedAt
    }

    private func saveCache(_ result: EnsembleWeatherData, fetchedAt: Date, for loc: SavedLocation) {
        lastRefreshByLocation[loc.id] = fetchedAt
        if let encoded = try? JSONEncoder().encode(CachedEntry(data: result, fetchedAt: fetchedAt)) {
            UserDefaults.standard.set(encoded, forKey: cacheKey(for: loc))
        }
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
        let result: EnsembleWeatherData? = await withTaskTimeout(seconds: 25) {
            await EnsembleService.shared.fetch(for: clLoc)
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
    private let lastWarmedRadarKey = "lastWarmedRadarLocation_v1"
    private let lastWarmedRadarAtKey = "lastWarmedRadarAt_v1"
    private let lastWarmedAllKey = "lastWarmedAllLocations_v1"
    private let lastWarmedAllAtKey = "lastWarmedAllLocationsAt_v1"
    /// Re-warm the same location after this long even if it didn't move: the
    /// server keeps dynamic hotspots only in memory, so a proxy restart (deploy,
    /// monthly rebuild, OOM) drops them. Re-warming on a long-absence return
    /// reheats the server hotspot *and* the app's QUIC connection before the
    /// first tile batch.
    private let radarWarmCooldown: TimeInterval = 15 * 60

    /// Called when the app becomes active (cold start and foreground return):
    /// refreshes the active location's weather so no manual pull-to-refresh is
    /// needed, and pre-warms radar tiles for it in the background.
    @MainActor
    func refreshOnForeground() async {
        guard let loc = activeLocation else { return }
        prewarmRadarIfNeeded(for: loc)
        if let last = lastForegroundRefresh,
           Date().timeIntervalSince(last) < foregroundRefreshCooldown {
            return
        }
        lastForegroundRefresh = Date()
        await loadWeather(for: loc, force: true)
    }

    /// Asks the radar proxy to render this location's tiles ahead of the user
    /// opening the radar. Re-triggers when the active location changed (~1 km
    /// granularity) *or* when the last warm is older than `radarWarmCooldown`,
    /// so a returning user after a long absence re-primes the server hotspot and
    /// the network connection instead of hitting cold tiles.
    @MainActor
    func prewarmRadarIfNeeded(for loc: SavedLocation) {
        let coord = String(format: "%.2f,%.2f", loc.latitude, loc.longitude)
        let defaults = UserDefaults.standard
        let sameCoord = defaults.string(forKey: lastWarmedRadarKey) == coord
        let lastAt = defaults.object(forKey: lastWarmedRadarAtKey) as? Date
        let fresh = lastAt.map { Date().timeIntervalSince($0) < radarWarmCooldown } ?? false
        guard !(sameCoord && fresh) else { return }
        defaults.set(coord, forKey: lastWarmedRadarKey)
        defaults.set(Date(), forKey: lastWarmedRadarAtKey)
        Task.detached(priority: .utility) {
            await RainRadarService.warmLocation(latitude: loc.latitude, longitude: loc.longitude)
        }
    }

    /// Registers every saved location with the proxy so each one opens the
    /// radar from cache. Re-registers when the set changed or the cooldown
    /// elapsed (proxy keeps hotspots only in memory + a persisted file).
    @MainActor
    func warmAllSavedLocations() {
        let coords = savedLocations.map { (latitude: $0.latitude, longitude: $0.longitude) }
        guard !coords.isEmpty else { return }
        let signature = coords
            .map { String(format: "%.2f,%.2f", $0.latitude, $0.longitude) }
            .joined(separator: ";")
        let defaults = UserDefaults.standard
        let sameSet = defaults.string(forKey: lastWarmedAllKey) == signature
        let lastAt = defaults.object(forKey: lastWarmedAllAtKey) as? Date
        let fresh = lastAt.map { Date().timeIntervalSince($0) < radarWarmCooldown } ?? false
        guard !(sameSet && fresh) else { return }
        defaults.set(signature, forKey: lastWarmedAllKey)
        defaults.set(Date(), forKey: lastWarmedAllAtKey)
        Task.detached(priority: .utility) {
            await RainRadarService.registerWarmLocations(coords)
        }
    }

    // MARK: - Location management
    @MainActor
    func addLocation(_ loc: SavedLocation) {
        savedLocations.append(loc)
        normalizeLocationSortOrder()
        activeLocationIndex = savedLocations.count - 1
        selectedDayIndex    = nil
        saveLocations()
        saveActiveLocationIndex()
        warmAllSavedLocations()
        Task { await loadWeather(for: loc, force: true) }
    }

    @MainActor
    func removeLocation(at index: Int) {
        guard savedLocations.indices.contains(index) else { return }
        let removed = savedLocations[index]
        UserDefaults.standard.removeObject(forKey: cacheKey(for: removed))
        lastRefreshByLocation.removeValue(forKey: removed.id)

        savedLocations.remove(at: index)
        activeLocationIndex = min(activeLocationIndex, max(0, savedLocations.count - 1))
        selectedDayIndex    = nil
        normalizeLocationSortOrder()
        saveLocations()
        saveActiveLocationIndex()
        warmAllSavedLocations()
        if let loc = activeLocation { Task { await loadWeather(for: loc) } }
    }

    @MainActor
    func moveLocations(from source: IndexSet, to destination: Int) {
        let activeID = activeLocation?.id
        guard !source.contains(where: { savedLocations[safe: $0]?.isGPS == true }) else { return }
        var reordered = savedLocations
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        if let gpsIndex = reordered.firstIndex(where: { $0.isGPS }) {
            let gpsLocation = reordered.remove(at: gpsIndex)
            reordered.insert(gpsLocation, at: 0)
        }
        savedLocations = reordered
        normalizeLocationSortOrder()
        if let activeID, let newIndex = savedLocations.firstIndex(where: { $0.id == activeID }) {
            activeLocationIndex = newIndex
        } else {
            activeLocationIndex = min(activeLocationIndex, max(0, savedLocations.count - 1))
        }
        saveLocations()
        saveActiveLocationIndex()
    }

    @MainActor
    func switchLocation(to index: Int) {
        guard savedLocations.indices.contains(index) else { return }
        activeLocationIndex = index
        selectedDayIndex    = nil
        saveActiveLocationIndex()

        // Restore cached data instantly — no blank state during background refresh
        weatherData = nil
        restoreCache(for: index)

        if let loc = savedLocations[safe: index] {
            where2GoSpots = []
            where2GoError = nil
            lastWhere2GoRequest = nil
            prewarmRadarIfNeeded(for: loc)
            Task { await loadWeather(for: loc) }
        }
    }

    // MARK: - Day selection
    func selectDay(_ index: Int) {
        selectedDayIndex = selectedDayIndex == index ? nil : index
    }

    // MARK: - GPS
    /// Prevents concurrent GPS flows (e.g. layout switch re-firing .task)
    private var isRequestingGPS = false
    /// Skip a fresh GPS fix if the last one is younger than this
    private let gpsCooldown: TimeInterval = 120
    private var lastGPSFix: Date?

    /// Called on app launch: keep the GPS location's data fresh but restore the
    /// location the user last had open, instead of always snapping to GPS.
    @MainActor
    func refreshOnLaunch() async {
        // Preserve the last-shown location only when it's a real saved city;
        // if GPS was showing (or nothing is saved yet), default to GPS.
        let keepCurrent = activeLocation.map { !$0.isGPS } ?? false
        warmAllSavedLocations()
        await useGPSLocation(makeActive: !keepCurrent)
    }

    /// Refreshes the GPS location. When `makeActive` is false the current
    /// selection is preserved (the GPS entry is still updated in the
    /// background), so launching the app keeps the last-shown location.
    @MainActor
    func useGPSLocation(makeActive: Bool = true) async {
        guard !isRequestingGPS else { return }
        let previousActiveID = activeLocation?.id

        // Recent fix available — just refresh weather, no GPS hardware
        if let last = lastGPSFix,
           Date().timeIntervalSince(last) < gpsCooldown,
           let gpsIndex = savedLocations.firstIndex(where: { $0.isGPS }) {
            if makeActive {
                activeLocationIndex = gpsIndex
                saveActiveLocationIndex()
            }
            if let loc = activeLocation { await loadWeather(for: loc) }
            return
        }

        isRequestingGPS = true
        defer { isRequestingGPS = false }

        // Only show the global spinner when GPS is actually taking over the
        // view; keeping the current location must not blank it out.
        if makeActive { isLoading = true }
        do {
            let clLoc = try await withTimeout(seconds: 10) {
                try await LocationService.shared.requestCurrentLocation()
            }
            let name = await geocoding.reverseGeocode(clLoc)

            // Clean up old GPS cache entry before replacing with new UUID
            let oldGPSIndex = savedLocations.firstIndex(where: { $0.isGPS })
            if let oldGPSIndex {
                let oldGPS = savedLocations[oldGPSIndex]
                UserDefaults.standard.removeObject(forKey: cacheKey(for: oldGPS))
                lastRefreshByLocation.removeValue(forKey: oldGPS.id)
            }

            let saved = SavedLocation(
                name:      name,
                latitude:  clLoc.coordinate.latitude,
                longitude: clLoc.coordinate.longitude,
                sortOrder: 0,
                isGPS:     true
            )
            if let oldGPSIndex {
                savedLocations.remove(at: oldGPSIndex)
                savedLocations.insert(saved, at: 0)
            } else {
                savedLocations.insert(saved, at: 0)
            }
            lastGPSFix = Date()
            saveLocations()
            warmAllSavedLocations()

            // Restore focus: GPS when taking over, otherwise the previously
            // shown location (its index may have shifted from the insert).
            if makeActive {
                activeLocationIndex = 0
                selectedDayIndex    = nil
            } else if let previousActiveID,
                      let idx = savedLocations.firstIndex(where: { $0.id == previousActiveID }) {
                activeLocationIndex = idx
            } else {
                activeLocationIndex = 0
                selectedDayIndex    = nil
            }
            saveActiveLocationIndex()

            if let active = activeLocation {
                prewarmRadarIfNeeded(for: active)
                await loadWeather(for: active, force: true)
            }
        } catch {
            if makeActive { isLoading = false }
            if let loc = activeLocation {
                await loadWeather(for: loc)
            } else {
                loadError = .gpsUnavailable
            }
        }
    }

    // MARK: - Swipe between locations
    @MainActor func swipeNext() { if activeLocationIndex < savedLocations.count - 1 { switchLocation(to: activeLocationIndex + 1) } }
    @MainActor func swipePrev() { if activeLocationIndex > 0                          { switchLocation(to: activeLocationIndex - 1) } }

    // MARK: - Persistence
    func saveLocations() {
        if let data = try? JSONEncoder().encode(savedLocations) {
            UserDefaults.standard.set(data, forKey: udKey)
        }
        // Keep the warning-push registration in sync with the saved locations.
        Task { @MainActor in
            await PushRegistrationService.shared.syncRegistration()
        }
    }

    private func normalizeLocationSortOrder() {
        for i in savedLocations.indices {
            savedLocations[i].sortOrder = i
        }
    }

    private func saveActiveLocationIndex() {
        UserDefaults.standard.set(activeLocationIndex, forKey: activeLocationIndexKey)
    }

    @MainActor
    func clearWeatherCache() {
        for loc in savedLocations {
            UserDefaults.standard.removeObject(forKey: cacheKey(for: loc))
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
