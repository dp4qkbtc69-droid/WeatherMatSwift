// WeatherParticleView.swift
// Animated particle overlay for each weather background type.
// All particle systems use Canvas + TimelineView — zero UIKit, zero state arrays.
import SwiftUI

// MARK: - Container

struct WeatherParticleView: View {
    let background: WeatherBackground
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase)  private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Target FPS for particle systems — halved in Low Power Mode.
    private var particleFPS: Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? 10 : 30
    }

    var body: some View {
        ZStack {
            background.gradient(for: colorScheme)
            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.22 : 0.14),
                    Color.black.opacity(colorScheme == .dark ? 0.08 : 0.03),
                    Color.black.opacity(colorScheme == .dark ? 0.30 : 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Pause all particle animations when the app is inactive / backgrounded
            if scenePhase == .active && !reduceMotion {
                particleLayer
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var particleLayer: some View {
        switch background {
        case .rainy:
            RainCanvas(count: 80, intensity: 0.55, fps: particleFPS)
        case .stormy:
            ZStack {
                RainCanvas(count: 130, intensity: 1.0, fps: particleFPS)
                LightningFlash()
            }
        case .snowy:
            SnowCanvas(count: 55, fps: particleFPS * 0.8)   // snow is slow — slightly lower fps
        case .sunny:
            SunGlowView()
        case .night:
            StarCanvas(count: 60, showMoon: false)
        case .nightClear:
            StarCanvas(count: 85, showMoon: true)
        case .cloudy:
            CloudDriftCanvas()
        case .foggy:
            FogCanvas()
        }
    }
}

// MARK: - Helpers

/// Fractional part of a Double (always ≥ 0)
private func frac(_ x: Double) -> Double { x - floor(x) }

// MARK: - Rain

struct RainCanvas: View {
    let count:     Int
    let intensity: Double   // 0…1
    let fps:       Double   // target frames per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps)) { tl in
            Canvas { ctx, size in
                let t     = tl.date.timeIntervalSinceReferenceDate
                let angle = 0.18 * intensity          // wind lean (radians)
                let sinA  = sin(angle)
                let cosA  = cos(angle)

                for i in 0..<count {
                    let fi     = Double(i)
                    let xNorm  = frac(fi * 0.618033988749)
                    let speed  = (380 + frac(fi * 0.3819660112501) * 380) * intensity
                    let phase  = frac(fi * 0.9754896382)
                    let alpha  = 0.12 + frac(fi * 0.7548776662) * 0.25
                    let length = 12.0 + frac(fi * 0.5698402909) * 18.0
                    let lw     = 0.6 + frac(fi * 0.4375) * 0.9

                    let h    = size.height + length + 20
                    let rawY = frac(t * speed / h + phase) * h - length
                    let rawX = xNorm * (size.width + 80) - 40 + rawY * sinA

                    var p = Path()
                    p.move(to: CGPoint(x: rawX,             y: rawY))
                    p.addLine(to: CGPoint(x: rawX - sinA * length,
                                          y: rawY + cosA * length))
                    ctx.stroke(p,
                               with: .color(.white.opacity(alpha)),
                               style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
        }
    }
}

// MARK: - Lightning (stormy only)

struct LightningFlash: View {
    @State private var flashOpacity: Double = 0
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        Rectangle()
            .fill(.white.opacity(flashOpacity))
            .ignoresSafeArea()
            .onAppear  { flashTask = Task { await flashLoop() } }
            .onDisappear { flashTask?.cancel(); flashTask = nil }
    }

    private func flashLoop() async {
        while !Task.isCancelled {
            let delay = Double.random(in: 5...18)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // double flash
            await MainActor.run { withAnimation(.easeIn(duration: 0.04))  { flashOpacity = 0.28 } }
            try? await Task.sleep(nanoseconds: 60_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.12)) { flashOpacity = 0    } }
            try? await Task.sleep(nanoseconds: 180_000_000)
            await MainActor.run { withAnimation(.easeIn(duration: 0.04))  { flashOpacity = 0.18 } }
            try? await Task.sleep(nanoseconds: 60_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.18)) { flashOpacity = 0    } }
        }
    }
}

// MARK: - Snow

struct SnowCanvas: View {
    let count: Int
    let fps:   Double   // target frames per second

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / fps)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate

                for i in 0..<count {
                    let fi     = Double(i)
                    let xNorm  = frac(fi * 0.618033988749)
                    let speed  = 45 + frac(fi * 0.3819660112501) * 85   // 45–130 px/s
                    let phase  = frac(fi * 0.9754896382)
                    let r      = 1.2 + frac(fi * 0.5698402909) * 2.8    // 1.2–4 px radius
                    let alpha  = 0.45 + frac(fi * 0.7548776662) * 0.45
                    let swayA  = 18 + frac(fi * 0.4142135623) * 36      // sway amplitude px
                    let swayF  = 0.28 + frac(fi * 0.2360679774) * 0.65  // sway frequency Hz

                    let h    = size.height + r * 2 + 10
                    let rawY = frac(t * speed / h + phase) * h - r
                    let rawX = xNorm * size.width
                    let swayX = rawX + sin(t * swayF * .pi * 2 + fi * 2.399963) * swayA

                    ctx.fill(
                        Path(ellipseIn: CGRect(x: swayX - r, y: rawY - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(alpha))
                    )
                }
            }
        }
    }
}

// MARK: - Sun glow

struct SunGlowView: View {
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width  * 0.52
            let cy = geo.size.height * 0.20

            ZStack {
                // Outer soft glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#FFD580").opacity(0.30), .clear],
                            center: .center, startRadius: 0, endRadius: 220
                        )
                    )
                    .frame(width: 440, height: 440)
                    .blur(radius: 40)
                    .scaleEffect(pulse ? 1.18 : 1.0)
                    .position(x: cx, y: cy)

                // Inner bright core
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(hex: "#FFF5C0").opacity(0.45), .clear],
                            center: .center, startRadius: 0, endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)
                    .blur(radius: 12)
                    .scaleEffect(pulse ? 1.10 : 0.95)
                    .position(x: cx, y: cy)

                // Light rays (rotates very slowly)
                TimelineView(.animation(minimumInterval: 1 / 10)) { tl in
                    Canvas { ctx, size in
                        let t   = tl.date.timeIntervalSinceReferenceDate
                        let rpm = 0.8   // full rotation per minute
                        let baseAngle = t * rpm / 60 * .pi * 2

                        for i in 0..<8 {
                            let angle   = baseAngle + Double(i) * .pi / 4
                            let inner   = 95.0
                            let outer   = 160.0 + Double(i % 2) * 40
                            let x1 = cx + cos(angle) * inner
                            let y1 = cy + sin(angle) * inner
                            let x2 = cx + cos(angle) * outer
                            let y2 = cy + sin(angle) * outer
                            var p = Path()
                            p.move(to: CGPoint(x: x1, y: y1))
                            p.addLine(to: CGPoint(x: x2, y: y2))
                            ctx.stroke(p,
                                       with: .color(Color(hex: "#FFE9A0").opacity(0.18)),
                                       style: StrokeStyle(lineWidth: 18, lineCap: .round))
                        }
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - Stars

struct StarCanvas: View {
    let count:     Int
    let showMoon:  Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate

                // Stars
                for i in 0..<count {
                    let fi    = Double(i)
                    let x     = frac(fi * 0.618033988749) * size.width
                    let y     = frac(fi * 0.3819660112501) * size.height * 0.72  // top 72%
                    let r     = 0.7 + frac(fi * 0.7548776662) * 1.6
                    let freq  = 0.28 + frac(fi * 0.2360679774) * 1.1
                    let phase = fi * 2.399963228083
                    let alpha = 0.30 + 0.62 * (0.5 + 0.5 * sin(t * freq * .pi * 2 + phase))

                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(.white.opacity(alpha))
                    )
                }

                // Moon (nightClear only)
                if showMoon {
                    let mx = size.width  * 0.76
                    let my = size.height * 0.13
                    let mr = 34.0
                    // Glow
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: mx - mr * 2.2, y: my - mr * 2.2,
                                               width: mr * 4.4, height: mr * 4.4)),
                        with: .color(.white.opacity(0.04))
                    )
                    // Disc
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: mx - mr, y: my - mr, width: mr * 2, height: mr * 2)),
                        with: .color(.white.opacity(0.88))
                    )
                    // Crater-shadow to suggest crescent (offset disc drawn darker)
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: mx - mr + mr * 0.38,
                                               y: my - mr - mr * 0.08,
                                               width: mr * 1.85, height: mr * 1.85)),
                        with: .color(Color(hex: "#06091a").opacity(0.90))
                    )
                }
            }
        }
    }
}

// MARK: - Cloud drift

struct CloudDriftCanvas: View {
    private struct CloudDef {
        let yFrac: Double; let scale: Double
        let speed: Double; let alpha: Double; let phase: Double
    }

    private let clouds: [CloudDef] = [
        .init(yFrac: 0.12, scale: 2.0, speed: 22, alpha: 0.055, phase: 0.00),
        .init(yFrac: 0.28, scale: 1.4, speed: 14, alpha: 0.045, phase: 0.28),
        .init(yFrac: 0.44, scale: 2.3, speed: 28, alpha: 0.050, phase: 0.55),
        .init(yFrac: 0.62, scale: 1.7, speed: 18, alpha: 0.040, phase: 0.82),
        .init(yFrac: 0.22, scale: 1.1, speed: 10, alpha: 0.035, phase: 0.12),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for cloud in clouds {
                    let y    = cloud.yFrac * size.height
                    let tw   = size.width + 400 * cloud.scale
                    let rawX = frac(cloud.phase + t * cloud.speed / tw) * tw - 200 * cloud.scale
                    let s    = cloud.scale
                    let col  = GraphicsContext.Shading.color(.white.opacity(cloud.alpha))

                    // 5-circle cloud shape
                    for (dx, dy, w, h): (Double, Double, Double, Double) in [
                        (0,   0,  180, 70),
                        (-70, -22, 120, 78),
                        (72, -18, 130, 74),
                        (-28, -48, 88, 64),
                        (42, -45, 100, 68),
                    ] {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: rawX + dx*s - w*s/2,
                                                   y: y    + dy*s - h*s/2,
                                                   width:  w * s,
                                                   height: h * s)),
                            with: col
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Fog

struct FogCanvas: View {
    private struct Band {
        let yFrac: Double; let h: Double
        let speed: Double; let alpha: Double; let phase: Double
    }

    private let bands: [Band] = [
        .init(yFrac: 0.20, h: 90,  speed: 14, alpha: 0.07, phase: 0.00),
        .init(yFrac: 0.38, h: 70,  speed: 10, alpha: 0.06, phase: 0.33),
        .init(yFrac: 0.55, h: 110, speed: 18, alpha: 0.07, phase: 0.66),
        .init(yFrac: 0.72, h: 80,  speed: 12, alpha: 0.05, phase: 0.15),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                for band in bands {
                    let y  = band.yFrac * size.height - band.h / 2
                    let tw = size.width * 2.2
                    let x  = -(frac(band.phase + t * band.speed / tw) * tw)
                    ctx.fill(
                        Path(roundedRect: CGRect(x: x, y: y, width: tw, height: band.h),
                             cornerRadius: band.h / 2),
                        with: .color(.white.opacity(band.alpha))
                    )
                }
            }
        }
    }
}
