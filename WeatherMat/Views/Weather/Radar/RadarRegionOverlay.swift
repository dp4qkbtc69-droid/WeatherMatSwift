// RadarRegionOverlay.swift
import CoreGraphics
import Foundation
import MapKit
import UIKit

struct RadarRegionRenderSet: @unchecked Sendable {
    let pack: RadarRegionPack
    let images: [String: CGImage]

    func image(for frame: RainRadarFrame) -> CGImage? {
        images[RegionPackService.regionFrameID(from: frame)]
    }
}

struct RenderedRegionFrame: @unchecked Sendable {
    let frameID: String
    let image: CGImage
}

enum RadarRegionImageRenderer {
    static func renderAll(pack: RadarRegionPack) async -> RadarRegionRenderSet {
        await Task.detached(priority: .utility) {
            var images: [String: CGImage] = [:]
            images.reserveCapacity(pack.frames.count)
            for frame in pack.frames {
                if let image = render(frame: frame, pack: pack) {
                    images[frame.id] = image
                }
            }
            return RadarRegionRenderSet(pack: pack, images: images)
        }.value
    }

    static func renderFrame(_ frame: RadarRegionPack.Frame, pack: RadarRegionPack) async -> RenderedRegionFrame? {
        await Task.detached(priority: .utility) {
            guard let image = render(frame: frame, pack: pack) else { return nil }
            return RenderedRegionFrame(frameID: frame.id, image: image)
        }.value
    }

    private static func render(frame: RadarRegionPack.Frame, pack: RadarRegionPack) -> CGImage? {
        let width = pack.grid.w
        let height = pack.grid.h
        let cellCount = width * height
        guard width > 0, height > 0, frame.intensity.count == cellCount else { return nil }

        var rgba = [UInt8](repeating: 0, count: cellCount * 4)
        paint(frame.intensity, into: &rgba, pack: pack, palette: pack.palette.rain, replace: true)
        if let snow = frame.snow, snow.count == cellCount {
            paint(snow, into: &rgba, pack: pack, palette: pack.palette.snow, replace: false)
        }
        featherAlpha(&rgba, width: width, height: height, radius: pack.featherRadius)

        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func paint(
        _ quantized: [UInt8],
        into rgba: inout [UInt8],
        pack: RadarRegionPack,
        palette: [RadarPaletteStep],
        replace: Bool
    ) {
        guard let first = palette.first, pack.scale > 0 else { return }
        for index in quantized.indices {
            let intensity = Double(quantized[index]) / pack.scale
            guard intensity >= pack.minIntensity, intensity >= first.lower else {
                if replace {
                    let base = index * 4
                    rgba[base + 3] = 0
                }
                continue
            }
            let color = color(for: intensity, palette: palette)
            let base = index * 4
            if replace || color[3] > 0 {
                rgba[base] = color[0]
                rgba[base + 1] = color[1]
                rgba[base + 2] = color[2]
                rgba[base + 3] = color[3]
            }
        }
    }

    private static func color(for intensity: Double, palette: [RadarPaletteStep]) -> [UInt8] {
        guard let first = palette.first else { return [0, 0, 0, 0] }
        if intensity <= first.lower { return normalizedRGBA(first.rgba) }
        for nextIndex in palette.indices.dropFirst() {
            let lower = palette[nextIndex - 1]
            let upper = palette[nextIndex]
            if intensity <= upper.lower {
                let span = max(upper.lower - lower.lower, 0.0001)
                let t = min(1.0, max(0.0, (intensity - lower.lower) / span))
                let a = normalizedRGBA(lower.rgba)
                let b = normalizedRGBA(upper.rgba)
                return (0..<4).map { UInt8((Double(a[$0]) + (Double(b[$0]) - Double(a[$0])) * t).rounded()) }
            }
        }
        return normalizedRGBA(palette.last?.rgba ?? first.rgba)
    }

    private static func normalizedRGBA(_ rgba: [UInt8]) -> [UInt8] {
        guard rgba.count >= 4 else { return [0, 0, 0, 0] }
        return Array(rgba.prefix(4))
    }

    private static func featherAlpha(_ rgba: inout [UInt8], width: Int, height: Int, radius: Double) {
        let passes = max(0, min(3, Int(radius.rounded(.up))))
        guard passes > 0, width > 2, height > 2 else { return }
        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<alpha.count {
            alpha[index] = rgba[index * 4 + 3]
        }
        var horizontal = alpha
        var vertical = alpha
        for _ in 0..<passes {
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let left = max(0, x - 1)
                    let right = min(width - 1, x + 1)
                    var total = 0
                    for xx in left...right {
                        total += Int(alpha[row + xx])
                    }
                    horizontal[row + x] = UInt8(total / (right - left + 1))
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    let top = max(0, y - 1)
                    let bottom = min(height - 1, y + 1)
                    var total = 0
                    for yy in top...bottom {
                        total += Int(horizontal[yy * width + x])
                    }
                    vertical[y * width + x] = UInt8(total / (bottom - top + 1))
                }
            }
            swap(&alpha, &vertical)
        }
        for index in 0..<alpha.count {
            rgba[index * 4 + 3] = alpha[index]
        }
    }
}

final class RadarRegionOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let image: CGImage

    init(mapRect: MKMapRect, image: CGImage) {
        self.boundingMapRect = mapRect
        self.coordinate = MKMapPoint(x: mapRect.midX, y: mapRect.midY).coordinate
        self.image = image
        super.init()
    }
}

final class RadarRegionOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? RadarRegionOverlay else { return }
        let rect = self.rect(for: overlay.boundingMapRect)
        context.saveGState()
        context.setAlpha(0.84)
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(overlay.image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}
