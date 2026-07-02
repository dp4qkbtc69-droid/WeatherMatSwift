// RadarWidgets.swift
import SwiftUI

struct RadarRoundButton: View {
    let icon: String
    var selected = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(.title2, weight: .bold))
                .foregroundStyle(selected ? Color(hex: "#5f4500") : .white.opacity(0.90))
                .frame(width: 52, height: 52)
                .background(selected ? Color(hex: "#ffd166") : Color.black.opacity(0.10))
                .background(.white.opacity(selected ? 0.0 : 0.13))
                .background(.ultraThinMaterial.opacity(0.74))
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(selected ? 0.54 : 0.22), lineWidth: 1))
                .shadow(color: .black.opacity(0.16), radius: 12, x: 0, y: 5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct RadarLegendView: View {
    var attribution: String?
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "drop.fill").font(.system(.caption, weight: .bold))
                Text("Niederschlagsintensität")
                    .font(.system(.caption, weight: .bold))
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Legende schließen")
            }

            HStack(spacing: 0) {
                ForEach(RadarLegendStep.steps) { step in
                    step.color.frame(maxWidth: .infinity, minHeight: 9, maxHeight: 9)
                }
            }
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 78), spacing: 7)], alignment: .leading, spacing: 6) {
                ForEach(RadarLegendStep.steps) { step in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(step.color)
                            .frame(width: 8, height: 8)
                        Text(step.label)
                            .font(.system(.caption2, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }
            }
            .foregroundStyle(.white.opacity(0.84))

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 10, height: 10)
                Text("Schnee: weiß/hellblau, wenn ICON-Rohdaten verfügbar sind")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(2)
            }

            if let attribution {
                Text("Datenquelle: \(attribution)")
                    .font(.system(.caption2, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 330)
        .background(Color.black.opacity(0.26))
        .background(.ultraThinMaterial.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.20), lineWidth: 1))
    }
}

struct RadarLegendStep: Identifiable {
    let id: String
    let color: Color
    let label: String

    // Hybrid-Rampe: Blau bis "mäßig", Warnfarben ab "kräftig".
    // Muss synchron zu RAIN_COLOR_STEPS im RadarProxy bleiben.
    static let steps = [
        RadarLegendStep(id: "trace", color: Color(hex: "#cfeefd"), label: "sehr leicht"),
        RadarLegendStep(id: "light", color: Color(hex: "#6fc5f7"), label: "leicht"),
        RadarLegendStep(id: "moderate", color: Color(hex: "#2a78d6"), label: "mäßig"),
        RadarLegendStep(id: "strong", color: Color(hex: "#f7d038"), label: "kräftig"),
        RadarLegendStep(id: "heavy", color: Color(hex: "#f28c28"), label: "stark"),
        RadarLegendStep(id: "severe", color: Color(hex: "#d93025"), label: "extrem")
    ]
}

struct RadarPreviewShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 8, y: rect.midY - 26))
        path.addCurve(to: CGPoint(x: rect.midX - 2, y: rect.midY - 10),
                      control1: CGPoint(x: rect.minX + 26, y: rect.minY + 2),
                      control2: CGPoint(x: rect.midX - 18, y: rect.minY + 8))
        path.addCurve(to: CGPoint(x: rect.midX + 12, y: rect.midY + 30),
                      control1: CGPoint(x: rect.midX + 20, y: rect.midY + 2),
                      control2: CGPoint(x: rect.midX - 6, y: rect.midY + 20))
        path.addCurve(to: CGPoint(x: rect.maxX - 4, y: rect.midY + 6),
                      control1: CGPoint(x: rect.maxX - 8, y: rect.maxY - 8),
                      control2: CGPoint(x: rect.maxX - 12, y: rect.midY + 24))
        path.addCurve(to: CGPoint(x: rect.midX + 6, y: rect.midY - 4),
                      control1: CGPoint(x: rect.maxX - 22, y: rect.midY - 4),
                      control2: CGPoint(x: rect.midX + 24, y: rect.midY - 18))
        path.addCurve(to: CGPoint(x: rect.minX + 8, y: rect.midY - 26),
                      control1: CGPoint(x: rect.midX - 12, y: rect.midY + 8),
                      control2: CGPoint(x: rect.minX + 14, y: rect.midY - 6))
        return path
    }
}

struct RadarGradient: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        LinearGradient(
            stops: [
                .init(color: Color(hex: "#cfeefd"), location: 0.0),
                .init(color: Color(hex: "#6fc5f7"), location: 0.24),
                .init(color: Color(hex: "#2a78d6"), location: 0.50),
                .init(color: Color(hex: "#f7d038"), location: 0.74),
                .init(color: Color(hex: "#d93025"), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
