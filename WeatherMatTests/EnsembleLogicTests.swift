// EnsembleLogicTests.swift
import Foundation
import Testing
@testable import WeatherMat

struct EnsembleLogicTests {

    // MARK: - Modellgewichte

    @Test func normalizedWeightsSumToOneForRespondingModels() {
        let weights = ModelWeights.normalized(available: ["WeatherKit", "OpenMeteo-ICON"])

        #expect(weights.count == 2)
        let sum = weights.values.reduce(0, +)
        #expect(abs(sum - 1.0) < 0.0001)
        #expect(weights["ECMWF"] == nil)
    }

    @Test func normalizedWeightsHandleUnknownAndEmptyInput() {
        #expect(ModelWeights.normalized(available: []).isEmpty)
        #expect(ModelWeights.normalized(available: ["Unbekannt"]).isEmpty)
    }

    // MARK: - Horizont-Multiplikatoren

    @Test func horizonFavorsNowcastModelsEarlyAndECMWFLate() {
        let weatherKitNow = ForecastModelRules.horizonMultiplier("WeatherKit", hoursAhead: 0)
        let ecmwfNow = ForecastModelRules.horizonMultiplier("ECMWF", hoursAhead: 0)
        #expect(weatherKitNow > ecmwfNow)

        let weatherKitDay6 = ForecastModelRules.horizonMultiplier("WeatherKit", hoursAhead: 130)
        let ecmwfDay6 = ForecastModelRules.horizonMultiplier("ECMWF", hoursAhead: 130)
        #expect(ecmwfDay6 > weatherKitDay6)
    }

    @Test func horizonWeightsAreRenormalized() {
        let models = [
            makeModel(name: "WeatherKit"),
            makeModel(name: "ECMWF")
        ]
        let base = ModelWeights.normalized(available: ["WeatherKit", "ECMWF"])

        let now = EnsembleService.shared.horizonWeights(for: models, base: base, hoursAhead: 0)
        #expect(abs(now.values.reduce(0, +) - 1.0) < 0.0001)
        #expect(now["WeatherKit"]! > now["ECMWF"]!)

        let day6 = EnsembleService.shared.horizonWeights(for: models, base: base, hoursAhead: 130)
        #expect(day6["ECMWF"]! > day6["WeatherKit"]!)
    }

    // MARK: - Wetterlagen-Voting

    @Test func votedWMOPicksHeaviestSkyClassNotSingleCode() {
        // Zwei Modelle sagen Regen (61, 63), eines klar (0) mit höchstem Einzelgewicht.
        // Die Regen-Klasse gewinnt, weil ihre Gewichte sich addieren.
        let code = EnsembleService.shared.votedWMO(
            entries: [(61, 0.3), (63, 0.3), (0, 0.4)],
            fallback: 0
        )
        #expect(ForecastModelRules.skyClass(code) == 4)
    }

    @Test func votedWMOCorrectsClearSkyAgainstCloudCover() {
        // Modelle stimmen für "klar", aber die gemittelte Bewölkung ist 80 % →
        // Korrektur auf bedeckt (Code 3).
        let code = EnsembleService.shared.votedWMO(
            entries: [(0, 0.6), (1, 0.4)],
            fallback: 0,
            avgCloudCover: 80
        )
        #expect(code == 3)
    }

    @Test func votedWMODoesNotTouchRainCodesOnCloudCorrection() {
        let code = EnsembleService.shared.votedWMO(
            entries: [(61, 1.0)],
            fallback: 61,
            avgCloudCover: 5
        )
        #expect(code == 61)
    }

    @Test func votedBoolUsesWeightNotCount() {
        // Zwei leichte Stimmen für Nacht, eine schwere für Tag.
        let isDay = EnsembleService.shared.votedBool([(false, 0.2), (false, 0.2), (true, 0.6)])
        #expect(isDay == true)
    }

    // MARK: - Stunden-Bucketing

    @Test func hourlyIndexRoundsToNearestHour() {
        let raw = 1_780_000_000.0
        let hourStart = raw - raw.truncatingRemainder(dividingBy: 3_600)
        let hourBucket = Int(hourStart / 3_600)

        // xx:50 gehört in den Folgestunden-Bucket, nicht in die angebrochene Stunde
        let at50 = makeHourlyPoint(time: Date(timeIntervalSince1970: hourStart + 50 * 60))
        let index = EnsembleService.shared.buildHourlyIndex([at50])
        #expect(index[hourBucket + 1] != nil)
        #expect(index[hourBucket] == nil)

        // xx:10 bleibt in der angebrochenen Stunde
        let at10 = makeHourlyPoint(time: Date(timeIntervalSince1970: hourStart + 10 * 60))
        let index10 = EnsembleService.shared.buildHourlyIndex([at10])
        #expect(index10[hourBucket] != nil)
    }

    // MARK: - Helfer

    private func makeModel(name: String) -> ModelWeatherData {
        ModelWeatherData(
            modelName: name, weight: 0.25,
            currentTemp: 20, currentFeelsLike: 20, currentHumidity: 50,
            currentWindSpeed: 10, currentWindDirection: 180,
            currentPressure: 1013, currentVisibility: 10_000, currentUVIndex: 3,
            currentIsDay: true, currentPrecipitation: 0, currentWMOCode: 0,
            currentCloudCover: 0,
            hourly: [], daily: [], minutely: []
        )
    }

    private func makeHourlyPoint(time: Date) -> ModelHourlyPoint {
        ModelHourlyPoint(
            time: time, temp: 20, precipProbability: 0, precipMm: 0,
            windSpeed: 10, wmoCode: 0, isDay: true
        )
    }
}
