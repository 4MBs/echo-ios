import SwiftUI

/// WebUntis login + the two things a timetable does for the app. Credentials
/// are sent to the Fedora server (which stores and uses them) — they never live
/// on the iPad, so once the server is connected this shows a clear "logged in"
/// state instead of empty fields; re-login hides behind "Anmeldung ändern".
struct TimetableSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var school = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var ok = false
    @State private var message: String?
    @State private var editingLogin = false

    private var isConnected: Bool { model.timetable.enabled }

    var body: some View {
        Form {
            Section {
                if isConnected {
                    connectedRow
                }
                if !isConnected || editingLogin {
                    loginFields
                } else {
                    Button("Anmeldung ändern") { editingLogin = true }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(ok ? .green : .red)
                }
            } footer: {
                Text("Dein Passwort wird nur auf deinem eigenen Server gespeichert.")
            }

            Section {
                Toggle("Erinnerung bei Stundenbeginn", isOn: notificationsBinding)
                Toggle("Aufnahme bei Stundenende stoppen", isOn: autoStopBinding)
            } footer: {
                Text("Aufnahmen werden automatisch dem richtigen Fach zugeordnet.")
            }
        }
        .navigationTitle("Stundenplan")
        .animation(.snappy, value: isConnected)
    }

    private var connectedRow: some View {
        LabeledContent {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mit WebUntis verbunden")
                Text(connectedSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var loginFields: some View {
        TextField("Schule (z. B. avs-itzehoe)", text: $school)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        TextField("Benutzername", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        SecureField("Passwort", text: $password)
        Button {
            Task { await connect() }
        } label: {
            HStack(spacing: 8) {
                if busy { ProgressView() }
                Text(busy ? "Verbinde…" : "Anmelden")
            }
        }
        .disabled(busy || school.isEmpty || username.isEmpty || password.isEmpty || !model.connectivity.isOnline)
        if !model.connectivity.isOnline {
            Text("Zum Anmelden wird der Server gebraucht.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var connectedSubtitle: String {
        if let current = model.timetable.current {
            return "Aktuell: \(current.title)"
        }
        if let next = model.timetable.next {
            return "Als Nächstes: \(next.title) · \(next.start)"
        }
        // The login lives on the server and is untouched by any of this; only
        // the ability to ask about it is missing.
        if !model.connectivity.isOnline {
            guard let savedAt = model.timetable.savedAt else {
                return "Die Anmeldung bleibt bestehen."
            }
            return "Stundenplan von \(CacheAge.phrase(savedAt))"
        }
        return "Stundenplan wird vom Server abgerufen."
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { model.settings.lessonNotifications },
            set: { value in
                model.settings.lessonNotifications = value
                Task { await model.syncTimetableNotifications() }
            }
        )
    }

    private var autoStopBinding: Binding<Bool> {
        Binding(
            get: { model.settings.autoStopAtLessonEnd },
            set: { model.settings.autoStopAtLessonEnd = $0 }
        )
    }

    private func connect() async {
        busy = true
        message = nil
        defer { busy = false }
        let api = BackendAPI(
            host: model.settings.serverHost,
            port: model.settings.serverPort,
            token: model.settings.authToken
        )
        do {
            try await api.submitWebUntisCredentials(school: school, username: username, password: password)
            ok = true
            message = "Verbunden."
            password = ""
            editingLogin = false
            await model.refreshTimetable()
            await model.syncTimetableNotifications()
        } catch {
            ok = false
            message = error.localizedDescription
        }
    }
}
