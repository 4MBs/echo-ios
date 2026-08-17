import PDFKit

final class BookPDFView: PDFView {
    /// Breathing room left around the page at its smallest, in points.
    private let margin: CGFloat = 14
    /// The scale the page rests at: its natural size on this screen, and the
    /// point below which zooming out stops.
    private(set) var restingScale: CGFloat = 0
    private var selectionOverlay: BookRegionSelectionOverlay?
    private var adjustmentOverlay: BookRegionAdjustmentOverlay?
    private var displayedRegion: BackendAPI.BookPageRegion?
    private weak var observedScrollView: UIScrollView?
    private var scrollObservations: [NSKeyValueObservation] = []
    private var scrollEnabledBeforeRegionSelection: Bool?
    private lazy var deselectionTap = UITapGestureRecognizer(
        target: self,
        action: #selector(tappedOutsideSelection)
    )
    var onRegionChanged: ((BackendAPI.BookPageRegion?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureRegionInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureRegionInteraction()
    }

    private func configureRegionInteraction() {
        deselectionTap.cancelsTouchesInView = false
        deselectionTap.delegate = self
        addGestureRecognizer(deselectionTap)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            disableInteractivePopGesture()
        }
    }

    private func disableInteractivePopGesture() {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let nav = next as? UINavigationController {
                nav.interactivePopGestureRecognizer?.isEnabled = false
                return
            }
            if let vc = next as? UIViewController, let nav = vc.navigationController {
                nav.interactivePopGestureRecognizer?.isEnabled = false
                return
            }
            responder = next
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyScaleLimits()
        selectionOverlay?.frame = bounds
        observeScrollingIfNeeded()
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    func beginRegionSelection(onSelected: @escaping (BackendAPI.BookPageRegion) -> Void) {
        cancelRegionSelection()
        setReaderGesturesEnabled(false)
        let overlay = BookRegionSelectionOverlay(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.onFinished = { [weak self, weak overlay] rect in
            guard let self else { return }
            let converted = overlay?.convert(rect, to: self) ?? rect
            if let region = normalizedRegion(from: converted) {
                display(region: region)
                onSelected(region)
                cancelRegionSelection()
            }
        }
        addSubview(overlay)
        selectionOverlay = overlay
        prioritizeRegionGestures(overlay.gestureRecognizers ?? [])
    }

    func cancelRegionSelection() {
        selectionOverlay?.removeFromSuperview()
        selectionOverlay = nil
        setReaderGesturesEnabled(true)
    }

    private func setReaderGesturesEnabled(_ enabled: Bool) {
        for swipe in gestureRecognizers?.compactMap({ $0 as? PageSwipeGestureRecognizer }) ?? [] {
            swipe.isEnabled = enabled
        }
        guard let scrollView = descendantScrollView(in: self) else { return }
        if enabled {
            if let previous = scrollEnabledBeforeRegionSelection {
                scrollView.isScrollEnabled = previous
            }
            scrollEnabledBeforeRegionSelection = nil
        } else {
            if scrollEnabledBeforeRegionSelection == nil {
                scrollEnabledBeforeRegionSelection = scrollView.isScrollEnabled
            }
            scrollView.isScrollEnabled = false
        }
    }

    func display(region: BackendAPI.BookPageRegion?) {
        displayedRegion = region
        if region == nil {
            adjustmentOverlay?.removeFromSuperview()
            adjustmentOverlay = nil
        } else {
            installAdjustmentOverlayIfNeeded()
        }
        updateDisplayedRegion()
    }

    private func normalizedRegion(
        from selection: CGRect,
        on preferredPage: PDFPage? = nil
    ) -> BackendAPI.BookPageRegion? {
        guard selection.width >= 18, selection.height >= 18,
              let document,
              let page = preferredPage ?? page(for: CGPoint(x: selection.midX, y: selection.midY), nearest: true)
        else { return nil }

        let pageFrame = convert(page.bounds(for: .cropBox), from: page)
        let clipped = selection.standardized.intersection(pageFrame)
        guard !clipped.isNull, clipped.width >= 18, clipped.height >= 18 else { return nil }

        let pageBounds = page.bounds(for: .cropBox)
        let pdfRect = convert(clipped, to: page).intersection(pageBounds)
        let pageIndex = document.index(for: page)
        guard pageBounds.width > 0, pageBounds.height > 0, pageIndex >= 0 else { return nil }

        return BackendAPI.BookPageRegion(
            pdfPage: pageIndex + 1,
            x: Double((pdfRect.minX - pageBounds.minX) / pageBounds.width).clamped01,
            y: Double((pdfRect.minY - pageBounds.minY) / pageBounds.height).clamped01,
            width: Double(pdfRect.width / pageBounds.width).clamped01,
            height: Double(pdfRect.height / pageBounds.height).clamped01
        )
    }

    private func updateDisplayedRegion() {
        guard let region = displayedRegion,
              let document,
              let page = document.page(at: region.pdfPage - 1)
        else {
            adjustmentOverlay?.isHidden = true
            return
        }
        installAdjustmentOverlayIfNeeded()
        let pageBounds = page.bounds(for: .cropBox)
        let pdfRect = CGRect(
            x: pageBounds.minX + pageBounds.width * CGFloat(region.x),
            y: pageBounds.minY + pageBounds.height * CGFloat(region.y),
            width: pageBounds.width * CGFloat(region.width),
            height: pageBounds.height * CGFloat(region.height)
        )
        let pageFrame = convert(pageBounds, from: page)
        let selectionFrame = convert(pdfRect, from: page).standardized.intersection(pageFrame)
        guard !selectionFrame.isNull, selectionFrame.width > 0, selectionFrame.height > 0 else {
            adjustmentOverlay?.isHidden = true
            return
        }
        adjustmentOverlay?.isHidden = false
        adjustmentOverlay?.allowedFrame = pageFrame
        adjustmentOverlay?.setSelectionFrame(selectionFrame)
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func installAdjustmentOverlayIfNeeded() {
        guard adjustmentOverlay == nil else { return }
        let overlay = BookRegionAdjustmentOverlay(frame: .zero)
        overlay.onFrameChanged = { [weak self] frame in
            guard let self,
                  let current = displayedRegion,
                  let page = document?.page(at: current.pdfPage - 1),
                  let updated = normalizedRegion(from: frame, on: page)
            else { return }
            displayedRegion = updated
        }
        overlay.onFrameCommitted = { [weak self] frame in
            guard let self,
                  let current = displayedRegion,
                  let page = document?.page(at: current.pdfPage - 1),
                  let updated = normalizedRegion(from: frame, on: page)
            else { return }
            displayedRegion = updated
            onRegionChanged?(updated)
        }
        overlay.onClear = { [weak self] in
            guard let self else { return }
            display(region: nil)
            onRegionChanged?(nil)
        }
        addSubview(overlay)
        adjustmentOverlay = overlay
        prioritizeRegionGestures(overlay.interactionRecognizers)
    }

    /// PDFKit scrolls and zooms an internal scroll view, so PDFView itself does
    /// not reliably receive a layout pass while the page moves. Tracking those
    /// values keeps the editable rectangle attached to the exact PDF
    /// coordinates through zooming, panning and orientation changes.
    private func observeScrollingIfNeeded() {
        guard observedScrollView == nil,
              let scrollView = descendantScrollView(in: self)
        else { return }
        observedScrollView = scrollView
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(readerInteractionBegan(_:)))
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(readerInteractionBegan(_:)))
        if let adjustmentOverlay {
            prioritizeRegionGestures(adjustmentOverlay.interactionRecognizers)
        }
        scrollObservations = [
            scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
            scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
            scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                self?.updateDisplayedRegion()
            },
        ]
    }

    @objc private func readerInteractionBegan(_ recognizer: UIGestureRecognizer) {
        guard recognizer.state == .began else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func descendantScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = descendantScrollView(in: subview) { return nested }
        }
        return nil
    }

    @objc private func tappedOutsideSelection(_ recognizer: UITapGestureRecognizer) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard let overlay = adjustmentOverlay, !overlay.isHidden, !overlay.isInteracting else { return }
        let point = recognizer.location(in: self)
        guard !regionControlsContain(point) else { return }
        display(region: nil)
        onRegionChanged?(nil)
    }

    func regionControlsContain(_ point: CGPoint) -> Bool {
        guard let overlay = adjustmentOverlay, !overlay.isHidden else { return false }
        return overlay.frame.insetBy(dx: -24, dy: -24).contains(point)
    }

    private func prioritizeRegionGestures(_ recognizers: [UIGestureRecognizer]) {
        guard !recognizers.isEmpty else { return }
        let pageSwipes = gestureRecognizers?.compactMap { $0 as? PageSwipeGestureRecognizer } ?? []
        let scrollPan = descendantScrollView(in: self)?.panGestureRecognizer
        let navPop = enclosingNavigationController?.interactivePopGestureRecognizer

        for recognizer in recognizers {
            deselectionTap.require(toFail: recognizer)
            scrollPan?.require(toFail: recognizer)
            navPop?.require(toFail: recognizer)
            for swipe in pageSwipes {
                swipe.require(toFail: recognizer)
            }
        }
    }

    private var enclosingNavigationController: UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let nav = next as? UINavigationController { return nav }
            if let vc = next as? UIViewController, let nav = vc.navigationController { return nav }
            responder = next
        }
        return nil
    }

    override func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if gestureRecognizer === deselectionTap || otherGestureRecognizer === deselectionTap {
            return true
        }
        return super.gestureRecognizer(
            gestureRecognizer,
            shouldRecognizeSimultaneouslyWith: otherGestureRecognizer
        )
    }

    /// Whether the page is sitting at its natural fit rather than at a zoom the
    /// student chose.
    ///
    /// Relative, not absolute. PDFKit nudges `scaleFactor` by small amounts of
    /// its own, and `applyScaleLimits` itself leaves a difference of up to
    /// 0.001 in place while still recording the new resting scale — so at a fit
    /// around 0.5, where an absolute 0.001 is two parts in a thousand, a page
    /// plainly at rest could read as "zoomed".
    private var isAtRestingScale: Bool {
        restingScale == 0 || abs(scaleFactor - restingScale) <= max(0.001, restingScale * 0.005)
    }

    func applyScaleLimits() {
        guard document != nil, bounds.width > 40, bounds.height > 40 else { return }
        let sizeToFit = scaleFactorForSizeToFit
        guard sizeToFit > 0, sizeToFit.isFinite else { return }

        // scaleFactorForSizeToFit fills the bounds; shrinking it by the same
        // ratio the margin takes out of the bounds insets the page by exactly
        // `margin` points, whatever shape the page happens to be.
        let inset = min(
            (bounds.width - 2 * margin) / bounds.width,
            (bounds.height - 2 * margin) / bounds.height
        )
        let fit = sizeToFit * inset
        guard fit > 0 else { return }

        // Follow the new fit when the reader is sitting at the old one (rotation,
        // layout switch, a differently sized page, or animated container resize)
        // rather than stranding the page at a scale that no longer belongs to it.
        let restingAtFit = isAtRestingScale
        if abs(minScaleFactor - fit) > 0.0005 {
            minScaleFactor = fit
        }
        if abs(maxScaleFactor - fit * 6) > 0.0005 {
            maxScaleFactor = fit * 6
        }
        if restingAtFit || scaleFactor < fit {
            if abs(scaleFactor - fit) > 0.001 {
                scaleFactor = fit
            }
        }
        restingScale = fit
    }

    func goToPageAtFinalQuality(_ pageIndex: Int) {
        guard let document, document.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        go(to: page)
        layoutDocumentView()
        setNeedsLayout()
        layoutIfNeeded()
        applyScaleLimits()
    }

    func setPageLayout(twoUp: Bool, anchorPage: Int, animated: Bool) {
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard displayMode != targetMode || displaysAsBook != twoUp else { return }
        guard let document, document.pageCount > 0 else { return }
        let anchorIndex = min(max(anchorPage - 1, 0), document.pageCount - 1)
        guard let anchor = document.page(at: anchorIndex) else { return }

        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        displayMode = targetMode
        displaysAsBook = twoUp
        go(to: anchor)
        restingScale = 0
        layoutDocumentView()
        setNeedsLayout()
        layoutIfNeeded()
        applyScaleLimits()
        if zoomRatio > 1.001, restingScale > 0 {
            scaleFactor = min(restingScale * zoomRatio, maxScaleFactor)
        }
    }
}
