import SwiftUI

struct LearnAnalyticsView: View {
    let api: BackendAPI
    @State private var analytics: BackendAPI.LearnAnalytics?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let analytics {
                Section("Jetzt wichtig") {
                    LabeledContent("Fällig", value: "\(analytics.due)")
                    LabeledContent("Überfällig", value: "\(analytics.overdue)")
                    LabeledContent(
                        "Erneut zu lernen",
                        value: "\(analytics.stateDistribution["relearning", default: 0])"
                    )
                }
                Section("Lernergebnis") {
                    LabeledContent(
                        "Abrufquote",
                        value: analytics.recallSuccess.map { $0.formatted(.percent) } ?? "Noch nicht genug Daten"
                    )
                    LabeledContent("Fehlversuche", value: "\(analytics.lapses)")
                    LabeledContent("Wiederholte Missverständnisse", value: "\(analytics.repeatedMisconceptions)")
                }
                Section("Aktivität") {
                    LabeledContent("Letzte 7 Tage", value: "\(analytics.activity7Days) Antworten")
                    LabeledContent("Letzte 30 Tage", value: "\(analytics.activity30Days) Antworten")
                    if let latest = analytics.responseTimeSeries.last(where: { $0.averageMs != nil })?.averageMs {
                        LabeledContent("Ø Antwortzeit zuletzt", value: "\(latest / 1000) Sek.")
                    }
                }
                if !analytics.recallBySubject.isEmpty {
                    Section("Abrufquote nach Fach") {
                        ForEach(analytics.recallBySubject.keys.sorted(), id: \.self) { subject in
                            LabeledContent(
                                subject,
                                value: analytics.recallBySubject[subject, default: 0].formatted(.percent)
                            )
                        }
                    }
                }
                let weaknesses = analytics.recallByConcept.sorted { $0.value < $1.value }.prefix(8)
                if !weaknesses.isEmpty {
                    Section("Aktuelle Wissenslücken") {
                        ForEach(Array(weaknesses), id: \.key) { concept, score in
                            LabeledContent(concept, value: score.formatted(.percent))
                        }
                    }
                }
                if !analytics.neverRecalled.isEmpty {
                    Section("Noch nie sicher abgerufen") {
                        ForEach(analytics.neverRecalled, id: \.self) { Text($0) }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "Analytik nicht verfügbar",
                    systemImage: "chart.bar.xaxis",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Lernbelege werden geladen …")
            }
        }
        .navigationTitle("Lernanalyse")
        .task {
            do { analytics = try await api.learnAnalytics() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
