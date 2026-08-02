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
                if !session.isFinished { header }
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

    /// Progress, position, and the one way out. No score: a running count of
    /// what you got wrong is pressure, not information.
    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(session.position) von \(session.total)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Spacer()
                Button("Beenden") { requestExit() }
                    .font(.body)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ProgressView(value: session.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.Space.screen)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityValue("Frage \(session.position) von \(session.total)")
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
