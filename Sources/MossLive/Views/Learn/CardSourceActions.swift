import SwiftUI

/// The two ways back into the lesson a card was written from.
///
/// This is the whole reason Echo is not a flashcard app: the question was cut
/// out of a recording this iPad made, so a wrong answer is twenty seconds of
/// that lesson away — and if hearing it again is not enough, the same lesson's
/// transcript is what the AI answers from.
///
/// Both halves already existed in the app and neither was reachable from a
/// card: the origin was a grey line reading "Quelle: Mathematik · 12:30", and
/// asking meant leaving for the Chat tab and describing the context by hand.
///
/// It owns its own state, so the question screen stays about the question.
struct CardSourceActions: View {
    let api: BackendAPI
    let card: BackendAPI.LearnCard
    let lesson: BackendAPI.LessonInfo?

    @Environment(AppModel.self) private var model

    @State private var playing = false
    @State private var asking = false

    /// The recording plays from the local cache; a lesson the archive says has
    /// none, and that was never downloaded, has nothing to offer.
    private var hasRecording: Bool {
        card.sourceStartMs != nil
            && (lesson?.hasAudio == true || BackendAPI.cachedAudio(id: card.sessionId) != nil)
    }

    var body: some View {
        Group {
            if playing, let start = card.sourceStartMs {
                SourceExcerptPlayer(
                    api: api,
                    lessonId: card.sessionId,
                    startMs: start,
                    endMs: card.sourceEndMs
                ) {
                    playing = false
                }
            } else {
                buttons
            }
        }
        .sheet(isPresented: $asking) {
            AskAboutCardSheet(api: api, card: card, lesson: lesson)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if hasRecording {
                Button {
                    playing = true
                } label: {
                    Label("Im Unterricht hören", systemImage: "waveform")
                }
            }
            // Asking needs the server, and an offer that cannot work is worse
            // than no offer: the recording plays from the cache, the question
            // cannot.
            if model.connectivity.isOnline {
                Button {
                    asking = true
                } label: {
                    Label("Nachfragen", systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }
}
