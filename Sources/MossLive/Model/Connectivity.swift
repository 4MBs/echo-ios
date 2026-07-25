import Foundation
import Network
import Observation

/// Whether the backend can be reached right now.
///
/// Two signals, because neither is enough on its own. The system path knows
/// there is no network before a request is even made, which is what keeps a
/// screen from flashing a spinner it can't satisfy. But a network is not the
/// server: sitting on a café's wifi says nothing about whether the machine at
/// home answers, and that only the last request can tell us.
///
/// The optimism is deliberate. Coming back onto a network resets the server to
/// "assume it answers", because the alternative — staying offline until proven
/// otherwise — needs a probe, and the app already makes one every minute.
@MainActor
@Observable
final class Connectivity {
    static let shared = Connectivity()

    private(set) var hasNetwork = true
    private(set) var serverAnswers = true

    var isOnline: Bool { hasNetwork && serverAnswers }

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                self.hasNetwork = satisfied
                // A new network deserves a fresh try at the server.
                if satisfied { self.serverAnswers = true }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.fourmbs.mosslive.connectivity"))
    }

    func noteReachable() {
        hasNetwork = true
        serverAnswers = true
    }

    /// Only failures that mean "nothing at the other end" count. A 404 or a
    /// server-side error says the server is very much there.
    func note(failure error: Error) {
        guard Self.meansUnreachable(error) else { return }
        serverAnswers = false
    }

    /// Deliberately not isolated: it is a pure test on an error value, and the
    /// networking code that asks is not on the main actor.
    nonisolated static func meansUnreachable(_ error: Error) -> Bool {
        if let api = error as? BackendAPI.APIError { return api.isOffline }
        guard let url = error as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .timedOut, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
