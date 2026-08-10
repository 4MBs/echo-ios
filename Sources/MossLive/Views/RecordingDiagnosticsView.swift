import SwiftUI

struct RecordingDiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section("Eingang") {
                LabeledContent("Route", value: diagnostics.route)
                LabeledContent(
                    "Hardwareformat",
                    value: diagnostics.hardwareSampleRate > 0
                        ? "\(Int(diagnostics.hardwareSampleRate)) Hz · \(diagnostics.hardwareChannels) Kanal"
                        : "Noch keine Aufnahme"
                )
                LabeledContent("iOS Voice Processing", value: diagnostics.voiceProcessing ? "Aktiv" : "Inaktiv")
                LabeledContent(
                    "Automatische Verstärkung",
                    value: diagnostics.automaticGainControl ? "Aktiv" : "Inaktiv"
                )
            }

            Section("Signal") {
                DiagnosticMeter(title: "Aktueller Pegel", value: diagnostics.level)
                LabeledContent("RMS", value: db(diagnostics.rmsDBFS))
                LabeledContent("Spitze", value: db(diagnostics.peakDBFS))
                LabeledContent("Rauschpegel", value: db(diagnostics.noiseFloorDBFS))
                LabeledContent(
                    "Clipping",
                    value: diagnostics.clippedSamplePercent.formatted(
                        .number.precision(.fractionLength(0 ... 3))
                    ) + " %"
                )
            }

            Section("Verbindung und Integrität") {
                LabeledContent("Server-RTT", value: milliseconds(model.lastRoundTripMs))
                LabeledContent("Transkript-Lag", value: seconds(model.serverTranscriptLagSeconds))
                LabeledContent("Datei-Puffer", value: seconds(model.bufferedSeconds))
                LabeledContent("Unterbrechungen", value: "\(diagnostics.interruptions)")
                LabeledContent("Route-Wechsel", value: "\(diagnostics.routeChanges)")
                LabeledContent("Verlorene Buffer", value: "\(diagnostics.lostBuffers)")
                LabeledContent("Lokal aufgenommen", value: duration(diagnostics.capturedSeconds))
            }

            if !model.audioEvents.isEmpty {
                Section("Letzte Ereignisse") {
                    ForEach(model.audioEvents.prefix(30)) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.message)
                                .font(.callout)
                            Text(event.date.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                if model.localRecordings.isEmpty {
                    Text("Noch keine lokale Sicherheitsaufnahme.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.localRecordings) { recording in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                                Text(recordingSubtitle(recording))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: recording.url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Sicherheitsaufnahme teilen")
                        }
                    }
                }
            } header: {
                Text("Lokale Sicherheitskopien")
            } footer: {
                Text("Während der Aufnahme als 48-kHz-PCM gesichert und danach als M4A komprimiert.")
            }
        }
        .navigationTitle("Aufnahmediagnose")
        .task { await model.refreshLocalRecordings() }
    }

    private var diagnostics: AudioDiagnosticsSnapshot { model.audioDiagnostics }

    private func db(_ value: Double) -> String {
        guard value > -119 else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded())) ms"
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + " s"
    }

    private func duration(_ value: Double) -> String {
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func recordingSubtitle(_ recording: LocalRecordingSummary) -> String {
        var parts = [duration(recording.durationSeconds)]
        switch recording.state {
        case .completed: break
        case .recovered: parts.append("wiederhergestellt")
        case .failed: parts.append("Konvertierungsfehler")
        case .recording: parts.append("wird aufgenommen")
        case .finalizing: parts.append("wird konvertiert")
        }
        return parts.joined(separator: " · ")
    }
}

private struct DiagnosticMeter: View {
    let title: String
    let value: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(Int(value * 100).formatted() + " %")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: Double(value))
                .tint(value > 0.96 ? .red : .green)
        }
        .padding(.vertical, 3)
    }
}
