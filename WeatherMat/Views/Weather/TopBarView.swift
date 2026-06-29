// TopBarView.swift
import SwiftUI

struct TopBarView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Binding var showLocations: Bool
    @State private var showModelDetails = false
    @State private var showFeedbackDialog = false

    var body: some View {
        ZStack(alignment: .top) {
            // ── Centre: location name ────────────────────────────────────
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    if vm.activeLocation?.isGPS == true {
                        Image(systemName: "location.fill")
                            .font(.system(size: 13))
                    }
                    Text(vm.activeLocation?.name ?? "—")
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                .frame(maxWidth: 188)

                // Pager dots
                if vm.savedLocations.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(vm.savedLocations.indices, id: \.self) { i in
                            Circle()
                                .fill(i == vm.activeLocationIndex ? Color.white : Color.white.opacity(0.35))
                                .frame(width: i == vm.activeLocationIndex ? 8 : 6,
                                       height: i == vm.activeLocationIndex ? 8 : 6)
                                .animation(.easeInOut(duration: 0.2), value: vm.activeLocationIndex)
                        }
                    }
                }
            }

            // ── Right: locations icon ────────────────────────────────────
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button {
                        showLocations = true
                    } label: {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if let data = vm.weatherData {
                        ModelStatusButton(
                            confidence: data.confidence,
                            activeModels: data.activeModels,
                            agreementPct: data.agreementPct,
                            confidenceBands: data.confidenceBands,
                            selectedDayIndex: vm.selectedDayIndex,
                            isExpanded: $showModelDetails
                        )
                        .frame(maxWidth: 214, alignment: .trailing)

                        Button {
                            HapticService.impact(.light)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showFeedbackDialog.toggle()
                            }
                        } label: {
                            Label("Wetter melden", systemImage: "cloud.rain.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.white.opacity(0.16))
                                .background(.ultraThinMaterial.opacity(0.62))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        if showFeedbackDialog {
                            WeatherFeedbackPanel { feedback in
                                showFeedbackDialog = false
                                vm.submitWeatherFeedback(feedback)
                            }
                            .frame(maxWidth: 168, alignment: .trailing)
                            .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .alert(
            "Rückmeldung gespeichert",
            isPresented: Binding(
                get: { vm.feedbackMessage != nil },
                set: { if !$0 { vm.feedbackMessage = nil } }
            )
        ) {
            Button("OK") { vm.feedbackMessage = nil }
        } message: {
            Text(vm.feedbackMessage ?? "")
        }
    }
}

// MARK: - Weather feedback
private struct WeatherFeedbackPanel: View {
    let submit: (WeatherFeedback) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WeatherFeedback.quickReportCases) { feedback in
                Button {
                    HapticService.impact(.light)
                    submit(feedback)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: feedback.quickReportIcon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(feedback.quickReportTint)
                            .frame(height: 24)

                        Text(feedback.compactLabel)
                            .font(.system(size: 12, weight: .bold))
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.22), radius: 1, x: 0, y: 1)
                    }
                    .frame(width: 152, height: 54)
                    .background(Color.black.opacity(0.18))
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(feedback.label)
            }
        }
        .padding(8)
        .background(Color.black.opacity(0.22))
        .background(.ultraThinMaterial.opacity(0.92))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// MARK: - Compact model status
struct ModelStatusButton: View {
    let confidence:       ConfidenceLevel
    let activeModels:     [String]
    let agreementPct:     Int
    let confidenceBands:  [ForecastConfidenceBand]
    var selectedDayIndex: Int? = nil
    @Binding var isExpanded: Bool

    private var displayConfidence: ConfidenceLevel {
        selectedBand?.confidence ?? confidence
    }

    private var displayAgreementPct: Int {
        selectedBand?.agreementPct ?? agreementPct
    }

    private var selectedBand: ForecastConfidenceBand? {
        let idx = selectedDayIndex ?? 0
        let id: String
        switch idx {
        case 0: id = "0-24h"
        case 1...3: id = "1-3d"
        default: id = "3-10d"
        }
        return confidenceBands.first { $0.id == id }
    }

    private var statusText: String {
        switch displayConfidence {
        case .high:   return "Modelle gut"
        case .medium: return "Modelle ok"
        case .low:    return "Modelle unsicher"
        }
    }

    private var horizonHours: Double {
        Double((selectedDayIndex ?? 0) * 24 + 12)
    }

    private var horizonLabel: String {
        let idx = selectedDayIndex ?? 0
        return idx == 0 ? "Heute" : "+\(idx) \(idx == 1 ? "Tag" : "Tage")"
    }

    private var dominantLabel: String {
        guard !activeModels.isEmpty else { return "Keine Modelle aktiv" }
        let h = horizonHours
        let scored = activeModels.map { ($0, ForecastModelRules.horizonMultiplier($0, hoursAhead: h)) }
        guard let top = scored.max(by: { $0.1 < $1.1 }) else { return activeModels.joined(separator: " · ") }
        let threshold = top.1 * 0.70
        return scored
            .filter { $0.1 >= threshold }
            .map(\.0)
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button {
                HapticService.impact(.light)
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    TrafficLightView(level: displayConfidence)
                    Text(statusText)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(displayAgreementPct)%")
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.14))
                .background(.ultraThinMaterial.opacity(0.58))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    Label(horizonLabel, systemImage: "calendar")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    if !confidenceBands.isEmpty {
                        ConfidenceBandsView(bands: confidenceBands)
                    }

                    Text("Stärkste Modelle: \(dominantLabel)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(activeModels.isEmpty ? "Aktuell keine Quellen aktiv" : activeModels.joined(separator: " · "))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                }
                .padding(12)
                .frame(width: 214, alignment: .leading)
                .background(Color.black.opacity(0.12))
                .background(.white.opacity(0.12))
                .background(.ultraThinMaterial.opacity(0.78))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

}


private struct ConfidenceBandsView: View {
    let bands: [ForecastConfidenceBand]

    var body: some View {
        VStack(spacing: 5) {
            ForEach(bands) { band in
                HStack(spacing: 7) {
                    Circle()
                        .fill(band.confidence.color)
                        .frame(width: 7, height: 7)
                    Text(band.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(width: 42, alignment: .leading)
                    Text(band.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(band.agreementPct)%")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
    }
}

struct TrafficLightView: View {
    let level: ConfidenceLevel

    var body: some View {
        HStack(spacing: 2) {
            light(.low)
            light(.medium)
            light(.high)
        }
        .padding(3)
        .background(.black.opacity(0.22))
        .clipShape(Capsule())
    }

    private func light(_ candidate: ConfidenceLevel) -> some View {
        Circle()
            .fill(candidate == level ? candidate.color : Color.white.opacity(0.25))
            .frame(width: 6, height: 6)
    }
}

// MARK: - Theme picker sheet
struct ThemePickerSheet: View {
    @Binding var themeName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Darstellung")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 20)
                .padding(.bottom, 16)

            HStack(spacing: 14) {
                ForEach(AppTheme.allCases) { t in
                    ThemeOptionButton(
                        theme: t,
                        isSelected: themeName == t.rawValue
                    ) {
                        HapticService.impact(.light)
                        withAnimation(.easeInOut(duration: 0.2)) {
                            themeName = t.rawValue
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button("Fertig") { dismiss() }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Individual theme option
struct ThemeOptionButton: View {
    let theme:      AppTheme
    let isSelected: Bool
    let action:     () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                // Preview circle
                ZStack {
                    Circle()
                        .fill(previewBackground)
                        .frame(width: 64, height: 64)
                    Image(systemName: theme.icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(previewForeground)
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .frame(width: 64, height: 64)
                    }
                }

                Text(theme.label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var previewBackground: Color {
        switch theme {
        case .system: return Color(.systemFill)
        case .light:  return Color(.systemBackground).opacity(0.1)
        case .dark:   return Color(white: 0.15)
        }
    }

    private var previewForeground: Color {
        switch theme {
        case .system: return .primary
        case .light:  return Color(hue: 0.11, saturation: 0.85, brightness: 0.92)
        case .dark:   return Color(hue: 0.65, saturation: 0.45, brightness: 0.85)
        }
    }
}
