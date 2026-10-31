// RadarTimelineControl.swift
// Instrument-mode timeline: play + day chips + scrubber. Time and date live
// in the header; the data source shows as a small trailing label.
import SwiftUI

struct DayBucket: Identifiable {
    let id: String
    let shortLabel: String
    let globalStartIndex: Int
    let globalEndIndex: Int
    var range: ClosedRange<Int> { globalStartIndex...globalEndIndex }
    func contains(_ index: Int) -> Bool { index >= globalStartIndex && index <= globalEndIndex }
}

/// Where a timeline frame sits on the measured-radar → ICON-EU-model axis —
/// drives the scrubber's tick tint and the "Nowcast"/"Modell" handoff
/// markers, so the two-day scrubber shows at a glance where extrapolated
/// radar ends and the actual NWP forecast begins.
enum RadarFrameCategory: Equatable {
    case observed
    case nowcast
    case model
}

struct RadarTimelineControl: View {
    let frames: [RainRadarFrame]
    @Binding var selectedIndex: Int
    @Binding var isPlaying: Bool
    let selectedTimeLabel: String
    let selectedDateLabel: String
    let kindLabel: String
    var isBuffering = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activeBucketIndex = 0
    // Live scrub position while a finger is down. The knob/ticks track this
    // immediately (smooth, and cheap — it's local @State, so only this
    // control's body re-evaluates), while the external `selectedIndex`
    // binding — which drives the parent's body, the map overlay, and a
    // region-pack render — is only committed at a throttled rate (see
    // `dragCommitInterval`) instead of on every pixel of movement.
    @State private var liveDragIndex: Int?
    @State private var lastDragCommitAt: Date = .distantPast
    private let dragCommitInterval: TimeInterval = 0.08

    private let buckets: [DayBucket]
    // Per-frame tick label + visibility, computed once in `init` (same
    // timing as `buckets`) instead of re-running Calendar/date-formatting
    // for every visible tick on every body evaluation — which, with the
    // live-drag tracking above, can now happen on every pixel of a scrub.
    private let tickLabels: [String]
    private let tickShowsLabel: [Bool]
    // Per-frame category (for tick tinting) and the handoff points between
    // categories (for the boundary markers) — computed once in `init`
    // alongside `tickLabels`/`buckets`, for the same reason: no Codable/date
    // work left to run on every body evaluation while scrubbing.
    private let frameCategories: [RadarFrameCategory]
    private let categoryTransitions: [(index: Int, category: RadarFrameCategory)]

    private var maxIndex: Int { max(frames.count - 1, 0) }

    init(
        frames: [RainRadarFrame],
        selectedIndex: Binding<Int>,
        isPlaying: Binding<Bool>,
        selectedTimeLabel: String,
        selectedDateLabel: String,
        kindLabel: String,
        isBuffering: Bool = false
    ) {
        self.frames = frames
        _selectedIndex = selectedIndex
        _isPlaying = isPlaying
        self.selectedTimeLabel = selectedTimeLabel
        self.selectedDateLabel = selectedDateLabel
        self.kindLabel = kindLabel
        self.isBuffering = isBuffering
        let computedBuckets = Self.makeBuckets(frames)
        buckets = computedBuckets
        let display = Self.computeTickDisplay(frames: frames, buckets: computedBuckets)
        tickLabels = display.labels
        tickShowsLabel = display.showLabel
        frameCategories = frames.map(Self.category(for:))
        categoryTransitions = Self.categoryTransitions(frames)
    }

    /// The index to actually display: the live drag position while
    /// scrubbing, otherwise the committed `selectedIndex`.
    private var effectiveIndex: Int {
        liveDragIndex ?? selectedIndex
    }

    private var effectiveCategory: RadarFrameCategory {
        frameCategories.indices.contains(effectiveIndex) ? frameCategories[effectiveIndex] : .observed
    }

    private func color(for category: RadarFrameCategory) -> Color {
        switch category {
        case .observed: return .white
        case .nowcast: return AppColors.selection
        case .model: return AppColors.accent
        }
    }

    private var activeBucket: DayBucket? {
        buckets.indices.contains(activeBucketIndex) ? buckets[activeBucketIndex] : nil
    }

    private var displayedFrames: [RainRadarFrame] {
        guard let activeBucket else { return frames }
        return Array(frames[activeBucket.range])
    }

    private var displayedMaxIndex: Int { max(displayedFrames.count - 1, 0) }

    private var localSelectedIndex: Int {
        guard let activeBucket else { return min(effectiveIndex, maxIndex) }
        return max(0, min(effectiveIndex - activeBucket.globalStartIndex, displayedMaxIndex))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { isPlaying.toggle() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppColors.selection)
                        .frame(width: DesignTokens.Control.compactCircle, height: DesignTokens.Control.compactCircle)
                        .background(AppColors.Surface.quietAction)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(AppColors.Stroke.control, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Wiedergabe pausieren" : "Wiedergabe starten")

                if buckets.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                                Button {
                                    // Jumping to another day always stops playback so
                                    // the animation doesn't immediately run off the
                                    // freshly selected (and possibly unwarmed) frame.
                                    isPlaying = false
                                    withAnimation(radarAnimation(.quick)) {
                                        activeBucketIndex = index
                                    }
                                    if !bucket.contains(selectedIndex) {
                                        selectedIndex = bucket.globalStartIndex
                                    }
                                } label: {
                                    Text(bucket.shortLabel)
                                        .font(.system(.caption, weight: .semibold))
                                        .foregroundStyle(index == activeBucketIndex ? AppColors.selectionText : .white.opacity(0.92))
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(index == activeBucketIndex ? AppColors.selection : AppColors.Surface.selectedMuted)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Tag \(bucket.shortLabel)")
                                .accessibilityAddTraits(index == activeBucketIndex ? .isSelected : [])
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                } else {
                    Spacer()
                }

                // Subtle readiness indicator while playback holds for a frame
                // ("Loading/Buffering" state — no big spinner on the map).
                if isBuffering {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.7))
                        .transition(.opacity)
                }

            }
            .foregroundStyle(.white)
            .animation(radarAnimation(.standard), value: isBuffering)

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let progress = displayedMaxIndex == 0 ? 0 : CGFloat(localSelectedIndex) / CGFloat(displayedMaxIndex)
                let knobX = min(max(progress * width, 12), width - 12)
                let bucketStart = activeBucket?.globalStartIndex ?? 0

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5).padding(.horizontal, 12).offset(y: 16)
                    Capsule().fill(.white.opacity(0.65)).frame(width: max(8, knobX), height: 5).padding(.leading, 12).offset(y: 16)

                    Text(kindLabel)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundStyle(effectiveCategory == .observed ? .white.opacity(0.72) : color(for: effectiveCategory))
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                        .animation(radarAnimation(.standard), value: kindLabel)
                        .position(x: max(42, width - 46), y: 4)

                    // Handoff markers: hairline + small plain label at each
                    // category change (observed → nowcast → model), so the
                    // two-day scrubber shows at a glance where extrapolated
                    // radar ends and the ICON-EU model forecast begins —
                    // not just a single generic "forecast starts" boundary.
                    ForEach(categoryTransitions.indices, id: \.self) { transitionIndex in
                        let transition = categoryTransitions[transitionIndex]
                        if let activeBucket, activeBucket.contains(transition.index) {
                            let x = timelineX(transition.index - activeBucket.globalStartIndex, width)
                            let tint = color(for: transition.category)
                            Rectangle()
                                .fill(tint.opacity(0.9))
                                .frame(width: 1.5, height: 34)
                                .position(x: x, y: 20)
                            Text(transition.category == .model ? "Modell" : "Nowcast")
                                .font(.system(.caption2, weight: .semibold))
                                .foregroundStyle(tint)
                                .position(x: min(max(x + 34, 40), width - 40), y: 4)
                        }
                    }

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(displayedFrames.indices, id: \.self) { index in
                            let globalIndex = bucketStart + index
                            let showsLabel = tickShowsLabel.indices.contains(globalIndex) && tickShowsLabel[globalIndex]
                            let category = frameCategories.indices.contains(globalIndex) ? frameCategories[globalIndex] : .observed
                            let tickColor = category == .model ? color(for: .model) : .white
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(tickColor.opacity(index == localSelectedIndex ? 1 : (category == .model ? 0.62 : 0.5)))
                                    .frame(width: 1.5, height: tickHeight(index, showsLabel: showsLabel))
                                if showsLabel {
                                    Text(tickLabels[globalIndex])
                                        .font(.system(.caption2, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 12)
                    .offset(y: 8)

                    Circle()
                        .fill(AppColors.selection)
                        .frame(width: DesignTokens.Control.timelineKnob, height: DesignTokens.Control.timelineKnob)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .position(x: knobX, y: 18)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = min(max(value.location.x, 0), width)
                        let localIndex = Int((x / width * CGFloat(displayedMaxIndex)).rounded())
                        let globalIndex = min(max(bucketStart + localIndex, 0), maxIndex)
                        liveDragIndex = globalIndex
                        let now = Date()
                        guard now.timeIntervalSince(lastDragCommitAt) >= dragCommitInterval else { return }
                        lastDragCommitAt = now
                        selectedIndex = globalIndex
                    }
                    .onEnded { _ in
                        if let liveDragIndex {
                            selectedIndex = liveDragIndex
                        }
                        self.liveDragIndex = nil
                        lastDragCommitAt = .distantPast
                    }
                )
            }
            .frame(height: 52)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Zeitleiste")
            .accessibilityValue("\(selectedDateLabel), \(selectedTimeLabel), \(kindLabel)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    selectedIndex = min(selectedIndex + 1, maxIndex)
                case .decrement:
                    selectedIndex = max(selectedIndex - 1, 0)
                @unknown default:
                    break
                }
            }
        }
        .padding(8)
        .instrumentPanel()
        .onChange(of: effectiveIndex) { _, newValue in
            let bucket = buckets.firstIndex(where: { $0.contains(newValue) }) ?? 0
            if bucket != activeBucketIndex {
                withAnimation(radarAnimation(.quick)) {
                    activeBucketIndex = bucket
                }
            }
        }
    }

    private enum TimelineAnimationKind {
        case quick
        case standard
    }

    private func radarAnimation(_ kind: TimelineAnimationKind) -> Animation? {
        guard !reduceMotion else { return nil }
        switch kind {
        case .quick:
            return .easeInOut(duration: DesignTokens.Motion.quick)
        case .standard:
            return .easeInOut(duration: DesignTokens.Motion.standard)
        }
    }

    private func timelineX(_ index: Int, _ width: CGFloat) -> CGFloat {
        let inner = max(1, width - 24)
        guard displayedMaxIndex > 0 else { return width / 2 }
        return 12 + CGFloat(index) / CGFloat(displayedMaxIndex) * inner
    }

    private func tickHeight(_ index: Int, showsLabel: Bool) -> CGFloat {
        index == localSelectedIndex ? 18 : (showsLabel ? 14 : 8)
    }

    // Pure data logic, no UI access — nonisolated so it stays callable from a
    // synchronous, non-@MainActor context (e.g. plain unit tests) instead of
    // inheriting @MainActor isolation from this View conformance.
    nonisolated static func makeBuckets(_ frames: [RainRadarFrame], calendar: Calendar = .current) -> [DayBucket] {
        guard !frames.isEmpty else { return [] }
        var buckets: [DayBucket] = []
        var start = 0
        for index in frames.indices.dropFirst() where !calendar.isDate(frames[index].time, inSameDayAs: frames[start].time) {
            buckets.append(bucket(start: start, end: index - 1, frames: frames, calendar: calendar))
            start = index
        }
        buckets.append(bucket(start: start, end: frames.count - 1, frames: frames, calendar: calendar))
        return buckets
    }

    private nonisolated static func bucket(start: Int, end: Int, frames: [RainRadarFrame], calendar: Calendar) -> DayBucket {
        let date = frames[start].time
        let short: String
        if calendar.isDateInToday(date) {
            short = "Heute"
        } else if calendar.isDateInTomorrow(date) {
            short = "Morgen"
        } else {
            short = date.formatted(.dateTime.weekday(.abbreviated).locale(.init(identifier: "de_DE")))
        }
        return DayBucket(id: "\(start)", shortLabel: short, globalStartIndex: start, globalEndIndex: end)
    }

    /// Precomputes, once per `frames` array, which ticks show a label and
    /// what that label says — the per-tick work (`Calendar.dateComponents`,
    /// date formatting) this replaces used to run from inside `body` for
    /// every visible tick on every single re-render. Not private, like
    /// `makeBuckets`, so pure-logic tests can call it directly.
    nonisolated static func computeTickDisplay(
        frames: [RainRadarFrame],
        buckets: [DayBucket],
        calendar: Calendar = .current
    ) -> (labels: [String], showLabel: [Bool]) {
        guard !frames.isEmpty else { return ([], []) }
        var labels = [String](repeating: "", count: frames.count)
        var show = [Bool](repeating: false, count: frames.count)
        for bucket in buckets {
            let bucketCount = bucket.globalEndIndex - bucket.globalStartIndex + 1
            guard bucketCount > 0 else { continue }
            let bucketMaxLocalIndex = bucketCount - 1
            let step = bucketCount > 36 ? 6 : (bucketCount > 12 ? 3 : 1)
            for globalIndex in bucket.range {
                let localIndex = globalIndex - bucket.globalStartIndex
                let shouldShow: Bool
                if bucketCount <= 1 || localIndex == 0 || localIndex == bucketMaxLocalIndex {
                    shouldShow = true
                } else {
                    let parts = calendar.dateComponents([.hour, .minute], from: frames[globalIndex].time)
                    if parts.minute == 0, let hour = parts.hour {
                        shouldShow = hour.isMultiple(of: step)
                    } else {
                        shouldShow = false
                    }
                }
                show[globalIndex] = shouldShow
                if shouldShow {
                    labels[globalIndex] = Self.formattedTickLabel(for: frames[globalIndex].time, calendar: calendar)
                }
            }
        }
        return (labels, show)
    }

    /// Pure classification, no UI access — `nonisolated` for the same reason
    /// as `makeBuckets`/`computeTickDisplay`: callable from plain unit tests.
    nonisolated static func category(for frame: RainRadarFrame) -> RadarFrameCategory {
        guard frame.isForecast else { return .observed }
        switch frame.sourceKind {
        case .iconEu, .iconEuRaw:
            return .model
        case .dwdRadar, .rainViewer, .unknown:
            return .nowcast
        }
    }

    /// Global indices where the category changes from the previous frame —
    /// in a chronologically sorted timeline this is at most two entries
    /// (observed→nowcast, nowcast→model), or just one when the model
    /// forecast starts immediately with no separate nowcast window.
    nonisolated static func categoryTransitions(_ frames: [RainRadarFrame]) -> [(index: Int, category: RadarFrameCategory)] {
        guard !frames.isEmpty else { return [] }
        var transitions: [(index: Int, category: RadarFrameCategory)] = []
        var previous = category(for: frames[0])
        for index in frames.indices.dropFirst() {
            let current = category(for: frames[index])
            if current != previous {
                transitions.append((index, current))
                previous = current
            }
        }
        return transitions
    }

    private nonisolated static func formattedTickLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
        }
        return date.formatted(.dateTime.day().month(.twoDigits).locale(.init(identifier: "de_DE")))
    }
}
