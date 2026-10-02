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
    /// The stand-in shown while the layout changes between one page and a
    /// spread. See `setPageLayout`.
    private var layoutTransition: PageLayoutTransitionStage?
    /// The colour behind the reader. The stand-in paints its backdrop with it,
    /// and covers the live view while PDFKit relayouts, so any difference
    /// would flash for the length of the move.
    var canvasColor: UIColor = .systemGroupedBackground
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

    override func layoutSubviews() {
        super.layoutSubviews()
        // The pictures of a layout change belong to the size they were taken
        // at. A resize under them — the assistant opening, a rotation — would
        // move every page somewhere else, so the change ends where it is.
        if let layoutTransition, layoutTransition.bounds.size != bounds.size {
            finishPageLayoutTransition()
        }
        applyScaleLimits()
        selectionOverlay?.frame = bounds
        observeScrollingIfNeeded()
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
        if let layoutTransition { bringSubviewToFront(layoutTransition) }
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
        if let layoutTransition { bringSubviewToFront(layoutTransition) }
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

        for recognizer in recognizers {
            deselectionTap.require(toFail: recognizer)
            scrollPan?.require(toFail: recognizer)
            for swipe in pageSwipes {
                swipe.require(toFail: recognizer)
            }
        }
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
        // A page turned mid-change would land under pictures of the old page.
        finishPageLayoutTransition()
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: clamped) else { return }
        go(to: page)
        layoutDocumentView()
        setNeedsLayout()
        layoutIfNeeded()
        applyScaleLimits()
    }
}

// MARK: - One page or a spread

extension BookPDFView {
    /// Switch between a single page and a spread.
    ///
    /// PDFKit makes the change in one layout pass that cannot be animated, so
    /// the reader covers the live view with pictures of the pages, lets PDFKit
    /// relayout underneath, and then moves the pictures to where PDFKit put
    /// the real pages before handing back.
    ///
    /// The move is a camera move. The page being read never fades and never
    /// changes shape: going to a spread it shrinks into its half of the
    /// spread while the facing page slides in from the side it is printed on,
    /// as if the reader stepped back from the book; going back it grows into
    /// the middle and its neighbour leaves the same way. What this replaced
    /// scaled a screenshot of the whole view — background included — towards
    /// the middle of the spread while fading it out over the new layout, so
    /// for a third of a second the old page sat ghosted across the gutter of
    /// the new one.
    func setPageLayout(twoUp: Bool, anchorPage: Int, animated: Bool) {
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard displayMode != targetMode || displaysAsBook != twoUp else { return }
        guard let document, document.pageCount > 0 else { return }
        let anchorIndex = min(max(anchorPage - 1, 0), document.pageCount - 1)
        guard let anchor = document.page(at: anchorIndex) else { return }

        finishPageLayoutTransition()
        let oldFrames = frames(ofPages: visiblePages.map { document.index(for: $0) })
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        // Zoomed in, the page runs past the edges of the view and there is no
        // whole page to move. Reduce Motion asks for a dissolve rather than a
        // move. Both get the old layout fading into the new one.
        let movingStage = animated && isAtRestingScale && oldFrames[anchorIndex] != nil
            ? makeMovingStage(oldFrames: oldFrames)
            : nil
        let moves = movingStage != nil
        let stage = movingStage ?? makeDissolvingStage()
        let newIndices = Self.pageIndices(showing: anchorIndex, twoUp: twoUp, pageCount: document.pageCount)

        // Pages the old layout never drew — the facing page of a new spread —
        // and the page that grows into a single page are rendered off the main
        // thread while PDFKit relayouts. A picture taken at the old, smaller
        // size would be stretched soft on its way up.
        var renders: PageLayoutRenders?
        if moves, let url = document.documentURL {
            let wanted = twoUp ? Set(newIndices).subtracting(oldFrames.keys) : [anchorIndex]
            renders = PageLayoutRenders(
                url: url,
                pages: wanted,
                maxPixelDimension: transitionRenderDimension(twoUp: twoUp, page: anchor)
            )
        }

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

        guard let stage else { return }
        addSubview(stage)
        layoutTransition = stage

        // PDFKit settles the new page rectangles on the next run loop, and the
        // renders have to be back before anything moves. Whichever is later
        // starts the move; a render that is slow to arrive is not waited for.
        let begin: (PageLayoutRenders.Images) -> Void = { [weak self, weak stage] images in
            guard let self, let stage, layoutTransition === stage, !stage.hasBegun else { return }
            stage.hasBegun = true
            layoutDocumentView()
            layoutIfNeeded()
            applyScaleLimits()
            let moved = moves
                && runMove(on: stage, anchorIndex: anchorIndex, newIndices: newIndices, images: images)
            if !moved { handBack(stage, duration: 0.24) }
        }
        if let renders {
            renders.start { images in begin(images) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { begin(renders.finished) }
        } else {
            DispatchQueue.main.async { begin([:]) }
        }
    }

    /// The pages PDFKit puts on screen for a page in a layout: the page alone,
    /// or the spread it belongs to. A book's cover stands by itself and the
    /// rest pair up as they are printed, two with three, four with five.
    static func pageIndices(showing index: Int, twoUp: Bool, pageCount: Int) -> [Int] {
        guard twoUp, index > 0 else { return [index] }
        let left = index.isMultiple(of: 2) ? index - 1 : index
        return [left, left + 1].filter { $0 < pageCount }
    }

    /// Where each page sits in this view, keyed by page index.
    private func frames(ofPages indices: [Int]) -> [Int: CGRect] {
        guard let document else { return [:] }
        var frames: [Int: CGRect] = [:]
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            let frame = convert(page.bounds(for: .cropBox), from: page).standardized
            if !frame.isNull, !frame.isEmpty { frames[index] = frame }
        }
        return frames
    }

    /// The largest the rendered pages are shown at, in pixels: the page fitted
    /// into the whole view for a single page, into half of it for a spread.
    private func transitionRenderDimension(twoUp: Bool, page: PDFPage) -> Int {
        let box = page.bounds(for: .cropBox).size
        let room = CGSize(width: twoUp ? bounds.width / 2 : bounds.width, height: bounds.height)
        guard box.width > 0, box.height > 0, room.width > 0, room.height > 0 else { return 1024 }
        let fit = min(room.width / box.width, room.height / box.height)
        let points = max(box.width, box.height) * fit
        let scale = max(traitCollection.displayScale, 1)
        return min(2048, max(512, Int((points * scale).rounded(.up))))
    }

    /// A stand-in for the moving case: every page on screen, cut out of the
    /// view as it is drawn right now, shadow and all, on the reader's own
    /// backdrop.
    private func makeMovingStage(oldFrames: [Int: CGRect]) -> PageLayoutTransitionStage? {
        let stage = PageLayoutTransitionStage(frame: bounds, backdrop: canvasColor)
        for (index, frame) in oldFrames {
            // The margin takes PDFKit's own page shadow along with the page.
            let margin = PageLayoutTransitionStage.shadowMargin
            let cut = frame.insetBy(dx: -margin, dy: -margin).intersection(bounds)
            guard !cut.isNull, !cut.isEmpty,
                  let picture = resizableSnapshotView(from: cut, afterScreenUpdates: false, withCapInsets: .zero)
            else { return nil }
            stage.addPage(
                index: index,
                picture: picture,
                frame: cut.offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                pageFrame: frame.offsetBy(dx: -cut.minX, dy: -cut.minY)
            )
        }
        return stage.isEmpty ? nil : stage
    }

    /// A stand-in for the dissolve: the whole view as it was.
    private func makeDissolvingStage() -> PageLayoutTransitionStage? {
        guard let picture = snapshotView(afterScreenUpdates: false) else { return nil }
        let stage = PageLayoutTransitionStage(frame: bounds, backdrop: canvasColor)
        stage.addBackdropPicture(picture)
        return stage
    }

    /// Moves the pictures from the old layout to the new one. False when the
    /// new layout is not what it was expected to be, which the caller answers
    /// with a dissolve instead.
    private func runMove(
        on stage: PageLayoutTransitionStage,
        anchorIndex: Int,
        newIndices: [Int],
        images: PageLayoutRenders.Images
    ) -> Bool {
        let newFrames = frames(ofPages: newIndices)
        let visible = bounds.insetBy(dx: -1, dy: -1)
        guard newFrames.count == newIndices.count,
              newFrames.values.allSatisfy({ visible.contains($0) }),
              let oldAnchor = stage.pageFrame(of: anchorIndex),
              let newAnchor = newFrames[anchorIndex].map({ $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }),
              oldAnchor.width > 0
        else { return false }

        // One transform for the whole stage, chosen so the page being read
        // lands exactly on its new rectangle. Everything else follows it,
        // which is what makes the move read as one camera rather than as
        // several pages each finding their own way.
        let scale = newAnchor.width / oldAnchor.width
        let center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
        let shift = CGPoint(
            x: newAnchor.midX - center.x - scale * (oldAnchor.midX - center.x),
            y: newAnchor.midY - center.y - scale * (oldAnchor.midY - center.y)
        )

        // A page that is new to the screen is placed where that same camera
        // would have had it before the move: beside the current page, at its
        // size, mostly out of view.
        var arriving: [UIView] = []
        for index in newIndices where !stage.hasPage(index) {
            guard let image = images[index], let newFrame = newFrames[index] else { return false }
            let target = newFrame.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
            let start = CGRect(
                x: center.x + (target.minX - center.x - shift.x) / scale,
                y: center.y + (target.minY - center.y - shift.y) / scale,
                width: target.width / scale,
                height: target.height / scale
            )
            let page = stage.addRenderedPage(index: index, image: image, frame: start)
            page.alpha = 0
            arriving.append(page)
        }
        // The page that grows swaps its picture for a sharp one before it
        // starts to grow; at its current size the two are the same.
        if scale > 1.1, let image = images[anchorIndex] {
            stage.sharpen(index: anchorIndex, with: image)
        }
        let leaving = stage.pages(notIn: Set(newIndices))

        UIView.animate(
            springDuration: 0.52,
            bounce: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            stage.camera.transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: scale, tx: shift.x, ty: shift.y
            )
        } completion: { [weak self, weak stage] _ in
            guard let self, let stage, layoutTransition === stage else { return }
            handBack(stage, duration: 0.16)
        }
        UIView.animate(withDuration: 0.34, delay: 0.04, options: [.curveEaseOut, .allowUserInteraction]) {
            arriving.forEach { $0.alpha = 1 }
        }
        UIView.animate(withDuration: 0.26, delay: 0, options: [.curveEaseIn, .allowUserInteraction]) {
            leaving.forEach { $0.alpha = 0 }
        }
        return true
    }

    /// Fades the stand-in away over the live view. After a move the pictures
    /// sit exactly on PDFKit's pages, so all that changes is that the live
    /// pages are sharp at any zoom; without one, the old layout dissolves into
    /// the new one where it stands.
    private func handBack(_ stage: PageLayoutTransitionStage, duration: TimeInterval) {
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
        ) {
            stage.alpha = 0
        } completion: { [weak self, weak stage] _ in
            guard let self, let stage, layoutTransition === stage else { return }
            finishPageLayoutTransition()
        }
    }

    private func finishPageLayoutTransition() {
        guard let stage = layoutTransition else { return }
        layoutTransition = nil
        stage.cancel()
        stage.removeFromSuperview()
    }
}
