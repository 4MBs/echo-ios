import SwiftUI
import UIKit

/// Panic switch: a three-finger tap anywhere in the app instantly opens the
/// configured app (via its URL scheme, e.g. GoodNotes). The recognizer sits
/// on the window and recognizes alongside every other gesture, so normal
/// one-finger interaction is unaffected. Recording keeps running in the
/// background — the session is untouched.
struct ThreeFingerSwitch: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> UIView {
        let view = AttachingView()
        view.isUserInteractionEnabled = false
        view.onTrigger = { open(urlString) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        (uiView as? AttachingView)?.onTrigger = { open(urlString) }
    }

    private func open(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return }
        UIApplication.shared.open(url)
    }

    /// Installs the window-level recognizer once the view lands in a window.
    final class AttachingView: UIView, UIGestureRecognizerDelegate {
        var onTrigger: (() -> Void)?
        private weak var recognizer: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, recognizer == nil else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(fire))
            tap.numberOfTouchesRequired = 3
            tap.numberOfTapsRequired = 1
            tap.delegate = self
            tap.cancelsTouchesInView = false
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        deinit {
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
            }
        }

        @objc private func fire() {
            onTrigger?()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
