import Foundation
import Testing
@testable import WeatherMat

@Suite("WeatherMat core behavior")
struct WeatherMatSwiftTesting {

    @Test("Task timeout returns nil instead of waiting for slow operation")
    func taskTimeoutReturnsNilInsteadOfWaitingForSlowOperation() async {
        let start = Date()

        let result: Int? = await withTaskTimeout(seconds: 0.05) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return 42
        }

        #expect(result == nil)
        #expect(Date().timeIntervalSince(start) < 1.0)
    }

    @Test("Task timeout returns completed result")
    func taskTimeoutReturnsCompletedResult() async {
        let result: String? = await withTaskTimeout(seconds: 1.0) {
            "ok"
        }

        #expect(result == "ok")
    }

    @Test("SavedLocation Codable round trip preserves fields")
    func savedLocationCodableRoundTripPreservesFields() throws {
        let location = SavedLocation(
            id: try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555")),
            name: "Berlin",
            country: "DE",
            state: "Berlin",
            latitude: 52.52,
            longitude: 13.405,
            sortOrder: 2,
            isGPS: true
        )

        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(SavedLocation.self, from: data)

        #expect(decoded == location)
        #expect(decoded.subtitle == "Berlin, DE")
    }

    @Test("WMO code produces distinct day and night symbols")
    func wmoCodeProducesDistinctDayAndNightSymbols() {
        let condition = WMOCode.condition(for: 0)

        #expect(!condition.label.isEmpty)
        #expect(!condition.sfSymbol.isEmpty)
        #expect(!condition.sfSymbolNight.isEmpty)
        #expect(condition.sfSymbol != condition.sfSymbolNight)
    }

    @Test(
        "Rain analysis detects upcoming rain",
        arguments: [
            (slotMinutes: 1, precipMm: 0.01),
            (slotMinutes: 15, precipMm: 0.10),
        ]
    )
    func analyzeRainDetectsUpcomingRain(slotMinutes: Int, precipMm: Double) {
        let now = Date()
        let secondPointOffset = 90 * 60
        let thirdPointOffset = secondPointOffset + slotMinutes * 60
        let points = [
            ModelMinutelyPoint(time: now, precipMm: 0, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(TimeInterval(secondPointOffset)), precipMm: precipMm, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(TimeInterval(thirdPointOffset)), precipMm: precipMm, precipProbability: 0),
        ]

        let rain = EnsembleService.shared.analyzeRain(minutely: points, confidence: .high)

        #expect(rain.type == .soon)
        #expect(abs(Double((rain.minutesUntilRain ?? 0) - 89)) <= 2)
    }

    @Test("Agreement compares hourly points by time bucket")
    func agreementComparesHourlyPointsByTimeBucket() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let modelA = modelWeather(
            name: "A",
            hourly: [
                hourly(base, temp: 10),
                hourly(base.addingTimeInterval(3_600), temp: 20),
            ]
        )
        let modelB = modelWeather(
            name: "B",
            hourly: [
                hourly(base.addingTimeInterval(3_600), temp: 20),
            ]
        )

        let agreement = EnsembleService.shared.agreementPct(results: [modelA, modelB])

        #expect(agreement >= 95)
    }

    private func hourly(_ time: Date, temp: Double) -> ModelHourlyPoint {
        ModelHourlyPoint(
            time: time,
            temp: temp,
            precipProbability: 0,
            precipMm: 0,
            windSpeed: 0,
            wmoCode: 0,
            isDay: true
        )
    }

    private func modelWeather(name: String, hourly: [ModelHourlyPoint]) -> ModelWeatherData {
        ModelWeatherData(
            modelName: name,
            weight: 1,
            currentTemp: 0,
            currentFeelsLike: 0,
            currentHumidity: 0,
            currentWindSpeed: 0,
            currentWindDirection: 0,
            currentPressure: 0,
            currentVisibility: 0,
            currentUVIndex: 0,
            currentIsDay: true,
            currentPrecipitation: 0,
            currentWMOCode: 0,
            currentCloudCover: 0,
            hourly: hourly,
            daily: [],
            minutely: []
        )
    }
}
