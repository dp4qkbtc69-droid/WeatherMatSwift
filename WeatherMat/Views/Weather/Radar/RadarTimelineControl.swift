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

struct RadarTimelineControl: View {
    let frames: [RainRadarFrame]
    @Binding var selectedIndex: Int
    @Binding var isPlaying: Bool
    let selectedTimeLabel: String
    let selectedDateLabel: String
    let kindLabel: String

    @State private var activeBucketIndex = 0
    private let buckets: [DayBucket]
    private var maxIndex: Int { max(frames.count - 1, 0) }

    init(
        frames: [RainRadarFrame],
        selectedIndex: Binding<Int>,
        isPlaying: Binding<Bool>,
        selectedTimeLabel: String,
        selectedDateLabel: String,
        kindLabel: String
    ) {
        self.frames = frames
        _selectedIndex = selectedIndex
        _isPlaying = isPlaying
        self.selectedTimeLabel = selectedTimeLabel
        self.selectedDateLabel = selectedDateLabel
        self.kindLabel = kindLabel
        buckets = Self.makeBuckets(frames)
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
        guard let activeBucket else { return min(selectedIndex, maxIndex) }
        return max(0, min(selectedIndex - activeBucket.globalStartIndex, displayedMaxIndex))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button { isPlaying.toggle() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(.footnote, weight: .bold))
                        .foregroundStyle(AppColors.selection)
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
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
                                    withAnimation(.easeInOut(duration: 0.18)) {
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
                                        .background(index == activeBucketIndex ? AppColors.selection : Color.white.opacity(0.12))
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

                Text(kindLabel)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let progress = displayedMaxIndex == 0 ? 0 : CGFloat(localSelectedIndex) / CGFloat(displayedMaxIndex)
                let knobX = min(max(progress * width, 12), width - 12)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18)).frame(height: 5).padding(.horizontal, 12).offset(y: 16)
                    Capsule().fill(.white.opacity(0.65)).frame(width: max(8, knobX), height: 5).padding(.leading, 12).offset(y: 16)

                    // Precise forecast boundary: hairline + small plain label,
                    // no floating pill.
                    if let forecast = displayedFrames.firstIndex(where: \.isForecast) {
                        let x = timelineX(forecast, width)
                        Rectangle()
                            .fill(AppColors.selection.opacity(0.9))
                            .frame(width: 1.5, height: 34)
                            .position(x: x, y: 20)
                        Text("Vorhersage")
                            .font(.system(.caption2, weight: .semibold))
                            .foregroundStyle(AppColors.selection)
                            .position(x: min(max(x + 34, 40), width - 40), y: 4)
                    }

                    HStack(alignment: .top, spacing: 0) {
                        ForEach(displayedFrames.indices, id: \.self) { index in
                            VStack(spacing: 3) {
                                RoundedRectangle(cornerRadius: 1)
                                    .fill(.white.opacity(index == localSelectedIndex ? 1 : 0.5))
                                    .frame(width: 1.5, height: tickHeight(index))
                                if showLabel(index) {
                                    Text(tickLabel(index))
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
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .position(x: knobX, y: 18)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let x = min(max(value.location.x, 0), width)
                    let localIndex = Int((x / width * CGFloat(displayedMaxIndex)).rounded())
                    let globalIndex = (activeBucket?.globalStartIndex ?? 0) + localIndex
                    selectedIndex = min(max(globalIndex, 0), maxIndex)
                })
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
        .background(Color.black.opacity(0.45))
        .background(.ultraThinMaterial.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radiusSmall))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radiusSmall)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .onChange(of: selectedIndex) { _, newValue in
            let bucket = buckets.firstIndex(where: { $0.contains(newValue) }) ?? 0
            if bucket != activeBucketIndex {
                withAnimation(.easeInOut(duration: 0.18)) {
                    activeBucketIndex = bucket
                }
            }
        }
    }

    private func timelineX(_ index: Int, _ width: CGFloat) -> CGFloat {
        let inner = max(1, width - 24)
        guard displayedMaxIndex > 0 else { return width / 2 }
        return 12 + CGFloat(index) / CGFloat(displayedMaxIndex) * inner
    }

    private func tickHeight(_ index: Int) -> CGFloat {
        index == localSelectedIndex ? 18 : (showLabel(index) ? 14 : 8)
    }

    private func showLabel(_ index: Int) -> Bool {
        guard displayedFrames.count > 1 else { return true }
        if index == 0 || index == displayedMaxIndex { return true }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: displayedFrames[index].time)
        guard parts.minute == 0, let hour = parts.hour else { return false }
        let step = displayedFrames.count > 36 ? 6 : (displayedFrames.count > 12 ? 3 : 1)
        return hour.isMultiple(of: step)
    }

    private func tickLabel(_ index: Int) -> String {
        guard displayedFrames.indices.contains(index) else { return "" }
        let date = displayedFrames[index].time
        if Calendar.current.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute().locale(.init(identifier: "de_DE")))
        }
        return date.formatted(.dateTime.day().month(.twoDigits).locale(.init(identifier: "de_DE")))
    }

    static func makeBuckets(_ frames: [RainRadarFrame], calendar: Calendar = .current) -> [DayBucket] {
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

    private static func bucket(start: Int, end: Int, frames: [RainRadarFrame], calendar: Calendar) -> DayBucket {
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
}
