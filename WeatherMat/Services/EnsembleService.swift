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
        async let airQuality = try? await withTimeout(seconds: 6) {
            try await AirQualityService.shared.fetch(for: location)
        }
        async let stationObservations = try? await withTimeout(seconds: 8) {
            try await NetatmoService.shared.fetchNearestObservations(for: location)
        }

        return combine(
            results: results,
            location: location,
            warnings: await warnings,
            airQuality: await airQuality,
            stationObservations: await stationObservations ?? []
        )
    }

    // MARK: - Ensemble combination
    private func combine(
        results: [ModelWeatherData],
        location: CLLocation,
        warnings: [DWDWarning],
        airQuality: AirQuality?,
        stationObservations: [NetatmoObservation]
    ) -> EnsembleWeatherData {
        guard !results.isEmpty else { return .empty }

        let names   = results.map(\.modelName)
        let locationKey = calibrationKey(for: location)
        ForecastCalibrationStore.shared.updateScores(for: locationKey, with: results)
        let weights = calibratedWeights(for: names, locationKey: locationKey)

        // dataPrimary: OpenMeteo provides up to 14 days — always use as array source
        let dataPrimary = results.first { $0.modelName == "OpenMeteo"      }
                       ?? results.first { $0.modelName == "OpenMeteo-ICON" }
                       ?? results.first { $0.modelName == "WeatherKit"     }
                       ?? results[0]

        let hourly  = consensusHourly(primary: dataPrimary, all: results, baseWeights: weights)
        let daily   = consensusDaily(primary: dataPrimary,  all: results, baseWeights: weights)
        let bands = confidenceBands(results: results)
        let agePct = bands.first(where: { $0.id == "0-24h" })?.agreementPct ?? agreementPct(results: results)
        let conf = confidenceLevel(for: agePct)
        let rainConfidence = bands.first(where: { $0.id == "0-6h" })?.confidence ?? conf
        let currentWeights = horizonWeights(for: results, base: weights, hoursAhead: 0)
        let condPrimary = results
            .filter { $0.modelName != "ECMWF" }
            .max { (currentWeights[$0.modelName] ?? 0) < (currentWeights[$1.modelName] ?? 0) }
            ?? results.max { (currentWeights[$0.modelName] ?? 0) < (currentWeights[$1.modelName] ?? 0) }
            ?? results[0]

        func currentWA<T: BinaryFloatingPoint>(_ kp: KeyPath<ModelWeatherData, T>) -> T {
            results.reduce(0) { $0 + $1[keyPath: kp] * T(currentWeights[$1.modelName] ?? 0) }
        }

        // Weighted average cloud cover (0–100) for cloud-cover correction.
        // Current values use horizon=0 weights, so near-term sources dominate.
        let cloudCoverW = Int(results.reduce(0.0) { acc, m in
            acc + Double(m.currentCloudCover) * (currentWeights[m.modelName] ?? 0)
        }.rounded())

        // Current WMO code via weighted vote at horizon=0, corrected by cloud cover.
        let currentWMO  = votedCurrentWMO(results: results, baseWeights: weights,
                                          avgCloudCover: cloudCoverW)
        let currentIsDay = votedBool(results.map { ($0.currentIsDay, currentWeights[$0.modelName] ?? 0) })
        let cond    = WMOCode.condition(for: currentWMO, isDay: currentIsDay)

        let rain = analyzeRain(results: results, baseWeights: weights, confidence: rainConfidence)

        let current = CurrentWeather(
            temp:          Int(currentWA(\.currentTemp).rounded()),
            feelsLike:     Int(currentWA(\.currentFeelsLike).rounded()),
            humidity:      condPrimary.currentHumidity,
            cloudCover:    cloudCoverW,
            windSpeed:     Int(currentWA(\.currentWindSpeed).rounded()),
            windDirection: condPrimary.currentWindDirection,
            pressure:      Int(currentWA(\.currentPressure).rounded()),
            visibility:    Int(currentWA(\.currentVisibility).rounded()),
            uvIndex:       currentWA(\.currentUVIndex),
            isDay:         currentIsDay,
            precipitation: currentWA(\.currentPrecipitation),
            airQuality:    airQuality,
            stationObservation: stationObservations.preferredCalibrationObservation,
            stationObservations: stationObservations,
            condition:     cond,
            background:    currentIsDay ? cond.background : .nightClear
        )

        ForecastCalibrationStore.shared.storeCurrentSnapshots(
            for: locationKey,
            from: results,
            ensemble: current
        )
        if let stationObservation = stationObservations.preferredCalibrationObservation {
            ForecastCalibrationStore.shared.recordStationObservation(
                for: locationKey,
                observation: stationObservation,
                results: results
            )
        }
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
            confidenceBands: bands,
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
    func horizonWeights(for models: [ModelWeatherData],
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
    func votedBool(_ values: [(Bool, Double)]) -> Bool {
        let dayWeight = values.filter { $0.0 }.map(\.1).reduce(0, +)
        let nightWeight = values.filter { !$0.0 }.map(\.1).reduce(0, +)
        return dayWeight >= nightWeight
    }

    func votedWMO(
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
    func buildHourlyIndex(_ hourly: [ModelHourlyPoint]) -> [Int: ModelHourlyPoint] {
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
    /// Computes pairwise agreement over all common hourly buckets.
    func agreementPct(results: [ModelWeatherData]) -> Int {
        agreementPct(results: results, allowedBuckets: nil)
    }

    private func confidenceLevel(for agreementPct: Int) -> ConfidenceLevel {
        agreementPct >= 75 ? .high : agreementPct >= 45 ? .medium : .low
    }

    private func confidenceBands(results: [ModelWeatherData]) -> [ForecastConfidenceBand] {
        let specs: [(String, String, String, Double, Double)] = [
            ("0-6h", "Jetzt", "0-6 h", 0, 6),
            ("0-24h", "Heute", "0-24 h", 0, 24),
            ("1-3d", "Mittel", "1-3 Tage", 24, 72),
            ("3-10d", "Trend", "3-10 Tage", 72, 240),
        ]
        return specs.map { id, title, subtitle, start, end in
            let pct = agreementPctForHorizon(results: results, fromHour: start, toHour: end)
            return ForecastConfidenceBand(
                id: id,
                title: title,
                subtitle: subtitle,
                agreementPct: pct,
                confidence: confidenceLevel(for: pct)
            )
        }
    }

    private func agreementPctForHorizon(results: [ModelWeatherData], fromHour: Double, toHour: Double) -> Int {
        let now = Date()
        let minBucket = Int((now.addingTimeInterval(fromHour * 3_600).timeIntervalSince1970 + 1_800) / 3_600)
        let maxBucket = Int((now.addingTimeInterval(toHour * 3_600).timeIntervalSince1970 + 1_800) / 3_600)
        return agreementPct(results: results, allowedBuckets: minBucket...maxBucket)
    }

    /// Computes pairwise MAE over temperature, precipitation probability, wind and condition class.
    private func agreementPct(results: [ModelWeatherData], allowedBuckets: ClosedRange<Int>?) -> Int {
        guard results.count >= 2 else { return 70 }
        var diffs: [Double] = []
        let pairs = results.indices.flatMap { i in results.indices.filter { $0 > i }.map { (results[i], results[$0]) } }
        for (a, b) in pairs {
            let aIndex = buildHourlyIndex(a.hourly)
            let bIndex = buildHourlyIndex(b.hourly)
            let buckets = Set(aIndex.keys)
                .intersection(bIndex.keys)
                .filter { bucket in allowedBuckets?.contains(bucket) ?? true }
                .sorted()
            guard !buckets.isEmpty else { continue }
            let tempMAE = buckets
                .map { abs((aIndex[$0]?.temp ?? 0) - (bIndex[$0]?.temp ?? 0)) }
                .reduce(0,+) / Double(buckets.count)
            let precipMAE = buckets
                .map { abs((aIndex[$0]?.precipProbability ?? 0) - (bIndex[$0]?.precipProbability ?? 0)) }
                .reduce(0,+) / Double(buckets.count)
            let windMAE = buckets
                .map { abs((aIndex[$0]?.windSpeed ?? 0) - (bIndex[$0]?.windSpeed ?? 0)) }
                .reduce(0,+) / Double(buckets.count)
            let conditionMismatch = buckets
                .map { ForecastModelRules.skyClass(aIndex[$0]?.wmoCode ?? 3) == ForecastModelRules.skyClass(bIndex[$0]?.wmoCode ?? 3) ? 0.0 : 1.0 }
                .reduce(0,+) / Double(buckets.count)
            diffs.append(tempMAE * 0.48 + precipMAE * 0.04 + windMAE * 0.08 + conditionMismatch * 3.0)
        }
        guard !diffs.isEmpty else { return 70 }
        return max(5, min(99, Int((100 - diffs.reduce(0,+) / Double(diffs.count) * 8).rounded())))
    }

    // MARK: - Rain analysis
    private func analyzeRain(results: [ModelWeatherData], baseWeights: [String: Double], confidence: ConfidenceLevel) -> RainAnalysis {
        let models = results.filter { !$0.minutely.isEmpty }
        guard !models.isEmpty else {
            return analyzeRain(minutely: [], confidence: confidence)
        }
        let slots = consensusMinutely(models: models, baseWeights: baseWeights)
        return analyzeRain(minutely: slots, confidence: confidence)
    }

    private func consensusMinutely(models: [ModelWeatherData], baseWeights: [String: Double]) -> [ModelMinutelyPoint] {
        let now = Date()
        let allTimes = Set(models.flatMap { model in
            model.minutely
                .filter { $0.time >= now.addingTimeInterval(-900) && $0.time <= now.addingTimeInterval(2 * 3_600) }
                .map { Int(($0.time.timeIntervalSince1970 + 30) / 60) }
        })
        return allTimes.sorted().compactMap { minuteBucket in
            let time = Date(timeIntervalSince1970: Double(minuteBucket * 60))
            let hw = horizonWeights(for: models, base: baseWeights, hoursAhead: max(0, time.timeIntervalSince(now) / 3_600))
            var total = 0.0
            var precip = 0.0
            var probability = 0.0
            for model in models {
                guard let nearest = nearestMinutelyPoint(in: model.minutely, to: time),
                      abs(nearest.time.timeIntervalSince(time)) <= 8 * 60,
                      let weight = hw[model.modelName]
                else { continue }
                total += weight
                precip += nearest.precipMm * weight
                probability += nearest.precipProbability * weight
            }
            guard total > 0 else { return nil }
            return ModelMinutelyPoint(time: time, precipMm: precip / total, precipProbability: probability / total)
        }
    }

    private func nearestMinutelyPoint(in points: [ModelMinutelyPoint], to time: Date) -> ModelMinutelyPoint? {
        points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    func analyzeRain(minutely: [ModelMinutelyPoint], confidence: ConfidenceLevel) -> RainAnalysis {
        let sfx: String = confidence == .high ? "" : confidence == .medium ? " (wahrscheinlich)" : " (unsicher)"
        let now = Date()
        let slots = minutely
            .filter { $0.time >= now.addingTimeInterval(-900) }
            .sorted { $0.time < $1.time }
        let chart = rainChart(from: slots, now: now)

        guard !slots.isEmpty else {
            return .init(type: .clear, text: "Kein Regen erwartet", sub: "",
                         sfSymbol: "sun.max.fill", confidence: confidence,
                         minutesUntilRain: nil, minutesUntilClear: nil,
                         chart: chart)
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
                         minutesUntilRain: 0, minutesUntilClear: nil,
                         chart: chart)
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
                         minutesUntilRain: mins, minutesUntilClear: nil,
                         chart: chart)
        }
        // Rain stopping
        if let stopIdx = slots.indices.first(where: {
            precipRateMmPerHour(in: slots, at: $0) < 0.08 && slots[$0].precipProbability < 40
        }), stopIdx > 0 {
            let mins = Int(slots[stopIdx].time.timeIntervalSince(now) / 60)
            if mins > 0 && mins < 120 {
                return .init(type: .clear, text: "Regen hört in \(mins) min auf\(sfx)", sub: "",
                             sfSymbol: "cloud.sun.fill", confidence: confidence,
                             minutesUntilRain: nil, minutesUntilClear: mins,
                             chart: chart)
            }
        }
        return .init(type: .clear, text: "Kein Regen in den nächsten 2 Stunden", sub: "",
                     sfSymbol: "sun.max.fill", confidence: confidence,
                     minutesUntilRain: nil, minutesUntilClear: nil,
                     chart: chart)
    }

    private func rainChart(from slots: [ModelMinutelyPoint], now: Date) -> [RainChartPoint] {
        slots.indices.compactMap { index in
            let slot = slots[index]
            guard slot.time >= now,
                  slot.time <= now.addingTimeInterval(2 * 3_600)
            else { return nil }
            return RainChartPoint(
                time: slot.time,
                precipitationRate: precipRateMmPerHour(in: slots, at: index),
                probability: slot.precipProbability
            )
        }
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
            airQuality: nil, stationObservation: nil, stationObservations: [],
            condition: WMOCode.condition(for: 0), background: .sunny),
        today: DailyEntry(date: Date(), condition: WMOCode.condition(for: 0),
                          high: 0, low: 0, precipitationProbability: 0, precipitationSum: 0,
                          sunrise: Date(), sunset: Date(), uvMax: 0, windMax: 0, sunshineDuration: 0),
        hourly: [], daily: [],
        rain: RainAnalysis(type: .clear, text: "", sub: "", sfSymbol: "sun.max.fill",
                           confidence: .medium, minutesUntilRain: nil, minutesUntilClear: nil, chart: []),
        warnings: [], agreementPct: 0, confidence: .medium, confidenceBands: [], activeModels: []
    )
}



private extension Array where Element == NetatmoObservation {
    var preferredCalibrationObservation: NetatmoObservation? {
        let fresh = filter(\.isFresh)
        return fresh.first { $0.moduleType == "NAModule1" && $0.temperature != nil } ??
        fresh.first { $0.temperature != nil && $0.humidity != nil } ??
        fresh.first { $0.rainRate != nil } ??
        fresh.first { $0.windSpeed != nil } ??
        fresh.first
    }
}
