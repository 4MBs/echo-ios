import SwiftUI

struct RecordingSubjectPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.recordingSubjectSelection.catalogue) { subject in
                Button {
                    model.chooseRecordingSubject(subject)
                } label: {
                    if subject == model.recordingSubjectSelection.selected {
                        Label(subject.name, systemImage: "checkmark")
                    } else {
                        Text(subject.name)
                    }
                }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "books.vertical.fill")
                Text(model.recordingSubjectSelection.selected?.name ?? "Fach wählen")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if model.isSavingRecordingSubject {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(width: 112, minHeight: 58)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(model.recordingSubjectSelection.catalogue.isEmpty)
        .accessibilityLabel("Fach der Aufnahme")
        .accessibilityValue(model.recordingSubjectSelection.selected?.name ?? "Nicht ausgewählt")
        .accessibilityIdentifier("recording-subject-picker")
    }
}
