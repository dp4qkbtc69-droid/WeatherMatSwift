// RegionPackService.swift
import Foundation
import MapKit
import os

struct RadarPaletteStep: Codable, Equatable, Sendable {
    let lower: Double
    let upper: Double
    let rgba: [UInt8]
}

struct RadarRegionPack: Equatable, Sendable {
    struct Bounds: Codable, Equatable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double
    }

    struct MercatorBounds: Codable, Equatable, Sendable {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    struct Grid: Codable, Equatable, Sendable {
        let w: Int
        let h: Int
    }

    struct Palette: Codable, Equatable, Sendable {
        let rain: [RadarPaletteStep]
        let snow: [RadarPaletteStep]
    }

    struct Frame: Identifiable, Equatable, Sendable {
        let id: String
        let time: Date
        let isForecast: Bool
        let source: RainRadarFrame.SourceKind
        let precipitationType: RainRadarFrame.PrecipitationType
        let intensity: [UInt8]
        let snow: [UInt8]?
    }

    let bbox: Bounds
    let mercator: MercatorBounds
    let grid: Grid
    let scale: Double
    let hasSnow: Bool
    let palette: Palette
    let minIntensity: Double
    let featherRadius: Double
    let frames: [Frame]

    var mapRect: MKMapRect {
        let world = MKMapSize.world
        let originShift = 20_037_508.342789244
        let x = (mercator.minX + originShift) / (originShift * 2.0) * world.width
        let maxYMap = (originShift - mercator.maxY) / (originShift * 2.0) * world.height
        let width = (mercator.maxX - mercator.minX) / (originShift * 2.0) * world.width
        let height = (mercator.maxY - mercator.minY) / (originShift * 2.0) * world.height
        return MKMapRect(x: x, y: maxYMap, width: width, height: height)
    }

    func frame(matching radarFrame: RainRadarFrame) -> Frame? {
        frames.first { $0.id == RegionPackService.regionFrameID(from: radarFrame) }
    }
}

enum RegionPackService {
    private static let logger = Logger(subsystem: "de.praxishartlep.weathermat", category: "RegionPack")

    static func fetchRegionPack(latitude: Double, longitude: Double, km: Double = 130.0) async throws -> RadarRegionPack {
        guard let baseURL = RainRadarService.proxyBaseURL else { throw URLError(.badURL) }
        guard var components = URLComponents(url: baseURL.appending(path: "region-pack"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.5f", latitude)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", longitude)),
            URLQueryItem(name: "km", value: String(format: "%.1f", km)),
            URLQueryItem(name: "frames", value: "all")
        ]
        guard let url = components.url else { throw URLError(.badURL) }

        var request = RainRadarService.authenticatedDwdRadarRequest(url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let pack = try decode(data: data)
        logger.info("Region pack loaded: \(pack.frames.count, privacy: .public) frames, \(data.count, privacy: .public) bytes")
        return pack
    }

    static func regionFrameID(from frame: RainRadarFrame) -> String {
        if frame.path.hasPrefix("/tiles/") {
            return String(frame.path.dropFirst("/tiles/".count))
        }
        return frame.path
    }

    static func decode(data: Data) throws -> RadarRegionPack {
        guard let newline = data.firstIndex(of: 0x0A) else { throw URLError(.cannotParseResponse) }
        let headerData = data[..<newline]
        let payloadStart = data.index(after: newline)
        let header = try JSONDecoder.dwdRadar.decode(RegionPackHeader.self, from: headerData)
        let cellCount = header.grid.w * header.grid.h
        guard cellCount > 0 else { throw URLError(.cannotParseResponse) }

        let frames = try header.frames.map { raw -> RadarRegionPack.Frame in
            let start = payloadStart + raw.offsetBytes
            let end = start + cellCount
            guard start >= payloadStart, end <= data.endIndex else { throw URLError(.cannotParseResponse) }
            let snow: [UInt8]?
            if let snowOffset = raw.snowOffsetBytes {
                let snowStart = payloadStart + snowOffset
                let snowEnd = snowStart + cellCount
                guard snowStart >= payloadStart, snowEnd <= data.endIndex else { throw URLError(.cannotParseResponse) }
                snow = Array(data[snowStart..<snowEnd])
            } else {
                snow = nil
            }
            return RadarRegionPack.Frame(
                id: raw.id,
                time: raw.time,
                isForecast: raw.isForecast,
                source: RainRadarFrame.SourceKind(rawValue: raw.source ?? "") ?? .unknown,
                precipitationType: RainRadarFrame.PrecipitationType(rawValue: raw.precipType ?? "") ?? .unknown,
                intensity: Array(data[start..<end]),
                snow: snow
            )
        }

        return RadarRegionPack(
            bbox: header.bbox,
            mercator: header.mercator,
            grid: header.grid,
            scale: header.scale,
            hasSnow: header.hasSnow,
            palette: header.palette,
            minIntensity: header.minIntensity,
            featherRadius: header.featherRadius,
            frames: frames
        )
    }
}

private struct RegionPackHeader: Codable {
    struct Frame: Codable {
        let id: String
        let time: Date
        let isForecast: Bool
        let source: String?
        let precipType: String?
        let offsetBytes: Int
        let snowOffsetBytes: Int?
    }

    let bbox: RadarRegionPack.Bounds
    let mercator: RadarRegionPack.MercatorBounds
    let grid: RadarRegionPack.Grid
    let scale: Double
    let hasSnow: Bool
    let palette: RadarRegionPack.Palette
    let minIntensity: Double
    let featherRadius: Double
    let frames: [Frame]
}

private extension JSONDecoder {
    static var dwdRadar: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = RainRadarService.parseDwdDate(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid DWD date")
        }
        return decoder
    }
}
