// RadarRegionOverlay.swift
import Accelerate
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

    // Intensity bytes -> CGImage. Per-pixel color/alpha mapping and edge
    // feathering run through Accelerate (vImage table lookups + box
    // convolution) instead of hand-rolled Swift loops: the quantized input is
    // a single byte (0-255), so the whole rain/snow -> RGBA mapping collapses
    // into a 256-entry lookup table applied once per channel across the
    // entire grid in one vectorized call, and the separable box blur that
    // used to run as four nested loops becomes one vImage call per pass.
    // Always called off the main actor (see renderAll/renderFrame above).
    static func render(frame: RadarRegionPack.Frame, pack: RadarRegionPack) -> CGImage? {
        let width = pack.grid.w
        let height = pack.grid.h
        let cellCount = width * height
        guard width > 0, height > 0, frame.intensity.count == cellCount else { return nil }

        let rainLUT = ColorLUT(scale: pack.scale, minimumIntensity: pack.minIntensity, palette: pack.palette.rain)

        var outR = [UInt8](repeating: 0, count: cellCount)
        var outG = [UInt8](repeating: 0, count: cellCount)
        var outB = [UInt8](repeating: 0, count: cellCount)
        var outA = [UInt8](repeating: 0, count: cellCount)
        applyTable(rainLUT.r, to: frame.intensity, width: width, height: height, into: &outR)
        applyTable(rainLUT.g, to: frame.intensity, width: width, height: height, into: &outG)
        applyTable(rainLUT.b, to: frame.intensity, width: width, height: height, into: &outB)
        applyTable(rainLUT.a, to: frame.intensity, width: width, height: height, into: &outA)

        if let snow = frame.snow, snow.count == cellCount {
            let snowLUT = ColorLUT(scale: pack.scale, minimumIntensity: nil, palette: pack.palette.snow)
            // The snow layer fully replaces the rain pixel wherever it paints
            // (matching the original "replace: false, color.alpha > 0" rule)
            // rather than alpha-blending over it, so a 0/255 mask plus a
            // per-channel select reproduces that exactly.
            var mask = [UInt8](repeating: 0, count: cellCount)
            applyTable(snowLUT.mask, to: snow, width: width, height: height, into: &mask)

            var snowR = [UInt8](repeating: 0, count: cellCount)
            var snowG = [UInt8](repeating: 0, count: cellCount)
            var snowB = [UInt8](repeating: 0, count: cellCount)
            var snowA = [UInt8](repeating: 0, count: cellCount)
            applyTable(snowLUT.r, to: snow, width: width, height: height, into: &snowR)
            applyTable(snowLUT.g, to: snow, width: width, height: height, into: &snowG)
            applyTable(snowLUT.b, to: snow, width: width, height: height, into: &snowB)
            applyTable(snowLUT.a, to: snow, width: width, height: height, into: &snowA)

            selectByMask(mask, snowR, outR, into: &outR)
            selectByMask(mask, snowG, outG, into: &outG)
            selectByMask(mask, snowB, outB, into: &outB)
            selectByMask(mask, snowA, outA, into: &outA)
        }

        featherAlpha(&outA, width: width, height: height, radius: pack.featherRadius)

        return makeCGImage(r: outR, g: outG, b: outB, a: outA, width: width, height: height)
    }

    /// 256-entry per-channel lookup tables covering every possible quantized
    /// byte value, built once per frame (negligible cost) so the actual
    /// per-pixel work below is a single Accelerate table lookup instead of a
    /// palette search + interpolation at every cell.
    private struct ColorLUT {
        var r = [UInt8](repeating: 0, count: 256)
        var g = [UInt8](repeating: 0, count: 256)
        var b = [UInt8](repeating: 0, count: 256)
        var a = [UInt8](repeating: 0, count: 256)
        var mask = [UInt8](repeating: 0, count: 256)

        init(scale: Double, minimumIntensity: Double?, palette: [RadarPaletteStep]) {
            guard let first = palette.first, scale > 0 else { return }
            for value in 0...255 {
                let intensity = Double(value) / scale
                if let minimumIntensity, intensity < minimumIntensity { continue }
                guard intensity >= first.lower else { continue }
                let color = Self.color(for: intensity, palette: palette)
                r[value] = color[0]
                g[value] = color[1]
                b[value] = color[2]
                a[value] = color[3]
                mask[value] = color[3] > 0 ? 255 : 0
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
    }

    /// Maps every byte in `source` through `table` via vImage's hardware
    /// table lookup — one vectorized pass over the whole grid.
    private static func applyTable(
        _ table: [UInt8],
        to source: [UInt8],
        width: Int,
        height: Int,
        into dest: inout [UInt8]
    ) {
        source.withUnsafeBufferPointer { srcBuf in
            table.withUnsafeBufferPointer { tableBuf in
                dest.withUnsafeMutableBufferPointer { destBuf in
                    guard let srcBase = srcBuf.baseAddress, let destBase = destBuf.baseAddress else { return }
                    var srcBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: srcBase),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width
                    )
                    var destBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(destBase),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width
                    )
                    _ = vImageTableLookUp_Planar8(&srcBuffer, &destBuffer, tableBuf.baseAddress!, vImage_Flags(kvImageNoFlags))
                }
            }
        }
    }

    /// Per-pixel `mask != 0 ? primary : fallback`, reproducing the "snow
    /// replaces rain wherever it paints" compositing rule from a plain
    /// 0/255 mask. A trivial byte select — no palette search involved
    /// anymore, so a tight Swift loop here is already cheap.
    private static func selectByMask(_ mask: [UInt8], _ primary: [UInt8], _ fallback: [UInt8], into dest: inout [UInt8]) {
        mask.withUnsafeBufferPointer { maskBuf in
            primary.withUnsafeBufferPointer { primaryBuf in
                fallback.withUnsafeBufferPointer { fallbackBuf in
                    dest.withUnsafeMutableBufferPointer { destBuf in
                        for index in 0..<destBuf.count {
                            destBuf[index] = maskBuf[index] != 0 ? primaryBuf[index] : fallbackBuf[index]
                        }
                    }
                }
            }
        }
    }

    /// Separable box blur on the alpha channel, now a single vImage call per
    /// pass instead of the original's four nested loops (horizontal pass,
    /// vertical pass, both by hand). A 3x3 box convolution with edge
    /// extension reproduces one horizontal+vertical 3-tap pass exactly.
    private static func featherAlpha(_ alpha: inout [UInt8], width: Int, height: Int, radius: Double) {
        let passes = max(0, min(3, Int(radius.rounded(.up))))
        guard passes > 0, width > 2, height > 2 else { return }

        var source = alpha
        var scratch = [UInt8](repeating: 0, count: alpha.count)
        for _ in 0..<passes {
            source.withUnsafeMutableBufferPointer { srcBuf in
                scratch.withUnsafeMutableBufferPointer { dstBuf in
                    guard let srcBase = srcBuf.baseAddress, let dstBase = dstBuf.baseAddress else { return }
                    var srcBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(srcBase),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width
                    )
                    var dstBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(dstBase),
                        height: vImagePixelCount(height),
                        width: vImagePixelCount(width),
                        rowBytes: width
                    )
                    // Truncate (not extend) the kernel at the grid edges: this
                    // shrinks the averaging window and normalizes by the
                    // pixels actually used, matching the original hand-rolled
                    // pass's border behavior far more closely than replicating
                    // the edge pixel would.
                    _ = vImageBoxConvolve_Planar8(
                        &srcBuffer, &dstBuffer, nil, 0, 0, 3, 3, 0, vImage_Flags(kvImageTruncateKernel)
                    )
                }
            }
            swap(&source, &scratch)
        }
        alpha = source
    }

    /// Interleaves the four planar channels into one RGBA8888 buffer via
    /// vImage's planar merge, then hands the bytes to CGImage. The merge
    /// function's parameter order is (byte0, byte1, byte2, byte3); passing
    /// R,G,B,A in that order yields R,G,B,A in memory, matching the
    /// `CGImageAlphaInfo.last` layout used below.
    private static func makeCGImage(r: [UInt8], g: [UInt8], b: [UInt8], a: [UInt8], width: Int, height: Int) -> CGImage? {
        let cellCount = width * height
        var interleaved = [UInt8](repeating: 0, count: cellCount * 4)

        let merged: Void? = r.withUnsafeBufferPointer { rBuf in
            g.withUnsafeBufferPointer { gBuf in
                b.withUnsafeBufferPointer { bBuf in
                    a.withUnsafeBufferPointer { aBuf in
                        interleaved.withUnsafeMutableBufferPointer { outBuf -> Void? in
                            guard let rBase = rBuf.baseAddress, let gBase = gBuf.baseAddress,
                                  let bBase = bBuf.baseAddress, let aBase = aBuf.baseAddress,
                                  let outBase = outBuf.baseAddress else { return nil }
                            var planarR = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: rBase),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width
                            )
                            var planarG = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: gBase),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width
                            )
                            var planarB = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: bBase),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width
                            )
                            var planarA = vImage_Buffer(
                                data: UnsafeMutableRawPointer(mutating: aBase),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width
                            )
                            var interleavedBuffer = vImage_Buffer(
                                data: UnsafeMutableRawPointer(outBase),
                                height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4
                            )
                            _ = vImageConvert_Planar8toARGB8888(
                                &planarR, &planarG, &planarB, &planarA, &interleavedBuffer, vImage_Flags(kvImageNoFlags)
                            )
                            return ()
                        }
                    }
                }
            }
        }
        guard merged != nil else { return nil }

        let data = Data(interleaved)
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
