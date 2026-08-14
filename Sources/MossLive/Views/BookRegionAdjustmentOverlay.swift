import UIKit

/// An editable, page-anchored selection. The entire rectangle is draggable and
/// each corner has a generous touch target with a small visible handle, which
/// mirrors the way system crop and text-selection controls separate visual
/// weight from hit-target size.
final class BookRegionAdjustmentOverlay: UIView, UIGestureRecognizerDelegate {
    var onFrameChanged: ((CGRect) -> Void)?
    var onFrameCommitted: ((CGRect) -> Void)?
    var onClear: (() -> Void)?
    var allowedFrame = CGRect.zero

    private enum Corner: CaseIterable, Hashable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        var isTop: Bool { self == .topLeft || self == .topRight }
    }

    private let border = CAShapeLayer()
    private var handles: [Corner: BookRegionHandleView] = [:]
    private var startingFrame = CGRect.zero
    private(set) var isInteracting = false
    private let minimumSide: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        backgroundColor = .clear

        border.fillColor = UIColor.systemBlue.withAlphaComponent(0.11).cgColor
        border.strokeColor = UIColor.systemBlue.cgColor
        border.lineWidth = 2
        border.lineJoin = .round
        layer.addSublayer(border)

        let move = UIPanGestureRecognizer(target: self, action: #selector(moved))
        move.delegate = self
        addGestureRecognizer(move)

        for corner in Corner.allCases {
            let handle = BookRegionHandleView(frame: .zero)
            handle.accessibilityLabel = accessibilityLabel(for: corner)
            let resize = UIPanGestureRecognizer(target: self, action: #selector(resized(_:)))
            resize.name = gestureName(for: corner)
            handle.addGestureRecognizer(resize)
            addSubview(handle)
            handles[corner] = handle
        }

        isAccessibilityElement = true
        accessibilityLabel = "Ausgewählter Buchbereich"
        accessibilityHint = "Zum Verschieben ziehen oder die Eckpunkte zum Ändern der Größe verwenden."
        accessibilityTraits = [.adjustable]
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Auswahl aufheben",
                target: self,
                selector: #selector(clearSelection)
            ),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.frame = bounds
        border.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: 7
        ).cgPath

        let target: CGFloat = 44
        for (corner, handle) in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: target, height: target)
            handle.center = CGPoint(
                x: corner.isLeft ? 0 : bounds.width,
                y: corner.isTop ? 0 : bounds.height
            )
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        return handles.values.contains { handle in
            handle.point(inside: convert(point, to: handle), with: event)
        }
    }

    func setSelectionFrame(_ newFrame: CGRect) {
        guard !isInteracting else { return }
        frame = newFrame.standardized
    }

    var interactionRecognizers: [UIGestureRecognizer] {
        let move = gestureRecognizers ?? []
        let resize = handles.values.flatMap { $0.gestureRecognizers ?? [] }
        return move + resize
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        !handles.values.contains { handle in
            guard let touchedView = touch.view else { return false }
            return touchedView === handle || touchedView.isDescendant(of: handle)
        }
    }

    @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch recognizer.state {
        case .began:
            isInteracting = true
            startingFrame = frame
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            let translation = recognizer.translation(in: container)
            frame = clampedMovedFrame(
                startingFrame.offsetBy(dx: translation.x, dy: translation.y)
            )
            onFrameChanged?(frame)
        case .ended:
            isInteracting = false
            onFrameCommitted?(frame)
        case .cancelled, .failed:
            frame = startingFrame
            isInteracting = false
            onFrameCommitted?(frame)
        default:
            break
        }
    }

    @objc private func resized(_ recognizer: UIPanGestureRecognizer) {
        guard let container = superview,
              let name = recognizer.name,
              let corner = corner(for: name)
        else { return }

        switch recognizer.state {
        case .began:
            isInteracting = true
            startingFrame = frame
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            let translation = recognizer.translation(in: container)
            frame = resizedFrame(from: startingFrame, corner: corner, translation: translation)
            onFrameChanged?(frame)
        case .ended:
            isInteracting = false
            onFrameCommitted?(frame)
        case .cancelled, .failed:
            frame = startingFrame
            isInteracting = false
            onFrameCommitted?(frame)
        default:
            break
        }
    }

    private func clampedMovedFrame(_ proposed: CGRect) -> CGRect {
        guard !allowedFrame.isEmpty else { return proposed }
        let width = min(proposed.width, allowedFrame.width)
        let height = min(proposed.height, allowedFrame.height)
        let x = min(max(proposed.minX, allowedFrame.minX), allowedFrame.maxX - width)
        let y = min(max(proposed.minY, allowedFrame.minY), allowedFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func resizedFrame(
        from initial: CGRect,
        corner: Corner,
        translation: CGPoint
    ) -> CGRect {
        var minX = initial.minX
        var maxX = initial.maxX
        var minY = initial.minY
        var maxY = initial.maxY
        let minimumWidth = min(minimumSide, initial.width)
        let minimumHeight = min(minimumSide, initial.height)

        if corner.isLeft {
            minX = min(max(initial.minX + translation.x, allowedFrame.minX), maxX - minimumWidth)
        } else {
            maxX = max(min(initial.maxX + translation.x, allowedFrame.maxX), minX + minimumWidth)
        }
        if corner.isTop {
            minY = min(max(initial.minY + translation.y, allowedFrame.minY), maxY - minimumHeight)
        } else {
            maxY = max(min(initial.maxY + translation.y, allowedFrame.maxY), minY + minimumHeight)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func gestureName(for corner: Corner) -> String {
        switch corner {
        case .topLeft: "book-region-top-left"
        case .topRight: "book-region-top-right"
        case .bottomLeft: "book-region-bottom-left"
        case .bottomRight: "book-region-bottom-right"
        }
    }

    private func corner(for name: String) -> Corner? {
        Corner.allCases.first { gestureName(for: $0) == name }
    }

    private func accessibilityLabel(for corner: Corner) -> String {
        switch corner {
        case .topLeft: "Auswahl oben links anpassen"
        case .topRight: "Auswahl oben rechts anpassen"
        case .bottomLeft: "Auswahl unten links anpassen"
        case .bottomRight: "Auswahl unten rechts anpassen"
        }
    }

    @objc private func clearSelection() -> Bool {
        onClear?()
        return true
    }
}

/// Keeps a 44-point native touch target while drawing only the compact handle
/// users expect at the corner of a crop or selection rectangle.
private final class BookRegionHandleView: UIView {
    private let dot = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        backgroundColor = .clear
        dot.fillColor = UIColor.systemBlue.cgColor
        dot.strokeColor = UIColor.white.cgColor
        dot.lineWidth = 2
        layer.addSublayer(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = bounds
        dot.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 14, dy: 14)).cgPath
    }
}
