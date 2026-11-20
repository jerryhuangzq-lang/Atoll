import Defaults
import SwiftUI

private let lyricSilenceThreshold = 5.0
// Show each line this early; the fill sweep still follows the LRC timestamp.
private let lyricAppearLead = 0.15
private let lyricIdleStepCap = 2.0

@MainActor
struct ClosedNotchLyricRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var musicManager: MusicManager
    @Default(.playerColorTinting) private var playerColorTinting
    @Default(.lyricSyncOffset) private var lyricSyncOffset
    @Default(.lyricFontSize) private var lyricFontSize

    private var rowHeight: CGFloat {
        CGFloat(ceil(lyricFontSize * 1.45))
    }

    private var textColor: Color {
        playerColorTinting
            ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6)
            : .gray
    }

    private var timelineSchedule: LyricTimelineSchedule {
        LyricTimelineSchedule(
            syncedLyrics: musicManager.syncedLyrics,
            lineTimings: musicManager.lyricLineTimings,
            elapsedTime: musicManager.elapsedTime,
            timestampDate: musicManager.timestampDate,
            playbackRate: musicManager.playbackRate,
            isPlaying: musicManager.isPlaying,
            songDuration: musicManager.songDuration,
            syncOffset: lyricSyncOffset,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        let currentRowHeight = rowHeight
        let currentColor = textColor

        GeometryReader { geometry in
            let rowWidth = max(0, geometry.size.width)
            TimelineView(timelineSchedule) { timeline in
                let elapsed = musicManager.estimatedPlaybackPosition(at: timeline.date) + lyricSyncOffset
                let lyrics = musicManager.syncedLyrics
                let timings = musicManager.lyricLineTimings
                if let index = LyricTiming.lyricIndex(in: lyrics, at: elapsed + lyricAppearLead) {
                    let line = lyrics[index]
                    let lineStart = line.timestamp
                    let timing = timings.indices.contains(index) ? timings[index] : nil
                    let sungSeconds = timing?.sungSeconds
                    let phrases = timing?.phrases
                    let nextIndex = index + 1
                    let nextStart = lyrics.indices.contains(nextIndex)
                        ? lyrics[nextIndex].timestamp : nil
                    ClosedNotchLyricLine(
                        line: line.text,
                        width: rowWidth,
                        rowHeight: currentRowHeight,
                        fontSize: lyricFontSize,
                        progress: reduceMotion
                            ? 1
                            : lyricFillProgress(
                                elapsed: elapsed,
                                lineStart: lineStart,
                                sungSeconds: sungSeconds,
                                phrases: phrases
                            ),
                        isSilent: lyricIsSilent(
                            elapsed: elapsed,
                            lineStart: lineStart,
                            sungSeconds: sungSeconds,
                            nextStart: nextStart
                        ),
                        reduceMotion: reduceMotion,
                        color: currentColor
                    )
                    .id(line.id)
                }
            }
        }
        .frame(height: currentRowHeight)
        .clipped()
    }
}

@MainActor
private struct ClosedNotchLyricLine: View {
    let line: String
    let width: CGFloat
    let rowHeight: CGFloat
    let fontSize: Double
    let progress: CGFloat
    let isSilent: Bool
    let reduceMotion: Bool
    let color: Color

    private var lyricMask: LinearGradient {
        let fill = reduceMotion ? 1 : progress
        return LinearGradient(
            colors: [.white, .white.opacity(0.45)],
            startPoint: UnitPoint(x: fill * 1.3 - 0.3, y: 0.5),
            endPoint: UnitPoint(x: fill * 1.3, y: 0.5)
        )
    }

    var body: some View {
        ClosedNotchLyricText(
            line: line,
            width: width,
            rowHeight: rowHeight,
            fontSize: fontSize,
            color: color
        )
        .equatable()
        .mask { lyricMask }
        .frame(width: width, height: rowHeight)
        .clipped()
        .opacity(isSilent ? 0 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: isSilent)
    }
}

@MainActor
private struct ClosedNotchLyricText: View, Equatable {
    let line: String
    let width: CGFloat
    let rowHeight: CGFloat
    let fontSize: Double
    let color: Color

    private var marqueeFontStyle: NSFont.TextStyle {
        if fontSize <= 11 { return .caption2 }
        if fontSize < 14 { return .body }
        return .title3
    }

    var body: some View {
        let font = Font.system(size: CGFloat(fontSize), weight: .medium, design: .rounded)

        ViewThatFits(in: .horizontal) {
            Text(line)
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            MarqueeText(
                .constant(line),
                font: font,
                nsFont: marqueeFontStyle,
                textColor: color,
                minDuration: 1,
                frameWidth: width
            )
            .lineLimit(1)
            .frame(width: width, height: rowHeight)
            .clipped()
        }
    }
}

private struct LyricTimelineSchedule: TimelineSchedule {
    let syncedLyrics: [LyricLine]
    let lineTimings: [LyricLineTiming]
    let elapsedTime: TimeInterval
    let timestampDate: Date
    let playbackRate: Double
    let isPlaying: Bool
    let songDuration: TimeInterval
    let syncOffset: Double
    let reduceMotion: Bool

    private func stepInterval(at date: Date) -> TimeInterval {
        guard isPlaying, playbackRate > 0, songDuration > 0,
              let firstStart = syncedLyrics.first?.timestamp else {
            return lyricIdleStepCap
        }

        let rawEstimated = elapsedTime + date.timeIntervalSince(timestampDate) * playbackRate
        // Once playback reaches the clamped duration ceiling, elapsed stops advancing.
        guard rawEstimated < songDuration else { return lyricIdleStepCap }

        let elapsed = max(0, rawEstimated) + syncOffset
        let rate = playbackRate

        guard let index = LyricTiming.lyricIndex(in: syncedLyrics, at: elapsed + lyricAppearLead) else {
            let wait = (firstStart - lyricAppearLead - elapsed) / rate + 0.001
            return min(max(1.0 / 60.0, wait), lyricIdleStepCap)
        }

        let lineStart = syncedLyrics[index].timestamp
        let nextStart = (index + 1 < syncedLyrics.count) ? syncedLyrics[index + 1].timestamp : nil
        let timing = lineTimings.indices.contains(index) ? lineTimings[index] : nil
        let lineSung = timing?.sungSeconds
        let phrases = timing?.phrases
        let position = elapsed - lineStart

        if !reduceMotion, let lineSung, let phrases, !phrases.isEmpty, position < lineSung {
            for phrase in phrases {
                if position < phrase.start {
                    let wait = (lineStart + phrase.start - elapsed) / rate + 0.001
                    return min(max(1.0 / 60.0, wait), lyricIdleStepCap)
                }
                if position < phrase.end {
                    let remaining = (lineStart + phrase.end - elapsed) / rate + 0.001
                    return min(1.0 / 30.0, max(1.0 / 60.0, remaining))
                }
            }
        }

        var nextBoundary: Double?
        if let lineSung {
            let silenceStart = lineStart + lineSung + lyricSilenceThreshold
            if elapsed < silenceStart {
                nextBoundary = silenceStart
            }
        }
        if let nextStart, elapsed < nextStart - lyricAppearLead {
            let nextAppear = nextStart - lyricAppearLead
            nextBoundary = nextBoundary.map { min($0, nextAppear) } ?? nextAppear
        }

        guard let target = nextBoundary else { return lyricIdleStepCap }
        let wait = (target - elapsed) / rate + 0.001
        return min(max(1.0 / 60.0, wait), lyricIdleStepCap)
    }

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var nextDate = startDate
        return AnyIterator {
            let current = nextDate
            let step = stepInterval(at: current)
            nextDate = current.addingTimeInterval(mode == .lowFrequency ? max(step, 0.25) : step)
            return current
        }
    }
}

private func lyricFillProgress(
    elapsed: Double,
    lineStart: Double,
    sungSeconds: Double?,
    phrases: [LyricPhraseTiming]?
) -> CGFloat {
    guard let sungSeconds, sungSeconds > 0, let phrases, !phrases.isEmpty else { return 1 }
    let position = elapsed - lineStart
    if position <= 0 { return 0 }
    if position >= sungSeconds { return 1 }
    var fraction = 0.0
    for phrase in phrases {
        if position < phrase.start { return CGFloat(fraction) }
        if position < phrase.end {
            let span = phrase.end - phrase.start
            guard span > 0 else { return CGFloat(phrase.endFraction) }
            let progress = (position - phrase.start) / span
            return CGFloat(fraction + (phrase.endFraction - fraction) * progress)
        }
        fraction = phrase.endFraction
    }
    return CGFloat(fraction)
}

private func lyricIsSilent(
    elapsed: Double,
    lineStart: Double,
    sungSeconds: Double?,
    nextStart: Double?
) -> Bool {
    guard let sungSeconds else { return false }
    let silenceStart = lineStart + sungSeconds + lyricSilenceThreshold
    return elapsed >= silenceStart && (nextStart.map { elapsed < $0 } ?? true)
}

// MARK: - Line timing

struct LyricPhraseTiming {
    let start: Double
    let end: Double
    let endFraction: Double
}

struct LyricLineTiming {
    let sungSeconds: Double
    let phrases: [LyricPhraseTiming]
}

/// LRC only timestamps whole lines, so how long a line is actually sung is
/// estimated from its syllable count, with short holds at phrase breaks.
enum LyricTiming {
    private struct PhraseSegment {
        let syllables: Int
        var widthWeight: Double
    }

    private static let latinVowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
    private static let phraseSeparators: Set<Character> = [
        ",", "，", "、", "。", "!", "！", "?", "？", ";", "；", ":", "：", "…", "—", "~", "～"
    ]

    static func lyricIndex(in lyrics: [LyricLine], at elapsed: Double) -> Int? {
        guard let first = lyrics.first, elapsed >= first.timestamp else { return nil }
        var low = 0
        var high = lyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if lyrics[mid].timestamp <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return idx
    }

    static func lineTimings(for lyrics: [LyricLine]) -> [LyricLineTiming] {
        let secondsPerSyllable = 0.25
        let baseLineLead = 0.35
        // Tuned by ear: CJK lines swept ~0.15 s ahead of the vocal.
        let syllabicExtraLead = 0.15
        let phrasePauseSeconds = 0.35
        let lastLineLimit = 4.0
        let minimumSungSeconds = 0.2
        return lyrics.indices.map { index in
            let (segments, hasSyllabic) = phraseSegments(lyrics[index].text)
            let lineLead = hasSyllabic ? baseLineLead + syllabicExtraLead : baseLineLead
            let segmentSeconds = segments.map { Double($0.syllables) * secondsPerSyllable }
            let raw = lineLead + segmentSeconds.reduce(0, +) + Double(max(0, segments.count - 1)) * phrasePauseSeconds
            let nextIndex = index + 1
            let limit = nextIndex < lyrics.count
                ? max(0, lyrics[nextIndex].timestamp - lyrics[index].timestamp) : lastLineLimit
            let total = max(minimumSungSeconds, min(raw, limit))
            let scale = raw > 0 ? total / raw : 1
            let totalWeight = segments.reduce(0) { $0 + $1.widthWeight }
            guard totalWeight > 0 else { return LyricLineTiming(sungSeconds: total, phrases: []) }
            var cursor = lineLead * scale
            var weight = 0.0
            var phrases: [LyricPhraseTiming] = []
            phrases.reserveCapacity(segments.count)
            for (segmentIndex, segment) in segments.enumerated() {
                let start = cursor
                cursor += segmentSeconds[segmentIndex] * scale
                weight += segment.widthWeight
                phrases.append(LyricPhraseTiming(start: start, end: cursor, endFraction: weight / totalWeight))
                if segmentIndex + 1 < segments.count { cursor += phrasePauseSeconds * scale }
            }
            return LyricLineTiming(sungSeconds: total, phrases: phrases)
        }
    }

    private static func isSyllabic(_ character: Character) -> Bool {
        guard character.isLetter, !character.isASCII else { return false }
        return character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana & Katakana
                 0x31F0...0x31FF, // Katakana Phonetic Extensions
                 0xFF65...0xFF9F, // Halfwidth Katakana
                 0x1B000...0x1B12F, // Kana Extended
                 0x1B130...0x1B16F, // Small Kana Extension
                 0x1AFF0...0x1AFFE, // Kana Extended-B
                 0x3005...0x3007, // 々 〆 〇
                 0x3021...0x3029, // Hangzhou numerals
                 0x3031...0x3035, // Kana repeat marks
                 0x3038...0x303C, // Han marks
                 0x16FE3...0x16FE3, // Old Chinese iteration mark
                 0x16FF0...0x16FF6, // Vietnamese reading marks
                 0xFFA0...0xFFDC, // Halfwidth Hangul
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0x20000...0x323AF, // CJK Extensions B-I
                 0x1100...0x11FF, // Hangul Jamo
                 0x3130...0x318F, // Hangul Compatibility Jamo
                 0xA960...0xA97F, // Hangul Jamo Extended-A
                 0xAC00...0xD7AF, // Hangul Syllables
                 0xD7B0...0xD7FF: // Hangul Jamo Extended-B
                return true
            default:
                return false
            }
        }
    }

    static func syllableEstimate(_ text: String) -> Int {
        let chars = Array(text)
        var total = 0, word = "", inDigitRun = false

        func finishWord() {
            guard !word.isEmpty else { return }
            let normalized = word.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            var groups = 0, prevVowel = false
            for ch in normalized {
                let isVowel = latinVowels.contains(ch)
                if isVowel && !prevVowel { groups += 1 }
                prevVowel = isVowel
            }
            if normalized.hasSuffix("e") && groups > 1 { groups -= 1 }
            total += max(1, groups)
            word.removeAll(keepingCapacity: true)
        }

        for (index, ch) in chars.enumerated() {
            if ch.isLetter {
                inDigitRun = false
                if isSyllabic(ch) {
                    finishWord()
                    total += 1
                } else {
                    word.append(ch)
                }
            } else if ch.unicodeScalars.allSatisfy({ $0.properties.numericType == .decimal }) {
                finishWord()
                if !inDigitRun {
                    total += 1
                    inDigitRun = true
                }
            } else {
                inDigitRun = false
                if (ch == "'" || ch == "’"), !word.isEmpty, index + 1 < chars.count, chars[index + 1].isLetter {
                    word.append(ch)
                } else {
                    finishWord()
                }
            }
        }
        finishWord()
        return max(1, total)
    }

    private static func phraseSegments(_ text: String) -> (segments: [PhraseSegment], hasSyllabic: Bool) {
        let chars = Array(text)
        var hasSyllabic = false
        let syllabic = chars.map { ch -> Bool in
            let result = isSyllabic(ch)
            if result { hasSyllabic = true }
            return result
        }
        var segments: [PhraseSegment] = []
        var currentText = "", currentWeight = 0.0, index = 0

        func finishSegment() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(PhraseSegment(syllables: syllableEstimate(trimmed), widthWeight: currentWeight))
                currentWeight = 0
            }
            currentText.removeAll(keepingCapacity: true)
        }

        func addSeparatorWeight(_ weight: Double) {
            if segments.isEmpty {
                currentWeight += weight
            } else {
                segments[segments.count - 1].widthWeight += weight
            }
        }

        while index < chars.count {
            let ch = chars[index]
            if phraseSeparators.contains(ch) {
                finishSegment()
                addSeparatorWeight(1.0)
                index += 1
            } else if ch.isWhitespace {
                let start = index
                while index < chars.count && chars[index].isWhitespace { index += 1 }
                let weight = Double(index - start) * 0.5
                if start > 0 && index < chars.count && syllabic[start - 1] && syllabic[index] {
                    finishSegment()
                }
                if currentText.isEmpty && !segments.isEmpty {
                    addSeparatorWeight(weight)
                } else {
                    currentText += String(chars[start..<index])
                    currentWeight += weight
                }
            } else {
                currentText.append(ch)
                currentWeight += syllabic[index] ? 2.0 : 1.0
                index += 1
            }
        }
        finishSegment()
        return (segments, hasSyllabic)
    }
}
