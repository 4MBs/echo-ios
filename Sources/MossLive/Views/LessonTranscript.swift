import SwiftUI

/// Who each voice belongs to, worked out from how much of the lesson it holds.
///
/// The diarizer hands out `S01`, `S02`, which is worth nothing to a reader.
/// But the person who does most of the talking in a school lesson is the
/// person teaching it, and the timetable already knows that person's name.
struct SpeakerBook {
    /// Diarisation label -> the name the page prints.
    let names: [String: String]
    /// The voice we are willing to put a real name on, if any.
    let teacherKey: String?

    static let empty = SpeakerBook(names: [:], teacherKey: nil)

    static func infer(from segments: [TranscriptSegment], teacher: String?) -> SpeakerBook {
        var talk: [String: Double] = [:]
        for segment in segments {
            talk[segment.speaker, default: 0] += max(0, segment.t1 - segment.t0)
        }
        guard !talk.isEmpty else { return .empty }
        let total = talk.values.reduce(0, +)
        // Sorted by talk time, and by label where two voices tie, so the
        // numbering is the same every time the lesson is opened.
        let ranked = talk.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }

        // The share has to be decisive before a guess gets a surname: in a
        // discussion lesson nobody holds the floor, and "Sprecher 1" is a
        // better answer than the wrong teacher.
        var teacherKey: String?
        if let teacher, !teacher.isEmpty, total > 0,
           let top = ranked.first, top.value / total >= 0.45 {
            teacherKey = top.key
        }

        var names: [String: String] = [:]
        for (rank, entry) in ranked.enumerated() {
            if entry.key == teacherKey, let teacher {
                names[entry.key] = teacher
            } else {
                names[entry.key] = "Sprecher \(rank + 1)"
            }
        }
        return SpeakerBook(names: names, teacherKey: teacherKey)
    }
}

/// One transcript line, prepared for the page rather than for the wire.
struct TranscriptLine: Identifiable {
    /// Index into the lesson's segments — the same number the player reports
    /// as `activeIndex`, which is what turns the highlight into a lookup.
    let id: Int
    let text: String
    let start: Double
    /// Set only on the line that opens a turn; the rest of the turn is the
    /// same person still speaking and does not need saying again.
    let speaker: String?
    let isTeacher: Bool
    let stamp: String?

    var opensTurn: Bool { speaker != nil }

    static func build(from segments: [TranscriptSegment], speakers: SpeakerBook) -> [TranscriptLine] {
        var result: [TranscriptLine] = []
        result.reserveCapacity(segments.count)
        var lastSpeaker: String?
        var lastStamp = -Double.greatestFiniteMagnitude

        for (index, segment) in segments.enumerated() {
            let opens = segment.speaker != lastSpeaker
            // A time against all four hundred lines is four hundred numbers
            // nobody reads. One at the head of every turn, and one more
            // whenever a turn has run on for a minute, is enough to find a
            // moment by eye and enough to leave the page quiet.
            let marks = opens || segment.t0 - lastStamp >= 60
            result.append(
                TranscriptLine(
                    id: index,
                    text: segment.text,
                    start: segment.t0,
                    speaker: opens ? speakers.names[segment.speaker] : nil,
                    isTeacher: segment.speaker == speakers.teacherKey,
                    stamp: marks ? lessonOffsetLabel(segment.t0) : nil
                )
            )
            if marks { lastStamp = segment.t0 }
            lastSpeaker = segment.speaker
        }
        return result
    }
}

/// One line of the record: its time out in the left margin, the thread of the
/// lesson running past it, and what was said.
///
/// The line is a button, because the transcript's real job is not to be read
/// end to end — it is to find the moment and then hear it.
struct LessonTranscriptLine: View {
    let line: TranscriptLine
    let tint: Color
    let isActive: Bool
    let canPlay: Bool
    let play: () -> Void

    var body: some View {
        if canPlay {
            Button(action: play) { row }
                .buttonStyle(.plain)
        } else {
            // With no recording there is nothing to seek to, so the line gives
            // up its tap and becomes selectable text instead.
            row.textSelection(.enabled)
        }
    }

    private var row: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let speaker = line.speaker { turnHead(speaker) }
            spoken
        }
        .padding(.top, line.opensTurn ? 18 : 1)
        .padding(.bottom, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) { thread }
    }

    /// The rule the whole transcript hangs on. Every line draws its own stretch
    /// of it with no gap above or below, so the stretches join into one
    /// unbroken line down the page — and the stretch beside the spoken line is
    /// lit, which is how the recording says where it has got to.
    private var thread: some View {
        Rectangle()
            .fill(isActive ? tint : Color.primary.opacity(0.10))
            .frame(width: 2.5)
            .offset(x: LessonMetrics.gutter)
    }

    private func turnHead(_ speaker: String) -> some View {
        Text(speaker)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(line.isTeacher ? tint : Color.secondary)
            .padding(.leading, LessonMetrics.textLeading)
            .padding(.bottom, 3)
    }

    /// The highlight is a wash behind the words and a colour on the thread —
    /// nothing that changes the type. Marking the spoken line by weight or size
    /// would reflow it, and a line that jumps as it is read is unreadable.
    private var spoken: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.stamp ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? tint : Color.secondary.opacity(0.5))
                .frame(width: LessonMetrics.gutter - 8, alignment: .trailing)
            Text(line.text)
                .font(.body)
                .lineSpacing(4)
                .padding(.vertical, 5)
                .padding(.horizontal, LessonMetrics.textInset)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? tint.opacity(0.14) : Color.clear)
                )
                .padding(.leading, LessonMetrics.threadGap + 8)
        }
    }
}
