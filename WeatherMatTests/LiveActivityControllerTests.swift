// LiveActivityControllerTests.swift
import Foundation
import Testing
@testable import WeatherMat

struct LiveActivityControllerTests {

    private func chart(ratesEveryMinute rates: [Double], startingAt start: Date) -> [RainChartPoint] {
        rates.enumerated().map { offset, rate in
            RainChartPoint(time: start.addingTimeInterval(Double(offset) * 60), precipitationRate: rate, probability: rate > 0 ? 80 : 0)
        }
    }

    private func analysis(
        type: RainType,
        minutesUntilRain: Int? = nil,
        minutesUntilClear: Int? = nil,
        chart: [RainChartPoint] = []
    ) -> RainAnalysis {
        RainAnalysis(
            type: type, text: "", sub: "2.0 mm/h", sfSymbol: "cloud.rain.fill", confidence: .high,
            minutesUntilRain: minutesUntilRain, minutesUntilClear: minutesUntilClear,
            chart: chart, severity: .light
        )
    }

    @Test func soonEstimatesDurationAndKeepsProgressLowWhileStillFarOut() throws {
        let now = Date()
        // Rain starts in 110 min (near the 120 min lookahead edge), rains
        // for 10 min, then clears.
        let rain = analysis(
            type: .soon,
            minutesUntilRain: 110,
            chart: chart(ratesEveryMinute: Array(repeating: 1.5, count: 10) + Array(repeating: 0.0, count: 5), startingAt: now.addingTimeInterval(110 * 60))
        )

        let estimate = LiveActivityController.rainEventEstimate(for: rain, now: now)

        #expect(estimate != nil)
        #expect(estimate?.durationMinutes == 10)
        // Still near the far edge of the 120 min lookahead -> fill stays low.
        let progress = try #require(estimate?.progress)
        #expect(progress > 0)
        #expect(progress < 0.2)
    }

    @Test func soonProgressApproachesOneAsRainGetsCloser() throws {
        let now = Date()
        let rain = analysis(
            type: .soon,
            minutesUntilRain: 2,
            chart: chart(ratesEveryMinute: Array(repeating: 1.5, count: 5), startingAt: now.addingTimeInterval(2 * 60))
        )

        let progress = try #require(LiveActivityController.rainEventEstimate(for: rain, now: now)?.progress)

        #expect(progress > 0.9)
    }

    @Test func nowReportsRemainingDurationButNoProgress() {
        let now = Date()
        // Rains for 15 more minutes, then clears.
        let rain = analysis(
            type: .now,
            minutesUntilRain: 0,
            chart: chart(ratesEveryMinute: Array(repeating: 2.0, count: 15) + Array(repeating: 0.0, count: 5), startingAt: now)
        )

        let estimate = LiveActivityController.rainEventEstimate(for: rain, now: now)

        #expect(estimate?.durationMinutes == 15)
        #expect(estimate?.progress == nil)
    }

    @Test func nowFallsBackToChartEndWhenRainNeverClearsWithinTheWindow() {
        let now = Date()
        let rain = analysis(
            type: .now,
            minutesUntilRain: 0,
            chart: chart(ratesEveryMinute: Array(repeating: 3.0, count: 30), startingAt: now)
        )

        let estimate = LiveActivityController.rainEventEstimate(for: rain, now: now)

        #expect(estimate?.durationMinutes == 29)
    }

    @Test func returnsNilWhenClearOrChartIsEmpty() {
        #expect(LiveActivityController.rainEventEstimate(for: analysis(type: .clear)) == nil)
        #expect(LiveActivityController.rainEventEstimate(for: analysis(type: .now, minutesUntilRain: 0, chart: [])) == nil)
        #expect(LiveActivityController.rainEventEstimate(for: analysis(type: .soon, minutesUntilRain: 10, chart: [])) == nil)
    }
}
