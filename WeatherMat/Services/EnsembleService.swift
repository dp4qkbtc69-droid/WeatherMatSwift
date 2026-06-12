// EnsembleService.swift  –  Multi-model combiner
import Foundation
import CoreLocation

final class EnsembleService: Sendable {

    static let shared = EnsembleService()
    private init() {}

    // MARK: - Public fetch
    /// Fires weather models in parallel, then combines into a single weighted result.
    /// BrightSky is excluded from weather providers (48 h only) but used for DWD warnings.
    func fetch(for location: CLLocation) async -> EnsembleWeatherData {
        // OpenMeteo (best_match) is the mandatory base — always reliable, 14-day daily.
        // WeatherKit + ECMWF add quality when available; failures are silently dropped.
        let providers: [WeatherProviding] = [
            WeatherKitService.shared,
            OpenMeteoService.bestMatch,
            OpenMeteoService.icon,      // DWD ICON — most accurate for Germany 0–72 h
            OpenMeteoService.ecmwf,
        ]

        // Parallel fetch – each provider has a hard 6-second cap
        var results: [ModelWeatherData] = []
        await withTaskGroup(of: ModelWeatherData?.self) { group in
            for provider in providers {
                group.addTask {
                    let timeout: TimeInterval = provider.modelName == "WeatherKit" ? 20 : 6
                    return try? await withTimeout(seconds: timeout) {
                        try await provider.fetchWeather(for: location)
                    }
                }
            }
            for await r in group { if let r { results.append(r) } }
        }

        // Warnings: separate BrightSky call with its own 6-second cap
        async let warnings = (try? await withTimeout(seconds: 6) {
            try await BrightSkyService.shared.fetchWarnings(for: location)
        }) ?? []

        return combine(results: results, location: location, warnings: await warnings)
    }

    // MARK: - Ensemble combination
    private func combine(results: [ModelWeatherData], location: CLLocation, warnings: [DWDWarning]) -> EnsembleWeatherData {
        guard !results.isEmpty else { return .empty }

        let names   = results.map(\.modelName)
        let locationKey = calibrationKey(for: location)
        ForecastCalibrationStore.shared.updateScores(for: locationKey, with: results)
        let weights = calibratedWeights(for: names, locationKey: locationKey)

        // Weighted helper (flat weights for scalar current fields)
        func wa<T: BinaryFloatingPoint>(_ kp: KeyPath<ModelWeatherData, T>) -> T {
            results.reduce(0) { $0 + $1[keyPath: kp] * T(weights[$1.modelName] ?? 0) }
        }

        // condPrimary: used for isDay, humidity, pressure, UV, wind direction
        // Never ECMWF for current (model run lag up to 12 h)
        let condPrimary = results.first { $0.modelName == "WeatherKit"     }
                       ?? results.first { $0.modelName == "OpenMeteo-ICON" }
                       ?? results.first { $0.modelName == "OpenMeteo"      }
                       ?? results[0]

        // dataPrimary: OpenMeteo provides up to 14 days — always use as array source
        let dataPrimary = results.first { $0.modelName == "OpenMeteo"      }
                       ?? results.first { $0.modelName == "OpenMeteo-ICON" }
                       ?? results.first { $0.modelName == "WeatherKit"     }
                       ?? results[0]

        let hourly  = consensusHourly(primary: dataPrimary, all: results, baseWeights: weights)
        let daily   = consensusDaily(primary: dataPrimary,  all: results, baseWeights: weights)
        let agePct  = agreementPct(results: results)
        let conf: ConfidenceLevel = agePct >= 75 ? .high : agePct >= 45 ? .medium : .low

        // Weighted average cloud cover (0–100) for cloud-cover correction
        let cloudCoverW = Int(results.reduce(0.0) { acc, m in
            acc + Double(m.currentCloudCover) * (weights[m.modelName] ?? 0)
        }.rounded())

        // Current WMO code via weighted vote at horizon=0, corrected by cloud cover
        let currentWMO  = votedCurrentWMO(results: results, baseWeights: weights,
                                          avgCloudCover: cloudCoverW)
        let currentIsDay = votedBool(results.map { ($0.currentIsDay, weights[$0.modelName] ?? 0) })
        let cond    = WMOCode.condition(for: currentWMO, isDay: currentIsDay)

        let bestMinutely = results.max { $0.minutely.count < $1.minutely.count }?.minutely ?? []
        let rain = analyzeRain(minutely: bestMinutely, confidence: conf)

        let current = CurrentWeather(
            temp:          Int(wa(\.currentTemp).rounded()),
            feelsLike:     Int(wa(\.currentFeelsLike).rounded()),
            humidity:      condPrimary.currentHumidity,
            cloudCover:    cloudCoverW,
            windSpeed:     Int(wa(\.currentWindSpeed).rounded()),
            windDirection: condPrimary.currentWindDirection,
            pressure:      Int(wa(\.currentPressure).rounded()),
            visibility:    Int(wa(\.currentVisibility).rounded()),
            uvIndex:       wa(\.currentUVIndex),
            isDay:         currentIsDay,
            precipitation: wa(\.currentPrecipitation),
            condition:     cond,
            background:    currentIsDay ? cond.background : .nightClear
        )

        ForecastCalibrationStore.shared.storeCurrentSnapshots(
            for: locationKey,
            from: results,
            ensemble: current
        )
        ForecastCalibrationStore.shared.storeForecasts(for: locationKey, from: results)

        return EnsembleWeatherData(
            current:      current,
            today:        daily.first ?? placeholderDay(from: current),
            hourly:       hourly,
            daily:        daily,
            rain:         rain,
            warnings:     warnings.sorted { $0.severity > $1.severity },
            agreementPct: agePct,
            confidence:   conf,
            activeModels: names
        )
    }

    private func calibratedWeights(for names: [String], locationKey: String) -> [String: Double] {
        let base = ModelWeights.normalized(available: names)
        let multipliers = ForecastCalibrationStore.shared.weightMultipliers(for: locationKey)
        let adjusted = base.map { entry in
            (entry.key, entry.value * (multipliers[entry.key] ?? 1.0))
        }
        let total = adjusted.map(\.1).reduce(0, +)
        guard total > 0 else { return base }
        return Dictionary(uniqueKeysWithValues: adjusted.map { ($0.0, $0.1 / total) })
    }

    private func calibrationKey(for location: CLLocation) -> String {
        let lat = (location.coordinate.latitude * 10).rounded() / 10
        let lon = (location.coordinate.longitude * 10).rounded() / 10
        return String(format: "%.1f,%.1f", lat, lon)
    }

    /// Returns horizon-adjusted, re-normalised weights for one time slot.
    private func horizonWeights(for models: [ModelWeatherData],
                                base: [String: Double],
                                hoursAhead: Double) -> [String: Double] {
        var adj: [String: Double] = [:]
        for m in models {
            guard let w = base[m.modelName] else { continue }
            adj[m.modelName] = w * ForecastModelRules.horizonMultiplier(m.modelName, hoursAhead: hoursAhead)
        }
        let sum = adj.values.reduce(0, +)
        guard sum > 0 else { return base }
        return adj.mapValues { $0 / sum }
    }

    // MARK: - Weighted condition voting
    private func votedBool(_ values: [(Bool, Double)]) -> Bool {
        let dayWeight = values.filter { $0.0 }.map(\.1).reduce(0, +)
        let nightWeight = values.filter { !$0.0 }.map(\.1).reduce(0, +)
        return dayWeight >= nightWeight
    }

    private func votedWMO(
        entries: [(code: Int, weight: Double)],
        fallback: Int,
        avgCloudCover: Int? = nil
    ) -> Int {
        var classWeight: [Int: Double] = [:]
        var classBestCode: [Int: (Int, Double)] = [:]

        for entry in entries where entry.weight > 0 {
            let cls = ForecastModelRules.skyClass(entry.code)
            classWeight[cls, default: 0] += entry.weight
            if entry.weight > (classBestCode[cls]?.1 ?? 0) {
                classBestCode[cls] = (entry.code, entry.weight)
            }
        }

        let winnerClass = classWeight.max(by: { $0.value < $1.value })?.key ?? ForecastModelRules.skyClass(fallback)
        var code = classBestCode[winnerClass]?.0 ?? fallback

        if let avgCloudCover, ForecastModelRules.skyClass(code) <= 2 {
            switch avgCloudCover {
            case 0...15:   code = 0
            case 16...35:  code = 1
            case 36...70:  code = 2
            default:       code = 3
            }
        }
        return code
    }

    // MARK: - Current WMO voting
    /// Weighted majority vote for current sky condition (horizon = 0).
    /// `avgCloudCover` (0–100) is used to correct sky-state mismatches when
    /// cloud-cover measurements contradict the voted sky class (e.g. models vote
    /// "clear" but cloud cover = 70% → step up to "partly cloudy").
    private func votedCurrentWMO(results: [ModelWeatherData],
                                 baseWeights: [String: Double],
                                 avgCloudCover: Int) -> Int {
        let hw = horizonWeights(for: results, base: baseWeights, hoursAhead: 0)
        return votedWMO(
            entries: results.map { ($0.currentWMOCode, hw[$0.modelName] ?? 0) },
            fallback: results[0].currentWMOCode,
            avgCloudCover: avgCloudCover
        )
    }

    // MARK: - Index builders (O(n) build → O(1) lookup)

    /// Keys each hourly point by its nearest hour (rounded, not truncated).
    /// Using +1800 before dividing ensures e.g. 13:50 maps to bucket 14, not 13.
    private func buildHourlyIndex(_ hourly: [ModelHourlyPoint]) -> [Int: ModelHourlyPoint] {
        var index = [Int: ModelHourlyPoint]()
        index.reserveCapacity(hourly.count)
        for point in hourly {
            index[Int((point.time.timeIntervalSince1970 + 1_800) / 3_600)] = point
        }
        return index
    }

    /// Keys each daily point by its calendar day (Unix timestamp of startOfDay / 86400).
    private func buildDailyIndex(_ daily: [ModelDailyPoint], cal: Calendar) -> [Int: ModelDailyPoint] {
        var index = [Int: ModelDailyPoint]()
        index.reserveCapacity(daily.count)
        for point in daily {
            index[Int(cal.startOfDay(for: point.date).timeIntervalSince1970 / 86_400)] = point
        }
        return index
    }

    // MARK: - Hourly consensus (horizon-adjusted weights per slot)
    private func consensusHourly(
        primary: ModelWeatherData, all: [ModelWeatherData], baseWeights: [String: Double]
    ) -> [HourlyEntry] {
        // Build per-model hour indices once — O(n) — then look up in O(1) per slot
        let hourlyIndices = Dictionary(uniqueKeysWithValues: all.map {
            ($0.modelName, buildHourlyIndex($0.hourly))
        })

        return primary.hourly.map { base in
            let hoursAhead = max(0, base.time.timeIntervalSinceNow / 3_600)
            let hw     = horizonWeights(for: all, base: baseWeights, hoursAhead: hoursAhead)
            let bucket = Int((base.time.timeIntervalSince1970 + 1_800) / 3_600)

            var tempW = 0.0, precipProbW = 0.0, precipMmW = 0.0, windW = 0.0, totalW = 0.0
            var conditionVotes: [(code: Int, weight: Double)] = []
            var isDayVotes: [(Bool, Double)] = []
            for m in all {
                guard let w     = hw[m.modelName],
                      let match = hourlyIndices[m.modelName]?[bucket] else { continue }
                tempW       += match.temp * w
                precipProbW += match.precipProbability * w
                precipMmW   += match.precipMm * w
                windW       += match.windSpeed * w
                totalW  += w
                conditionVotes.append((match.wmoCode, w))
                isDayVotes.append((match.isDay, w))
            }
            let s = totalW > 0 ? 1.0 / totalW : 1.0
            let isDay = votedBool(isDayVotes.isEmpty ? [(base.isDay, 1)] : isDayVotes)
            let wmo = votedWMO(entries: conditionVotes, fallback: base.wmoCode)
            let cond = WMOCode.condition(for: wmo, isDay: isDay)
            return HourlyEntry(
                time:                     base.time,
                temp:                     Int((tempW * s).rounded()),
                condition:                cond,
                precipitationProbability: Int((precipProbW * s).rounded()),
                precipitationMm:          precipMmW * s,
                windSpeed:                Int((windW * s).rounded()),
                isDay:                    isDay
            )
        }
    }

    // MARK: - Daily consensus (horizon-adjusted weights per day)
    private func consensusDaily(
        primary: ModelWeatherData, all: [ModelWeatherData], baseWeights: [String: Double]
    ) -> [DailyEntry] {
        let cal = Calendar.current
        // Build per-model day indices once — O(n) — then look up in O(1) per day
        let dailyIndices = Dictionary(uniqueKeysWithValues: all.map {
            ($0.modelName, buildDailyIndex($0.daily, cal: cal))
        })

        return primary.daily.map { base in
            let daysAhead  = max(0, base.date.timeIntervalSinceNow / 86_400)
            let hw     = horizonWeights(for: all, base: baseWeights, hoursAhead: daysAhead * 24)
            let bucket = Int(cal.startOfDay(for: base.date).timeIntervalSince1970 / 86_400)

            var highW = 0.0, lowW = 0.0, precipProbW = 0.0, precipSumW = 0.0
            var windMaxW = 0.0, uvMaxW = 0.0, sunshineW = 0.0, totalW = 0.0
            var conditionVotes: [(code: Int, weight: Double)] = []
            for m in all {
                guard let w     = hw[m.modelName],
                      let match = dailyIndices[m.modelName]?[bucket] else { continue }
                highW       += match.high * w
                lowW        += match.low * w
                precipProbW += match.precipProbability * w
                precipSumW  += match.precipSum * w
                windMaxW    += match.windMax * w
                uvMaxW      += match.uvMax * w
                sunshineW   += match.sunshineDuration * w
                totalW  += w
                conditionVotes.append((match.wmoCode, w))
            }
            let daylightSource = ["WeatherKit", "OpenMeteo", "OpenMeteo-ICON", "ECMWF"]
                .compactMap { dailyIndices[$0]?[bucket] }
                .first
            let s = totalW > 0 ? 1.0 / totalW : 1.0
            let wmo = votedWMO(entries: conditionVotes, fallback: base.wmoCode)
            let cond = WMOCode.condition(for: wmo)
            return DailyEntry(
                date:                     base.date,
                condition:                cond,
                high:                     Int((highW * s).rounded()),
                low:                      Int((lowW  * s).rounded()),
                precipitationProbability: Int((precipProbW * s).rounded()),
                precipitationSum:         precipSumW * s,
                sunrise:                  daylightSource?.sunrise ?? base.sunrise ?? Date(),
                sunset:                   daylightSource?.sunset ?? base.sunset ?? Date(),
                uvMax:                    uvMaxW * s,
                windMax:                  Int((windMaxW * s).rounded()),
                sunshineDuration:         (sunshineW * s) / 3_600
            )
        }
    }

    // MARK: - Agreement %
    /// Computes pairwise MAE over temperature (60%) and precip-prob (40%) for the next 24h.
    func agreementPct(results: [ModelWeatherData]) -> Int {
        guard results.count >= 2 else { return 70 }
        var diffs: [Double] = []
        let pairs = results.indices.flatMap { i in results.indices.filter { $0 > i }.map { (results[i], results[$0]) } }
        for (a, b) in pairs {
            let aIndex = buildHourlyIndex(a.hourly)
            let bIndex = buildHourlyIndex(b.hourly)
            let buckets = Array(Set(aIndex.keys).intersection(bIndex.keys)).sorted().prefix(24)
            guard !buckets.isEmpty else { continue }
            let tempMAE = buckets
                .map { abs((aIndex[$0]?.temp ?? 0) - (bIndex[$0]?.temp ?? 0)) }
                .reduce(0,+) / Double(buckets.count)
            let precipMAE = buckets
                .map { abs((aIndex[$0]?.precipProbability ?? 0) - (bIndex[$0]?.precipProbability ?? 0)) }
                .reduce(0,+) / Double(buckets.count)
            diffs.append(tempMAE * 0.6 + precipMAE * 0.4 * 0.1)
        }
        guard !diffs.isEmpty else { return 70 }
        return max(5, min(99, Int((100 - diffs.reduce(0,+) / Double(diffs.count) * 8).rounded())))
    }

    // MARK: - Rain analysis
    func analyzeRain(minutely: [ModelMinutelyPoint], confidence: ConfidenceLevel) -> RainAnalysis {
        let sfx: String = confidence == .high ? "" : confidence == .medium ? " (wahrscheinlich)" : " (unsicher)"
        let now = Date()
        let slots = minutely
            .filter { $0.time >= now.addingTimeInterval(-900) }
            .sorted { $0.time < $1.time }

        guard !slots.isEmpty else {
            return .init(type: .clear, text: "Kein Regen erwartet", sub: "",
                         sfSymbol: "sun.max.fill", confidence: confidence,
                         minutesUntilRain: nil, minutesUntilClear: nil)
        }
        // Currently raining?
        let currentIndex = slots.lastIndex { $0.time <= now }
            ?? slots.firstIndex { $0.time >= now }
            ?? 0
        let cur = slots[currentIndex]
        let curRate = precipRateMmPerHour(in: slots, at: currentIndex)
        if curRate > 0.2 || cur.precipProbability > 70 {
            let sub = curRate > 0
                ? String(format: "%.1f mm/h", curRate)
                : "\(Int(cur.precipProbability))% Wahrscheinlichkeit"
            return .init(type: .now, text: "Regnet gerade\(sfx)", sub: sub,
                         sfSymbol: "cloud.rain.fill", confidence: confidence,
                         minutesUntilRain: 0, minutesUntilClear: nil)
        }
        // Upcoming rain
        for (index, slot) in slots.enumerated()
            where slot.time > now
                && slot.time <= now.addingTimeInterval(2 * 3_600)
                && (precipRateMmPerHour(in: slots, at: index) > 0.2 || slot.precipProbability > 60) {
            let mins = max(1, Int(slot.time.timeIntervalSince(now) / 60))
            return .init(type: .soon, text: "Regen in \(mins) Minuten\(sfx)",
                         sub: "\(Int(slot.precipProbability))% Wahrscheinlichkeit",
                         sfSymbol: "cloud.drizzle.fill", confidence: confidence,
                         minutesUntilRain: mins, minutesUntilClear: nil)
        }
        // Rain stopping
        if let stopIdx = slots.indices.first(where: {
            precipRateMmPerHour(in: slots, at: $0) < 0.08 && slots[$0].precipProbability < 40
        }), stopIdx > 0 {
            let mins = Int(slots[stopIdx].time.timeIntervalSince(now) / 60)
            if mins > 0 && mins < 120 {
                return .init(type: .clear, text: "Regen hört in \(mins) min auf\(sfx)", sub: "",
                             sfSymbol: "cloud.sun.fill", confidence: confidence,
                             minutesUntilRain: nil, minutesUntilClear: mins)
            }
        }
        return .init(type: .clear, text: "Kein Regen in den nächsten 2 Stunden", sub: "",
                     sfSymbol: "sun.max.fill", confidence: confidence,
                     minutesUntilRain: nil, minutesUntilClear: nil)
    }

    private func precipRateMmPerHour(in slots: [ModelMinutelyPoint], at index: Int) -> Double {
        guard slots.indices.contains(index) else { return 0 }
        let duration: TimeInterval
        if slots.indices.contains(index + 1) {
            duration = slots[index + 1].time.timeIntervalSince(slots[index].time)
        } else if slots.indices.contains(index - 1) {
            duration = slots[index].time.timeIntervalSince(slots[index - 1].time)
        } else {
            duration = 15 * 60
        }
        let clampedDuration = min(max(duration, 60), 60 * 60)
        return slots[index].precipMm / clampedDuration * 3_600
    }

    private func placeholderDay(from cur: CurrentWeather) -> DailyEntry {
        DailyEntry(date: Date(), condition: cur.condition, high: cur.temp, low: cur.temp,
                   precipitationProbability: 0, precipitationSum: 0,
                   sunrise: Date(), sunset: Date(), uvMax: cur.uvIndex, windMax: cur.windSpeed,
                   sunshineDuration: 0)
    }
}

// MARK: - EnsembleWeatherData empty state
extension EnsembleWeatherData {
    static let empty = EnsembleWeatherData(
        current: CurrentWeather(
            temp: 0, feelsLike: 0, humidity: 0, cloudCover: 0, windSpeed: 0, windDirection: 0,
            pressure: 0, visibility: 0, uvIndex: 0, isDay: true, precipitation: 0,
            condition: WMOCode.condition(for: 0), background: .sunny),
        today: DailyEntry(date: Date(), condition: WMOCode.condition(for: 0),
                          high: 0, low: 0, precipitationProbability: 0, precipitationSum: 0,
                          sunrise: Date(), sunset: Date(), uvMax: 0, windMax: 0, sunshineDuration: 0),
        hourly: [], daily: [],
        rain: RainAnalysis(type: .clear, text: "", sub: "", sfSymbol: "sun.max.fill",
                           confidence: .medium, minutesUntilRain: nil, minutesUntilClear: nil),
        warnings: [], agreementPct: 0, confidence: .medium, activeModels: []
    )
}

// MARK: - Local forecast calibration

/// Lightweight, private-use calibration: old model forecasts are compared with
/// later "now" readings from the available providers. This is not a weather
/// station truth source, but it slowly nudges consistently worse local models down.
final class ForecastCalibrationStore: @unchecked Sendable {
    static let shared = ForecastCalibrationStore()

    private let lock = NSLock()
    private let defaults = UserDefaults.standard
    private let samplesKey = "forecastCalibrationSamples_v1"
    private let scoresKey = "forecastCalibrationScores_v1"
    private let latestCurrentKey = "forecastCalibrationLatestCurrent_v1"
    private let maxSampleAge: TimeInterval = 36 * 3_600
    private let maxSamplesPerLocation = 96
    private let maxLatestCurrentAge: TimeInterval = 3 * 3_600

    private init() {}

    func weightMultipliers(for locationKey: String) -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        let scores = loadScores()[locationKey] ?? [:]
        return scores.mapValues { score in
            max(0.75, min(1.20, score))
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: samplesKey)
        defaults.removeObject(forKey: scoresKey)
        defaults.removeObject(forKey: latestCurrentKey)
    }

    func updateScores(for locationKey: String, with results: [ModelWeatherData]) {
        let nowBucket = hourBucket(Date())
        let currentByModel = Dictionary(uniqueKeysWithValues: results.map {
            ($0.modelName, CurrentSnapshot(temp: $0.currentTemp,
                                           precipProbability: Double($0.currentPrecipitation > 0.05 ? 100 : 0),
                                           windSpeed: $0.currentWindSpeed,
                                           wmoClass: ForecastModelRules.skyClass($0.currentWMOCode)))
        })
        guard !currentByModel.isEmpty else { return }

        let consensusCurrent = CurrentSnapshot(
            temp: currentByModel.values.map(\.temp).reduce(0, +) / Double(currentByModel.count),
            precipProbability: currentByModel.values.map(\.precipProbability).reduce(0, +) / Double(currentByModel.count),
            windSpeed: currentByModel.values.map(\.windSpeed).reduce(0, +) / Double(currentByModel.count),
            wmoClass: mode(currentByModel.values.map(\.wmoClass))
        )

        lock.lock()
        defer { lock.unlock() }

        var samples = loadSamples()
        var scores = loadScores()
        var locationScores = scores[locationKey] ?? [:]

        let now = Date()
        var locationSamples = samples[locationKey] ?? []
        let matching = locationSamples.filter { $0.hourBucket == nowBucket }
        guard !matching.isEmpty else {
            samples[locationKey] = pruned(locationSamples, now: now)
            saveSamples(samples)
            return
        }

        for sample in matching {
            let actual = currentByModel[sample.modelName] ?? consensusCurrent
            let error = forecastError(sample.prediction, actual: actual)
            let score = max(0.75, min(1.20, 1.15 - error / 20.0))
            let old = locationScores[sample.modelName] ?? 1.0
            locationScores[sample.modelName] = old * 0.85 + score * 0.15
        }

        locationSamples.removeAll { $0.hourBucket <= nowBucket }
        samples[locationKey] = pruned(locationSamples, now: now)
        scores[locationKey] = locationScores
        saveSamples(samples)
        saveScores(scores)
    }

    func storeForecasts(for locationKey: String, from results: [ModelWeatherData]) {
        let now = Date()
        let minBucket = hourBucket(now.addingTimeInterval(45 * 60))
        let maxBucket = hourBucket(now.addingTimeInterval(24 * 3_600))
        let newSamples = results.flatMap { model in
            model.hourly.compactMap { point -> CalibrationSample? in
                let bucket = hourBucket(point.time)
                guard bucket >= minBucket, bucket <= maxBucket else { return nil }
                return CalibrationSample(
                    modelName: model.modelName,
                    hourBucket: bucket,
                    createdAt: now,
                    prediction: CurrentSnapshot(temp: point.temp,
                                                precipProbability: point.precipProbability,
                                                windSpeed: point.windSpeed,
                                                wmoClass: ForecastModelRules.skyClass(point.wmoCode))
                )
            }
        }

        guard !newSamples.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        var samples = loadSamples()
        var locationSamples = pruned(samples[locationKey] ?? [], now: now)
        let existingKeys = Set(locationSamples.map { "\($0.modelName)-\($0.hourBucket)" })
        locationSamples += newSamples.filter { !existingKeys.contains("\($0.modelName)-\($0.hourBucket)") }
        if locationSamples.count > maxSamplesPerLocation {
            locationSamples = Array(locationSamples.sorted { $0.hourBucket > $1.hourBucket }.prefix(maxSamplesPerLocation))
        }
        samples[locationKey] = locationSamples
        saveSamples(samples)
    }

    func storeCurrentSnapshots(for locationKey: String, from results: [ModelWeatherData], ensemble: CurrentWeather) {
        let snapshots = Dictionary(uniqueKeysWithValues: results.map {
            ($0.modelName, CurrentSnapshot(temp: $0.currentTemp,
                                           precipProbability: Double($0.currentPrecipitation > 0.05 ? 100 : 0),
                                           windSpeed: $0.currentWindSpeed,
                                           wmoClass: ForecastModelRules.skyClass($0.currentWMOCode)))
        })
        guard !snapshots.isEmpty else { return }

        let ensembleSnapshot = CurrentSnapshot(
            temp: Double(ensemble.temp),
            precipProbability: ensemble.precipitation > 0.05 ? 100 : 0,
            windSpeed: Double(ensemble.windSpeed),
            wmoClass: ForecastModelRules.skyClass(ensemble.condition.code)
        )

        lock.lock()
        defer { lock.unlock() }
        var latest = loadLatestCurrent()
        latest[locationKey] = LatestCurrent(createdAt: Date(),
                                            modelSnapshots: snapshots,
                                            ensemble: ensembleSnapshot)
        saveLatestCurrent(latest)
    }

    func recordFeedback(for locationKey: String, feedback: WeatherFeedback) {
        lock.lock()
        defer { lock.unlock() }

        var latest = loadLatestCurrent()
        guard let current = latest[locationKey],
              Date().timeIntervalSince(current.createdAt) <= maxLatestCurrentAge
        else { return }

        let actual = adjustedActual(from: current.ensemble, feedback: feedback)
        var scores = loadScores()
        var locationScores = scores[locationKey] ?? [:]

        for (modelName, snapshot) in current.modelSnapshots {
            let error = forecastError(snapshot, actual: actual)
            let score = max(0.70, min(1.25, 1.18 - error / 18.0))
            let old = locationScores[modelName] ?? 1.0
            locationScores[modelName] = old * 0.72 + score * 0.28
        }

        scores[locationKey] = locationScores
        saveScores(scores)
        latest[locationKey] = current
        saveLatestCurrent(latest)
    }

    private struct CurrentSnapshot: Codable {
        let temp: Double
        let precipProbability: Double
        let windSpeed: Double
        let wmoClass: Int
    }

    private struct CalibrationSample: Codable {
        let modelName: String
        let hourBucket: Int
        let createdAt: Date
        let prediction: CurrentSnapshot
    }

    private struct LatestCurrent: Codable {
        let createdAt: Date
        let modelSnapshots: [String: CurrentSnapshot]
        let ensemble: CurrentSnapshot
    }

    private func adjustedActual(from current: CurrentSnapshot, feedback: WeatherFeedback) -> CurrentSnapshot {
        switch feedback {
        case .matches:
            return current
        case .tempTooHigh:
            return CurrentSnapshot(temp: current.temp - 3,
                                   precipProbability: current.precipProbability,
                                   windSpeed: current.windSpeed,
                                   wmoClass: current.wmoClass)
        case .tempTooLow:
            return CurrentSnapshot(temp: current.temp + 3,
                                   precipProbability: current.precipProbability,
                                   windSpeed: current.windSpeed,
                                   wmoClass: current.wmoClass)
        case .rainMissing:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: 100,
                                   windSpeed: current.windSpeed,
                                   wmoClass: 4)
        case .rainFalseAlarm:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: 0,
                                   windSpeed: current.windSpeed,
                                   wmoClass: min(current.wmoClass, 1))
        case .tooSunny:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: current.precipProbability,
                                   windSpeed: current.windSpeed,
                                   wmoClass: max(current.wmoClass, 2))
        case .tooCloudy:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: current.precipProbability,
                                   windSpeed: current.windSpeed,
                                   wmoClass: 0)
        case .windTooHigh:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: current.precipProbability,
                                   windSpeed: max(0, current.windSpeed - 10),
                                   wmoClass: current.wmoClass)
        case .windTooLow:
            return CurrentSnapshot(temp: current.temp,
                                   precipProbability: current.precipProbability,
                                   windSpeed: current.windSpeed + 10,
                                   wmoClass: current.wmoClass)
        }
    }

    private func forecastError(_ prediction: CurrentSnapshot, actual: CurrentSnapshot) -> Double {
        let tempError = abs(prediction.temp - actual.temp) * 1.2
        let precipError = abs(prediction.precipProbability - actual.precipProbability) * 0.04
        let windError = abs(prediction.windSpeed - actual.windSpeed) * 0.08
        let conditionError = prediction.wmoClass == actual.wmoClass ? 0 : 3.0
        return tempError + precipError + windError + conditionError
    }

    private func pruned(_ samples: [CalibrationSample], now: Date) -> [CalibrationSample] {
        samples.filter { now.timeIntervalSince($0.createdAt) <= maxSampleAge }
    }

    private func loadSamples() -> [String: [CalibrationSample]] {
        guard let data = defaults.data(forKey: samplesKey),
              let decoded = try? JSONDecoder().decode([String: [CalibrationSample]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveSamples(_ samples: [String: [CalibrationSample]]) {
        if let data = try? JSONEncoder().encode(samples) {
            defaults.set(data, forKey: samplesKey)
        }
    }

    private func loadScores() -> [String: [String: Double]] {
        guard let data = defaults.data(forKey: scoresKey),
              let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveScores(_ scores: [String: [String: Double]]) {
        if let data = try? JSONEncoder().encode(scores) {
            defaults.set(data, forKey: scoresKey)
        }
    }

    private func loadLatestCurrent() -> [String: LatestCurrent] {
        guard let data = defaults.data(forKey: latestCurrentKey),
              let decoded = try? JSONDecoder().decode([String: LatestCurrent].self, from: data)
        else { return [:] }
        return decoded
    }

    private func saveLatestCurrent(_ latest: [String: LatestCurrent]) {
        if let data = try? JSONEncoder().encode(latest) {
            defaults.set(data, forKey: latestCurrentKey)
        }
    }

    private func hourBucket(_ date: Date) -> Int {
        Int((date.timeIntervalSince1970 + 1_800) / 3_600)
    }

    private func mode(_ values: [Int]) -> Int {
        Dictionary(grouping: values, by: { $0 })
            .max { $0.value.count < $1.value.count }?
            .key ?? 2
    }
}

// MARK: - Timeout helpers

/// Throws on timeout — use for operations that already throw.
func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// Returns nil on timeout — use for non-throwing operations that must still be capped.
func withTaskTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
    do {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            defer { group.cancelAll() }
            return try await group.next()
        }
    } catch {
        return nil
    }
}
