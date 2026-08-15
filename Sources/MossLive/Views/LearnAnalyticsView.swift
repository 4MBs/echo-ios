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
                    LabeledContent("Erneut zu lernen", value: "\(analytics.stateDistribution["relearning", default: 0])")
                }
                Section("Lernergebnis") {
                    LabeledContent("Abrufquote", value: analytics.recallSuccess.map { $0.formatted(.percent) } ?? "Noch nicht genug Daten")
                    LabeledContent("Fehlversuche", value: "\(analytics.lapses)")
                    LabeledContent("Wiederholte Missverständnisse", value: "\(analytics.repeatedMisconceptions)")
                }
                Section("Aktivität") {
                    LabeledContent("Letzte 7 Tage", value: "\(analytics.activity7Days) Antworten")
                    LabeledContent("Letzte 30 Tage", value: "\(analytics.activity30Days) Antworten")
                }
                if !analytics.neverRecalled.isEmpty {
                    Section("Noch nie sicher abgerufen") {
                        ForEach(analytics.neverRecalled, id: \.self) { Text($0) }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Analytik nicht verfügbar", systemImage: "chart.bar.xaxis", description: Text(errorMessage))
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
