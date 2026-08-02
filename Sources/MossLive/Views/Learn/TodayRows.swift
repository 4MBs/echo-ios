import SwiftUI

// The lines Heute is made of. Each one is a row in a shared surface — a
// subject dot, some words, a number at the end — because the screen's job is to
// be read in one look, and eight rectangles of different heights cannot be.

/// What today's round is made of. Not tappable: it describes the one button
/// above it rather than offering a second way to press it.
struct PlanBlockRow: View {
    let block: StudyPlan.Block

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            SubjectDot(subject: block.subject)
            Text(block.subject)
                .font(.body)
                .lineLimit(1)
            Text(cardCount)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(block.reason)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(block.subject), \(cardCount), \(block.reason)")
    }

    private var cardCount: String {
        block.cardCount == 1 ? "1 Karte" : "\(block.cardCount) Karten"
    }
}

/// The daily goal, as a line that says what it did rather than a control that
/// asks a question before the work.
struct DailyGoalRow: View {
    @Binding var minutes: Int

    var body: some View {
        Menu {
            Picker("Zeit am Tag", selection: $minutes) {
                ForEach(AppSettings.learnMinuteOptions, id: \.self) { option in
                    Text("\(option) Minuten").tag(option)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text("Zugeschnitten auf \(minutes) Minuten am Tag")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.inset)
            .padding(.vertical, 12)
            // A row of footnote-sized type is about 40pt tall; a target is 44.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Zeit am Tag: \(minutes) Minuten")
        .accessibilityHint("Ändert, wie lang deine Lernrunde ist")
    }
}

/// One exam: what and when, and how solid the material is.
struct ExamRow: View {
    let exam: BackendAPI.LearnExam
    let readiness: Double

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            SubjectDot(subject: exam.subject)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.body)
                    .lineLimit(1)
                Text(dateLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ReadinessBar(value: readiness, subject: exam.subject)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline), \(dateLine), Bereitschaft \(Readiness(readiness).word)")
    }

    private var headline: String {
        exam.name.isEmpty ? exam.subject : "\(exam.subject) · \(exam.name)"
    }

    private var dateLine: String {
        guard let date = LearnDay.date(exam.examDate) else {
            return LearnDay.countdown(days: exam.daysRemaining)
        }
        if exam.daysRemaining <= 0 { return "Heute" }
        return "\(LearnDay.short(date)) · \(LearnDay.countdown(days: exam.daysRemaining))"
    }
}

/// A topic that is not sitting well yet. Tapping it practises exactly that.
struct TopicRow: View {
    let topic: StudyTopic

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            SubjectDot(subject: topic.subject)
            VStack(alignment: .leading, spacing: 3) {
                Text(topic.name)
                    .font(.body)
                    .lineLimit(1)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ReadinessBar(value: topic.readiness, subject: topic.subject)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(topic.name), \(detail), \(topic.word)")
    }

    private var detail: String {
        let count = topic.cards.count == 1 ? "1 Karte" : "\(topic.cards.count) Karten"
        guard let subject = topic.subject, subject != topic.name else { return count }
        return "\(subject) · \(count)"
    }
}

/// A row that is only a label and an action — the single call to action of an
/// empty section.
struct LearnActionRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.accent)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.inset)
        .padding(.vertical, 14)
        .frame(minHeight: 44)
    }
}

/// What is true of the screen rather than of a row: how old the stored copy is,
/// what is still waiting to be sent, what could not be loaded.
///
/// A footnote, and never a warning colour. Offline is a normal state of this
/// app, not a fault.
struct LearnStatusFooter: View {
    let isOnline: Bool
    let storedAt: Date?
    let pendingAnswers: Int
    let examsUnavailable: Bool

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lines: [String] {
        var out: [String] = []
        if !isOnline {
            if let storedAt {
                out.append("Offline · Stand von \(CacheAge.phrase(storedAt))")
            } else {
                out.append("Offline")
            }
        }
        if pendingAnswers > 0 {
            out.append(pendingAnswers == 1
                ? "1 Antwort wartet auf den Server"
                : "\(pendingAnswers) Antworten warten auf den Server")
        }
        if examsUnavailable {
            out.append("Arbeiten konnten nicht geladen werden")
        }
        return out
    }
}
