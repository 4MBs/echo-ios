import SwiftUI

/// The subject of the recording. It is filled in from the timetable and is only
/// ever opened to correct that — nothing here has to be answered before the
/// record button works.
struct RecordingSubjectPicker: View {
    @Environment(AppModel.self) private var model

    private var selection: RecordingSubjectSelection { model.recordingSubjectSelection }

    var body: some View {
        Menu {
            Button {
                model.useAutomaticRecordingSubject()
            } label: {
                if selection.isManual {
                    Text("Automatisch")
                } else {
                    Label("Automatisch", systemImage: "checkmark")
                }
            }

            Divider()

            ForEach(selection.catalogue) { subject in
                Button {
                    model.chooseRecordingSubject(subject)
                } label: {
                    if selection.isManual, subject == selection.selected {
                        Label(subject.name, systemImage: "checkmark")
                    } else {
                        Text(subject.name)
                    }
                }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: selection.isManual ? "books.vertical.fill" : "calendar.badge.clock")
                Text(selection.selected?.name ?? "Automatisch")
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if model.isSavingRecordingSubject {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(width: 112)
            .frame(minHeight: 58)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(selection.catalogue.isEmpty)
        .accessibilityLabel("Fach der Aufnahme")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Optional. Ohne Auswahl benennt der Stundenplan die Aufnahme.")
        .accessibilityIdentifier("recording-subject-picker")
    }

    private var accessibilityValue: String {
        guard let name = selection.selected?.name else { return "Automatisch" }
        return selection.isManual ? name : "Automatisch: \(name)"
    }
}
