// RadarWidgets.swift
// Instrument-mode chrome for the radar screen: thin dark glass, restrained
// controls, accent as tint — deliberately quieter than the emotional
// liquid-glass language of the main screens.
import SwiftUI

/// Rail button in instrument style: 44 pt target, active state via gold
/// tint + ring instead of a filled surface.
struct RadarRoundButton: View {
    let icon: String
    var selected = false
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(selected ? AppColors.selection : .white.opacity(0.88))
                .frame(width: DesignTokens.Control.circle, height: DesignTokens.Control.circle)
                .background(AppColors.Surface.instrumentControl)
                .background(.ultraThinMaterial.opacity(0.7))
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        selected ? AppColors.selection.opacity(0.9) : AppColors.Stroke.control,
                        lineWidth: selected ? 1.5 : 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Compact legend panel — docks directly above the timeline instead of
/// floating over the map.
struct RadarLegendView: View {
    var attribution: String?
    var isFallbackSource = false
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("Niederschlag")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Legende schließen")
            }

            if isFallbackSource {
                // RainViewer fallback tiles use their own palette — showing
                // our scale would be wrong, so we say so instead.
                Text("Ersatzdaten aktiv – Farbskala weicht ab")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(AppColors.selection)
            } else {
                HStack(spacing: 1) {
                    ForEach(RadarLegendStep.steps) { step in
                        step.color.frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
                    }
                }
                .clipShape(Capsule())

                HStack(spacing: 1) {
                    ForEach(RadarLegendStep.steps) { step in
                        Text(step.label)
                            .font(.system(.caption2, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }
                }
                .foregroundStyle(.white.opacity(0.78))

                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 8, height: 8)
                    Text("Schnee weiß/hellblau")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }

            Text(footerText)
                .font(.system(.caption2, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .instrumentPanel()
    }

    private var footerText: String {
        if isFallbackSource {
            return attribution ?? "RainViewer"
        }
        return "DWD-Radarkomposit · Vorhersage: ICON-EU"
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
