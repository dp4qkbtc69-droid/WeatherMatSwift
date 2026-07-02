// TopBarView.swift
import SwiftUI

struct TopBarView: View {
    @Environment(WeatherViewModel.self) private var vm
    @Binding var showLocations: Bool
    let openRainRadar: () -> Void
    @State private var showModelDetails = false
    @State private var showFeedbackDialog = false

    var body: some View {
        ZStack(alignment: .top) {
            // ── Centre: location name ────────────────────────────────────
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    if vm.activeLocation?.isGPS == true {
                        Image(systemName: "location.fill")
                            .font(.footnote)
                    }
                    Text(vm.activeLocation?.name ?? "—")
                        .font(.system(.title3, weight: .semibold))
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
                            .font(.system(.title3, weight: .semibold))
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
                        .frame(maxWidth: 236, alignment: .trailing)

                        // Secondary action: quiet ghost pill.
                        Button {
                            HapticService.impact(.light)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showFeedbackDialog.toggle()
                            }
                        } label: {
                            Label("Wetter melden", systemImage: "cloud.rain.fill")
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(AppColors.Text.secondary)
                                .quietActionPill()
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Öffnet Schnellmeldungen zum aktuellen Wetter")

                        // Primary navigation: the strongest element in the cluster.
                        Button {
                            HapticService.impact(.light)
                            openRainRadar()
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: "map.fill")
                                    .font(.system(.body, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 42, height: 42)
                                    .background(AppColors.Surface.primaryAction)
                                    .background(.ultraThinMaterial.opacity(0.7))
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(AppColors.Stroke.primary, lineWidth: 1))
                                Text("Radar")
                                    .font(.system(.caption2, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Regenradar öffnen")

                        if showFeedbackDialog {
                            WeatherFeedbackPanel { feedback in
                                showFeedbackDialog = false
                                vm.submitWeatherFeedback(feedback)
                            }
                            .frame(maxWidth: 204, alignment: .trailing)
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
                    HStack(spacing: 10) {
                        Image(systemName: feedback.quickReportIcon)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundStyle(feedback.quickReportTint)
                            .frame(width: 34, height: 28)

                        Text(feedback.compactLabel)
                            .font(.system(.callout, weight: .bold))
                            .multilineTextAlignment(.leading)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.22), radius: 1, x: 0, y: 1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 188, height: 52)
                    .background(Color.black.opacity(0.18))
                    .background(.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
    @State private var showModelInfo = false

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
                // Status first, disclosure second: a light outline makes the
                // affordance clear without competing with primary actions.
                HStack(spacing: 6) {
                    TrafficLightView(level: displayConfidence)
                    Text(statusText)
                        .font(.system(.footnote, weight: .semibold))
                    Text("\(displayAgreementPct)%")
                        .font(.system(.footnote, weight: .bold))
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(.caption2, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(AppColors.Text.primary)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(AppColors.Surface.selectedMuted)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isExpanded ? AppColors.selection.opacity(0.65) : AppColors.Stroke.control, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Modellstatus \(statusText), \(displayAgreementPct) Prozent")
            .accessibilityHint(isExpanded ? "Schließt Details zur Modell-Einigkeit" : "Öffnet Details zur Modell-Einigkeit")

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Label(horizonLabel, systemImage: "calendar")
                            .font(.system(.footnote, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))

                        Spacer()

                        Button {
                            HapticService.impact(.light)
                            withAnimation(.easeInOut(duration: 0.16)) {
                                showModelInfo.toggle()
                            }
                        } label: {
                            Image(systemName: showModelInfo ? "info.circle.fill" : "info.circle")
                                .font(.system(.footnote, weight: .bold))
                                .foregroundStyle(showModelInfo ? AppColors.selection : .white.opacity(0.76))
                                .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showModelInfo ? "Modellinformationen ausblenden" : "Modellinformationen anzeigen")
                    }

                    if !confidenceBands.isEmpty {
                        ConfidenceBandsView(bands: confidenceBands)
                    }

                    if showModelInfo {
                        Divider()
                            .background(.white.opacity(0.14))
                            .padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Stärkste Modelle")
                                .font(.system(.caption2, weight: .bold))
                                .foregroundStyle(.white.opacity(0.70))
                            Text(dominantLabel)
                                .font(.system(.caption, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.94))
                                .lineLimit(2)
                                .minimumScaleFactor(0.76)

                            Text(activeModels.isEmpty ? "Keine Quellen aktiv" : activeModels.joined(separator: " · "))
                                .font(.system(.caption2, weight: .medium))
                                .foregroundStyle(.white.opacity(0.66))
                                .lineLimit(2)
                                .minimumScaleFactor(0.76)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(12)
                .frame(width: 236, alignment: .leading)
                .instrumentPanel()
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
                        .font(.system(.caption2, weight: .bold))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(width: 56, alignment: .leading)
                    Text(band.subtitle)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer()
                    Text("\(band.agreementPct)%")
                        .font(.system(.caption2, weight: .bold))
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
                .font(.system(.body, weight: .semibold))
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
                .font(.system(.body, weight: .medium))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                // Preview circle
                ZStack {
                    Circle()
                        .fill(previewBackground)
                        .frame(width: 52, height: 52)
                    Image(systemName: theme.icon)
                        .font(.system(.body, weight: .medium))
                        .foregroundStyle(previewForeground)
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: 52, height: 52)
                    }
                }

                // Labels sit on the dark glass sheet — fixed white with a
                // clear selected/unselected hierarchy in both color schemes.
                Text(theme.label)
                    .font(.system(.footnote, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(labelColor.opacity(isSelected ? 1.0 : 0.64))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(colorScheme == .dark ? 0.10 : 0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusSmall))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Darstellung \(theme.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var previewBackground: Color {
        switch theme {
        case .system: return colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08)
        case .light:  return Color.white.opacity(colorScheme == .dark ? 0.18 : 0.92)
        case .dark:   return Color(white: 0.15)
        }
    }

    private var previewForeground: Color {
        switch theme {
        case .system: return colorScheme == .dark ? .white : Color(hex: "#101820")
        case .light:  return Color(hue: 0.11, saturation: 0.85, brightness: 0.92)
        case .dark:   return Color(hue: 0.65, saturation: 0.45, brightness: 0.85)
        }
    }

    private var labelColor: Color {
        colorScheme == .dark ? .white : Color(hex: "#0d3142")
    }
}
