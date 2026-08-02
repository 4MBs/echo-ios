import SwiftUI

/// A study round, full screen: one question, one answer, one reaction.
///
/// It is a modal over the whole window rather than a page inside the Lernen
/// tab, because studying is a mode and not a place — the sidebar goes away and
/// there is exactly one way out. The state lives on `AppModel`, so locking the
/// iPad, taking a call or switching apps comes back to the same question with
/// the same answers behind it.
struct StudySessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    let session: StudySession

    @State private var confirmingExit = false
    /// Lesson titles and dates, read once from the archive so a question can say
    /// which lesson it came from — and whether that lesson has a recording.
    @State private var lessons: [String: BackendAPI.LessonInfo] = [:]

    private var api: BackendAPI { model.api }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // The result is its own screen with its own way out. Leaving the
                // progress bar and a second "Beenden" above it would put the
                // same action on the screen twice.
                if !session.isFinished { header(width: geo.size.width) }
                stage(width: geo.size.width)
            }
        }
        .sessionScreen()
        .confirmationDialog(
            "Lernrunde beenden?",
            isPresented: $confirmingExit,
            titleVisibility: .visible
        ) {
            Button("Beenden", role: .destructive) { model.endStudy() }
            Button("Weiterlernen", role: .cancel) {}
        } message: {
            Text("Deine bisherigen Antworten sind gespeichert.")
        }
        .onAppear { loadLessons() }
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { requestExit() }
    }

    // MARK: - Chrome

    /// Where the question comes from, where the round is, and the one way out.
    ///
    /// The origin moved up here out of the content: it is true of the whole
    /// screen rather than part of the question, and in the header it gives the
    /// round the subject's colour without painting anything. No score — a
    /// running count of what you got wrong is pressure, not information — and
    /// no timer, because nothing here is timed.
    private func header(width: CGFloat) -> some View {
        // In a Slide Over slice, or at accessibility text sizes, the origin
        // gives up its words and keeps its glyph: the position and the way out
        // are what the header is for.
        let showsOrigin = width >= Theme.Width.narrow && typeSize < .accessibility1
        return VStack(spacing: 10) {
            HStack(spacing: Theme.Space.row) {
                if let card = session.current {
                    SubjectGlyph(subject: card.subject, size: 30)
                    if showsOrigin {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(card.subject ?? otherSubjectName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if let origin = originLine(for: card) {
                                Text(origin)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                Text("\(session.position)/\(session.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Frage \(session.position) von \(session.total)")
                Button("Beenden") { requestExit() }
                    .font(.body)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ProgressView(value: session.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.Space.screen)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    /// The lesson a card was written from, spelled as a date when the archive
    /// knows it and as the lesson's own title when it does not.
    private func originLine(for card: BackendAPI.LearnCard) -> String? {
        if let started = lessons[card.sessionId]?.startedAt { return LearnDay.short(started) }
        return card.lessonTitle?.trimmingCharacters(in: .whitespaces).nilWhenEmpty
    }

    @ViewBuilder
    private func stage(width: CGFloat) -> some View {
        if session.isFinished {
            SessionResultView(session: session) { again in
                if let again {
                    model.startStudy(again)
                } else {
                    model.endStudy()
                }
            }
        } else if let card = session.current {
            QuestionView(
                card: card,
                lesson: lessons[card.sessionId],
                api: api,
                width: width,
                isLast: session.position == session.total,
                countsForPlan: session.mode.reportsResults,
                onAnswer: { correct, rating, responseMs, confidence in
                    guard session.record(correct: correct, rating: rating) else { return }
                    model.record(
                        answer: card,
                        correct: correct,
                        rating: rating,
                        responseMs: responseMs,
                        confidence: confidence,
                        in: session
                    )
                },
                onNext: {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { session.advance() }
                }
            )
            .id(card.id)
        }
    }

    // MARK: - Actions

    /// Leaving mid-round asks; leaving a finished round does not, because there
    /// is nothing left to lose.
    private func requestExit() {
        if session.isFinished || session.answers.isEmpty {
            model.endStudy()
        } else {
            confirmingExit = true
        }
    }

    private func loadLessons() {
        guard lessons.isEmpty else { return }
        let stored = OfflineCache.load([BackendAPI.LessonInfo].self, key: OfflineCache.Key.lessons) ?? []
        lessons = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
