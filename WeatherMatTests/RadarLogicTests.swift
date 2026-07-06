// RadarLogicTests.swift
import Foundation
import CoreGraphics
import Testing
@testable import WeatherMat

struct RadarLogicTests {

    private static let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func frame(
        minutes: Int,
        isForecast: Bool = false,
        sourceKind: RainRadarFrame.SourceKind = .dwdRadar
    ) -> RainRadarFrame {
        RainRadarFrame(
            time: Self.base.addingTimeInterval(Double(minutes) * 60),
            path: "/tiles/frame-\(minutes)",
            isForecast: isForecast,
            sourceKind: sourceKind,
            precipitationType: .unknown,
            referenceTime: nil
        )
    }

    // MARK: - Sichtbares Timeline-Fenster

    @Test func visibleFramesKeeps24HoursHistoryAnd120HoursForecast() {
        let frames = [
            frame(minutes: -25 * 60),                       // älter als 24 h -> raus
            frame(minutes: -23 * 60),                       // innerhalb 24 h -> bleibt
            frame(minutes: 0),                              // letzte Beobachtung
            frame(minutes: 119 * 60, isForecast: true),     // innerhalb 120 h -> bleibt
            frame(minutes: 121 * 60, isForecast: true)      // jenseits 120 h -> raus
        ]
        let timeline = RainRadarTimeline(host: "h", attribution: "a", source: .dwd, tileMaxZoom: 9, frames: frames)

        let visible = RadarV2Store.visibleFrames(in: timeline)

        #expect(visible.count == 3)
        #expect(visible.first?.time == frames[1].time)
        #expect(visible.last?.time == frames[3].time)
    }

    @Test func visibleFramesWithoutObservationsKeepsEverything() {
        let frames = [
            frame(minutes: 0, isForecast: true),
            frame(minutes: 60, isForecast: true)
        ]
        let timeline = RainRadarTimeline(host: "h", attribution: "a", source: .dwd, tileMaxZoom: 9, frames: frames)

        #expect(RadarV2Store.visibleFrames(in: timeline).count == 2)
    }

    // MARK: - Playback-Pacing

    @Test func playbackDelayScalesWithFrameGap() {
        let tenMinutes = RadarV2Store.playbackDelayNanoseconds(
            current: frame(minutes: 0),
            next: frame(minutes: 10)
        )
        let oneHour = RadarV2Store.playbackDelayNanoseconds(
            current: frame(minutes: 0),
            next: frame(minutes: 60)
        )

        #expect(tenMinutes < oneHour)
        #expect(tenMinutes >= 340_000_000)
    }

    @Test func playbackDelayClampsAtUpperBound() {
        let threeHours = RadarV2Store.playbackDelayNanoseconds(
            current: frame(minutes: 0),
            next: frame(minutes: 180)
        )

        #expect(threeHours == 780_000_000)
    }

    @Test func playbackPausesBrieflyAtSourceTransition() {
        let transition = RadarV2Store.playbackDelayNanoseconds(
            current: frame(minutes: 0, sourceKind: .dwdRadar),
            next: frame(minutes: 60, isForecast: true, sourceKind: .iconEuRaw)
        )

        #expect(transition == 760_000_000)
    }

    // MARK: - Tages-Buckets

    @Test func makeBucketsSplitsAtCalendarDayBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!

        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 1
        components.hour = 23
        components.minute = 30
        components.timeZone = calendar.timeZone
        let lateEvening = calendar.date(from: components)!

        let frames = [0, 15, 30, 45, 60].map { offset in
            RainRadarFrame(
                time: lateEvening.addingTimeInterval(Double(offset) * 60),
                path: "/tiles/bucket-\(offset)",
                isForecast: false,
                sourceKind: .dwdRadar,
                precipitationType: .unknown,
                referenceTime: nil
            )
        }

        let buckets = RadarTimelineControl.makeBuckets(frames, calendar: calendar)

        #expect(buckets.count == 2)
        #expect(buckets[0].range == 0...1)   // 23:30, 23:45
        #expect(buckets[1].range == 2...4)   // 00:00, 00:15, 00:30
    }

    @Test func makeBucketsHandlesEmptyAndSingleDayInput() {
        #expect(RadarTimelineControl.makeBuckets([]).isEmpty)

        let frames = [frame(minutes: 0), frame(minutes: 10)]
        let buckets = RadarTimelineControl.makeBuckets(frames)
        #expect(buckets.count == 1)
        #expect(buckets[0].range == 0...1)
    }

    // MARK: - WMS-Zeitraster

    @Test func fiveMinuteBucketRoundsDownToProductGrid() {
        let date = Date(timeIntervalSince1970: 1_780_000_137) // irgendwo zwischen zwei 5-min-Schritten
        let rounded = date.roundedDownToFiveMinuteBucket

        #expect(rounded.timeIntervalSince1970.truncatingRemainder(dividingBy: 300) == 0)
        #expect(rounded <= date)
        #expect(date.timeIntervalSince(rounded) < 300)
    }

    // MARK: - Timeline-Parsing

    @Test func parsesDwdTimestampsWithAndWithoutFractionalSeconds() {
        let plain = RainRadarService.parseDwdDate("2026-07-02T10:05:00Z")
        let fractional = RainRadarService.parseDwdDate("2026-07-02T10:05:00.000Z")

        #expect(plain != nil)
        #expect(fractional != nil)
        #expect(plain == fractional)
        #expect(RainRadarService.parseDwdDate("kein-datum") == nil)
    }

    // MARK: - Region renderer color contract

    @Test func regionRendererAppliesRainCutoffButPaintsSnowTrace() throws {
        let frame = RadarRegionPack.Frame(
            id: "golden",
            time: Self.base,
            isForecast: false,
            source: .dwdRadar,
            precipitationType: .mixed,
            referenceTime: nil,
            // scale=10: 2 -> 0.2 (below rain cutoff), 4 -> 0.4 (paint rain)
            intensity: [2, 4, 0, 0],
            // scale=10: 1 -> 0.1. Snow must paint despite minIntensity=0.3.
            snow: [0, 0, 1, 0]
        )
        let pack = RadarRegionPack(
            bbox: .init(west: 0, south: 0, east: 1, north: 1),
            mercator: .init(minX: 0, minY: 0, maxX: 1, maxY: 1),
            grid: .init(w: 2, h: 2),
            scale: 10,
            hasSnow: true,
            palette: .init(
                rain: [.init(lower: 0.3, upper: 1.0, rgba: [10, 20, 30, 255])],
                snow: [.init(lower: 0.01, upper: 1.0, rgba: [200, 210, 220, 255])]
            ),
            minIntensity: 0.3,
            featherRadius: 0,
            frames: [frame]
        )

        let image = try #require(RadarRegionImageRenderer.render(frame: frame, pack: pack))
        let data = try #require(image.dataProvider?.data)
        let bytes = [UInt8](data as Data)

        #expect(Array(bytes[0..<4]) == [0, 0, 0, 0])
        #expect(Array(bytes[4..<8]) == [10, 20, 30, 255])
        #expect(Array(bytes[8..<12]) == [200, 210, 220, 255])
        #expect(Array(bytes[12..<16]) == [0, 0, 0, 0])
    }
}
