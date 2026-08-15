import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

extension View {
    /// Reports the first touch of every sequence that lands outside a text
    /// input, so an editing session can end wherever the student taps next.
    ///
    /// The reader's own canvas already resigns the keyboard, but the sidebar,
    /// the navigation bar and the assistant panel sit outside that hierarchy
    /// and never reached it — which is why ending page entry used to take a
    /// second tap. Watching at the window covers all of them at once.
    ///
    /// Nothing is consumed: the recognizer fails as soon as it has read the
    /// touch, so the tap it reports still performs whatever it was aimed at.
    func endsEditingOnTouchOutsideTextInput(
        while isActive: Bool,
        perform action: @escaping () -> Void
    ) -> some View {
        background(
            OutsideTouchObserver(isActive: isActive, onTouchOutside: action)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

private struct OutsideTouchObserver: UIViewRepresentable {
    var isActive: Bool
    var onTouchOutside: () -> Void

    func makeUIView(context: Context) -> OutsideTouchHost {
        let host = OutsideTouchHost()
        host.isUserInteractionEnabled = false
        host.recognizer.onTouchOutside = onTouchOutside
        host.isActive = isActive
        return host
    }

    func updateUIView(_ host: OutsideTouchHost, context: Context) {
        host.recognizer.onTouchOutside = onTouchOutside
        host.isActive = isActive
    }

    static func dismantleUIView(_ host: OutsideTouchHost, coordinator: Coordinator) {
        host.isActive = false
    }
}

/// A zero-sized view whose only job is to own the window recognizer for exactly
/// as long as it is wanted, and to find the window again after a move. Leaving
/// the hierarchy takes the window with it, which is what detaches the
/// recognizer when the reader is popped mid-edit.
private final class OutsideTouchHost: UIView {
    let recognizer = OutsideTouchRecognizer(target: nil, action: nil)

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            syncAttachment()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncAttachment()
    }

    private func syncAttachment() {
        guard isActive, let window else {
            recognizer.view?.removeGestureRecognizer(recognizer)
            return
        }
        guard recognizer.view !== window else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        window.addGestureRecognizer(recognizer)
    }
}

private final class OutsideTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onTouchOutside: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // A recognizer without a single action is not sent touches at all, so
        // it keeps one that does nothing.
        addTarget(self, action: #selector(observeOnly))
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // Failing rather than recognizing is what keeps the touch whole: it
        // carries on to the view it started on, undelayed and unchanged.
        state = .failed
        guard let touch = touches.first, let view else { return }
        guard let hit = view.hitTest(touch.location(in: view), with: nil) else {
            onTouchOutside?()
            return
        }
        // A touch on the field itself is part of editing — moving the caret,
        // selecting a digit — and must not end it. The keyboard lives in its
        // own window and is never seen here at all.
        let insideTextInput = sequence(first: hit, next: { $0.superview })
            .contains { $0 is UITextInput }
        guard !insideTextInput else { return }
        onTouchOutside?()
    }

    @objc private func observeOnly() {}

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
