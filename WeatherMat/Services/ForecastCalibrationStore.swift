// ForecastCalibrationStore.swift
import Foundation

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

    func recordStationObservation(for locationKey: String, observation: NetatmoObservation, results: [ModelWeatherData]) {
        let actual = CurrentSnapshot(
            temp: observation.temperature ?? Double.nan,
            precipProbability: (observation.rainRate ?? 0) > 0.05 ? 100 : 0,
            windSpeed: observation.windSpeed ?? Double.nan,
            wmoClass: (observation.rainRate ?? 0) > 0.05 ? 4 : 2
        )
        guard actual.temp.isFinite || actual.windSpeed.isFinite || observation.rainRate != nil else { return }

        lock.lock()
        defer { lock.unlock() }

        var scores = loadScores()
        var locationScores = scores[locationKey] ?? [:]
        for model in results {
            let prediction = CurrentSnapshot(
                temp: model.currentTemp,
                precipProbability: model.currentPrecipitation > 0.05 ? 100 : 0,
                windSpeed: model.currentWindSpeed,
                wmoClass: ForecastModelRules.skyClass(model.currentWMOCode)
            )
            let error = forecastErrorIgnoringMissing(prediction, actual: actual)
            let score = max(0.70, min(1.25, 1.20 - error / 18.0))
            let old = locationScores[model.modelName] ?? 1.0
            locationScores[model.modelName] = old * 0.80 + score * 0.20
        }
        scores[locationKey] = locationScores
        saveScores(scores)
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

    private func forecastErrorIgnoringMissing(_ prediction: CurrentSnapshot, actual: CurrentSnapshot) -> Double {
        var error = 0.0
        var weight = 0.0
        if actual.temp.isFinite {
            error += abs(prediction.temp - actual.temp) * 1.2
            weight += 1.2
        }
        if actual.windSpeed.isFinite {
            error += abs(prediction.windSpeed - actual.windSpeed) * 0.08
            weight += 0.08
        }
        if actual.precipProbability.isFinite {
            error += abs(prediction.precipProbability - actual.precipProbability) * 0.04
            weight += 0.04
        }
        error += prediction.wmoClass == actual.wmoClass ? 0 : 2.0
        weight += 1.0
        return weight > 0 ? error : 0
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
