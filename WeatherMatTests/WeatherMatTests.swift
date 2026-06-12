import XCTest
@testable import WeatherMat

final class WeatherMatTests: XCTestCase {

    func testTaskTimeoutReturnsNilInsteadOfWaitingForSlowOperation() async {
        let start = Date()

        let result: Int? = await withTaskTimeout(seconds: 0.05) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return 42
        }

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testTaskTimeoutReturnsCompletedResult() async {
        let result: String? = await withTaskTimeout(seconds: 1.0) {
            "ok"
        }

        XCTAssertEqual(result, "ok")
    }

    func testSavedLocationCodableRoundTripPreservesFields() throws {
        let location = SavedLocation(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
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

        XCTAssertEqual(decoded, location)
        XCTAssertEqual(decoded.subtitle, "Berlin, DE")
    }

    func testWMOCodeProducesDistinctDayAndNightSymbols() {
        let condition = WMOCode.condition(for: 0, isDay: true)

        XCTAssertFalse(condition.label.isEmpty)
        XCTAssertFalse(condition.sfSymbol.isEmpty)
        XCTAssertFalse(condition.sfSymbolNight.isEmpty)
        XCTAssertNotEqual(condition.sfSymbol, condition.sfSymbolNight)
    }

    func testAnalyzeRainLooksTwoHoursAheadForOneMinuteSlots() {
        let now = Date()
        let points = [
            ModelMinutelyPoint(time: now, precipMm: 0, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(90 * 60), precipMm: 0.01, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(91 * 60), precipMm: 0.01, precipProbability: 0),
        ]

        let rain = EnsembleService.shared.analyzeRain(minutely: points, confidence: .high)

        XCTAssertEqual(rain.type, .soon)
        XCTAssertEqual(rain.minutesUntilRain ?? 0, 89, accuracy: 2)
    }

    func testAnalyzeRainUsesComparableRateForFifteenMinuteSlots() {
        let now = Date()
        let points = [
            ModelMinutelyPoint(time: now, precipMm: 0, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(90 * 60), precipMm: 0.10, precipProbability: 0),
            ModelMinutelyPoint(time: now.addingTimeInterval(105 * 60), precipMm: 0.10, precipProbability: 0),
        ]

        let rain = EnsembleService.shared.analyzeRain(minutely: points, confidence: .high)

        XCTAssertEqual(rain.type, .soon)
        XCTAssertEqual(rain.minutesUntilRain ?? 0, 89, accuracy: 2)
    }

    func testAgreementComparesHourlyPointsByTimeBucket() {
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

        XCTAssertGreaterThanOrEqual(agreement, 95)
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
