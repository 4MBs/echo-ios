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
    private var resizeSnapshot: UIView?
    private var resizeCompletion: DispatchWorkItem?
    private var hiddenDuringResize: [UIView] = []
    private var holdsPDFLayout = false
    private var resizeSnapshotBaseBounds = CGRect.zero
    private var resizeSnapshotContentFrame = CGRect.zero
    private var resizeSnapshotFollowsFit = false
    private var pageRenderCache: BookPageRenderCache?
    private var finalQualityOverlay: UIView?
    private var layoutTransitionOverlay: UIView?
    private var navigationGeneration = 0
    private var layoutGeneration = 0
    private weak var observedScrollView: UIScrollView?
    private var scrollObservations: [NSKeyValueObservation] = []
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
        // PDFKit rebuilds page tiles synchronously for every intermediate width
        // of a split-view animation. Keep its hierarchy at the last stable
        // layout while a lightweight snapshot follows the system animation.
        if holdsPDFLayout {
            updateResizeSnapshotLayout()
            if let resizeSnapshot { bringSubviewToFront(resizeSnapshot) }
            return
        }
        super.layoutSubviews()
        applyScaleLimits()
        prepareVisibleAndNeighboringPages()
        selectionOverlay?.frame = bounds
        observeScrollingIfNeeded()
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    func beginRegionSelection(onSelected: @escaping (BackendAPI.BookPageRegion) -> Void) {
        cancelRegionSelection()
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
        discardFinalQualityOverlay()
    }

    private func descendantScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = descendantScrollView(in: subview) { return nested }
        }
        return nil
    }

    @objc private func tappedOutsideSelection(_ recognizer: UITapGestureRecognizer) {
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
        // layout switch, a differently sized page) rather than stranding the page
        // at a scale that no longer belongs to it.
        let restingAtFit = restingScale == 0 || abs(scaleFactor - restingScale) < 0.001
        if abs(minScaleFactor - fit) > 0.0005 {
            minScaleFactor = fit
        }
        if abs(maxScaleFactor - fit * 6) > 0.0005 {
            maxScaleFactor = fit * 6
        }
        if restingAtFit || scaleFactor < fit, abs(scaleFactor - fit) > 0.001 {
            scaleFactor = fit
        }
        restingScale = fit
    }

    /// Page turns never expose PDFKit's provisional tiled render. Neighboring
    /// pages should already be in the device-resolution cache; if a distant
    /// jump misses, the old page remains visible until that same final-quality
    /// render is ready, then the navigation and overlay install happen in one
    /// main-thread turn before the next frame is displayed.
    func goToPageAtFinalQuality(_ pageIndex: Int) {
        guard let document, document.pageCount > 0 else { return }
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        let targets = expectedPageIndices(containing: clamped, twoUp: displaysAsBook)
        let dimension = renderPixelDimension
        guard let cache = pageCache else {
            if let page = document.page(at: clamped) { go(to: page) }
            return
        }

        navigationGeneration += 1
        let generation = navigationGeneration
        cache.prepare(pageIndices: targets, maxPixelDimension: dimension) { [weak self] in
            guard let self, generation == navigationGeneration,
                  let page = self.document?.page(at: clamped)
            else { return }
            discardFinalQualityOverlay()
            go(to: page)
            layoutDocumentView()
            layoutIfNeeded()
            applyScaleLimits()
            installFinalQualityOverlay()
            prepareVisibleAndNeighboringPages()
        }
    }

    /// Change PDFKit's layout in place. Device-resolution page planes cover the
    /// live tiles and move between their old and new frames; newly added pages
    /// enter from the side and removed pages leave spatially, with no opacity
    /// animation or replacement of the representable.
    func setPageLayout(twoUp: Bool, anchorPage: Int, animated: Bool) {
        let targetMode: PDFDisplayMode = twoUp ? .twoUp : .singlePage
        guard displayMode != targetMode || displaysAsBook != twoUp else {
            // Invalidates an asynchronous render requested for a mode the user
            // has already toggled away from.
            layoutGeneration += 1
            return
        }

        guard let document, document.pageCount > 0 else { return }
        let anchorIndex = min(max(anchorPage - 1, 0), document.pageCount - 1)
        let current = Set(visiblePages.map { document.index(for: $0) })
        let target = expectedPageIndices(containing: anchorIndex, twoUp: twoUp)
        let required = current.union(target)
        let dimension = renderPixelDimension

        layoutGeneration += 1
        let generation = layoutGeneration
        guard let cache = pageCache else {
            performPageLayout(twoUp: twoUp, anchorIndex: anchorIndex, animated: animated)
            return
        }
        cache.prepare(pageIndices: required, maxPixelDimension: dimension) { [weak self] in
            guard let self, generation == layoutGeneration else { return }
            performPageLayout(twoUp: twoUp, anchorIndex: anchorIndex, animated: animated)
        }
    }

    private func performPageLayout(twoUp: Bool, anchorIndex: Int, animated: Bool) {
        guard let document, let anchor = document.page(at: anchorIndex) else { return }
        completePendingResize()
        layoutTransitionOverlay?.removeFromSuperview()
        layoutTransitionOverlay = nil

        let dimension = renderPixelDimension
        let oldPages = Dictionary(uniqueKeysWithValues: visiblePages.map {
            (document.index(for: $0), convert($0.bounds(for: .cropBox), from: $0).standardized)
        })
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        discardFinalQualityOverlay()

        displayMode = twoUp ? .twoUp : .singlePage
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

        let newPages = Dictionary(uniqueKeysWithValues: visiblePages.map {
            (document.index(for: $0), convert($0.bounds(for: .cropBox), from: $0).standardized)
        })
        guard animated, !oldPages.isEmpty, !newPages.isEmpty else {
            installFinalQualityOverlay()
            prepareVisibleAndNeighboringPages()
            return
        }

        installSpatialLayoutTransition(oldPages: oldPages, newPages: newPages, dimension: dimension)
    }

    private func installSpatialLayoutTransition(
        oldPages: [Int: CGRect],
        newPages: [Int: CGRect],
        dimension: Int
    ) {
        let canvas = UIView(frame: bounds)
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvas.isUserInteractionEnabled = false
        canvas.accessibilityElementsHidden = true
        for frame in newPages.values {
            let cover = UIView(frame: frame)
            cover.backgroundColor = .systemGroupedBackground
            canvas.addSubview(cover)
        }

        struct MovingPage {
            let view: UIImageView
            let destination: CGRect
        }
        var moving: [MovingPage] = []
        let retained = Set(oldPages.keys).intersection(newPages.keys)
        let retainedCenter = retained.first.flatMap { newPages[$0]?.midX } ?? bounds.midX
        for pageIndex in Set(oldPages.keys).union(newPages.keys).sorted() {
            guard let image = pageCache?.image(pageIndex: pageIndex, maxPixelDimension: dimension) else {
                continue
            }
            guard let frames = transitionFrames(
                pageIndex: pageIndex,
                oldPages: oldPages,
                newPages: newPages,
                retainedCenter: retainedCenter
            ) else { continue }
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            imageView.frame = frames.start
            canvas.addSubview(imageView)
            moving.append(MovingPage(view: imageView, destination: frames.destination))
        }

        addSubview(canvas)
        layoutTransitionOverlay = canvas
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }

        UIView.animate(
            withDuration: 0.36,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
            moving.forEach { $0.view.frame = $0.destination }
        } completion: { [weak self, weak canvas] _ in
            guard let self else { return }
            installFinalQualityOverlay()
            canvas?.removeFromSuperview()
            if layoutTransitionOverlay === canvas { layoutTransitionOverlay = nil }
            prepareVisibleAndNeighboringPages()
        }
    }

    private func transitionFrames(
        pageIndex: Int,
        oldPages: [Int: CGRect],
        newPages: [Int: CGRect],
        retainedCenter: CGFloat
    ) -> (start: CGRect, destination: CGRect)? {
        switch (oldPages[pageIndex], newPages[pageIndex]) {
        case let (oldFrame?, newFrame?):
            (oldFrame, newFrame)
        case let (nil, newFrame?):
            (
                offscreenFrame(newFrame, movesRight: newFrame.midX >= retainedCenter),
                newFrame
            )
        case let (oldFrame?, nil):
            (
                oldFrame,
                offscreenFrame(oldFrame, movesRight: oldFrame.midX >= retainedCenter)
            )
        case (nil, nil):
            nil
        }
    }

    private func offscreenFrame(_ frame: CGRect, movesRight: Bool) -> CGRect {
        frame.offsetBy(dx: movesRight ? bounds.width + margin : -(bounds.width + margin), dy: 0)
    }

    private var pageCache: BookPageRenderCache? {
        if pageRenderCache == nil, let document {
            pageRenderCache = BookPageRenderCache(document: document)
        }
        return pageRenderCache
    }

    private var renderPixelDimension: Int {
        let displayScale = window?.screen.scale ?? traitCollection.displayScale
        let zoomRatio = restingScale > 0 ? max(scaleFactor / restingScale, 1) : 1
        return max(256, Int(ceil(max(bounds.width, bounds.height) * displayScale * zoomRatio)))
    }

    private func expectedPageIndices(containing pageIndex: Int, twoUp: Bool) -> Set<Int> {
        guard let document, document.pageCount > 0 else { return [] }
        let clamped = min(max(pageIndex, 0), document.pageCount - 1)
        guard twoUp, clamped > 0 else { return [clamped] }
        let first = clamped.isMultiple(of: 2) ? clamped - 1 : clamped
        return Set([first, first + 1].filter { $0 < document.pageCount })
    }

    private func prepareVisibleAndNeighboringPages() {
        guard let document, bounds.width > 40, bounds.height > 40 else { return }
        let visible = visiblePages.map { document.index(for: $0) }
        guard let first = visible.min(), let last = visible.max() else { return }
        let nearby = Set(max(0, first - 2) ... min(document.pageCount - 1, last + 2))
        pageCache?.prepare(pageIndices: nearby, maxPixelDimension: renderPixelDimension)
    }

    private func installFinalQualityOverlay() {
        guard let document, let cache = pageCache else { return }
        let dimension = renderPixelDimension
        let pageFrames = visiblePages.compactMap { page -> (Int, CGRect)? in
            let index = document.index(for: page)
            let frame = convert(page.bounds(for: .cropBox), from: page).standardized
            return frame.isEmpty ? nil : (index, frame)
        }
        guard !pageFrames.isEmpty,
              pageFrames.allSatisfy({ cache.image(pageIndex: $0.0, maxPixelDimension: dimension) != nil })
        else { return }

        discardFinalQualityOverlay()
        let overlay = UIView(frame: bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        for (pageIndex, frame) in pageFrames {
            guard let image = cache.image(pageIndex: pageIndex, maxPixelDimension: dimension) else { continue }
            let imageView = UIImageView(image: image)
            imageView.frame = frame
            imageView.contentMode = .scaleToFill
            imageView.clipsToBounds = true
            overlay.addSubview(imageView)
        }
        addSubview(overlay)
        finalQualityOverlay = overlay
        if let adjustmentOverlay { bringSubviewToFront(adjustmentOverlay) }
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func discardFinalQualityOverlay() {
        finalQualityOverlay?.removeFromSuperview()
        finalQualityOverlay = nil
    }

    private func completePendingResize() {
        resizeCompletion?.cancel()
        resizeCompletion = nil
        guard holdsPDFLayout || resizeSnapshot != nil else { return }
        holdsPDFLayout = false
        hiddenDuringResize.forEach { $0.isHidden = false }
        hiddenDuringResize.removeAll(keepingCapacity: true)
        discardResizeSnapshot()
        super.layoutSubviews()
    }

    /// Freeze only PDFKit's expensive internal layout during a known animated
    /// container resize. The page snapshot scales uniformly to the new fit;
    /// assigning it the changing bounds directly would squeeze the spread only
    /// horizontally. The live PDF is laid out once at the final size and then
    /// cross-faded back in.
    func prepareForAnimatedResize(duration: TimeInterval) {
        discardFinalQualityOverlay()
        resizeCompletion?.cancel()
        if !holdsPDFLayout {
            // A second toggle can arrive during the one-run-loop hand-off to
            // live PDFKit. Complete that hand-off before capturing the next
            // snapshot so no hidden selection overlay is inherited.
            if resizeSnapshot != nil { finishResizeHandoff() }
            discardResizeSnapshot()
        }
        if !holdsPDFLayout,
           bounds.width > 0,
           bounds.height > 0,
           let snapshot = snapshotView(afterScreenUpdates: false) {
            resizeSnapshotBaseBounds = bounds
            resizeSnapshotContentFrame = visiblePageFrame ?? bounds
            resizeSnapshotFollowsFit = restingScale == 0 || abs(scaleFactor - restingScale) < 0.001
            hiddenDuringResize = subviews.filter { !$0.isHidden }
            hiddenDuringResize.forEach { $0.isHidden = true }
            snapshot.bounds = CGRect(origin: .zero, size: bounds.size)
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
            snapshot.autoresizingMask = []
            snapshot.isUserInteractionEnabled = false
            snapshot.layer.minificationFilter = .trilinear
            snapshot.layer.magnificationFilter = .linear
            addSubview(snapshot)
            resizeSnapshot = snapshot
            holdsPDFLayout = true
        }
        guard holdsPDFLayout else { return }

        let completion = DispatchWorkItem { [weak self] in
            self?.finishAnimatedResize()
        }
        resizeCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion)
    }

    private var visiblePageFrame: CGRect? {
        let frames = visiblePages.map { page in
            convert(page.bounds(for: .cropBox), from: page).standardized
        }.filter { !$0.isNull && !$0.isEmpty }
        guard var frame = frames.first else { return nil }
        for next in frames.dropFirst() {
            frame = frame.union(next)
        }
        return frame
    }

    /// Keeps both axes at one scale throughout the resize. The scale is based
    /// on the visible page rectangle rather than the whole PDFView, whose large
    /// black margins would incorrectly prevent a narrow spread from growing
    /// again when the assistant closes.
    private func updateResizeSnapshotLayout() {
        guard let snapshot = resizeSnapshot,
              resizeSnapshotBaseBounds.width > 0,
              resizeSnapshotBaseBounds.height > 0
        else { return }

        let scale: CGFloat
        if resizeSnapshotFollowsFit {
            let originalFit = snapshotFit(in: resizeSnapshotBaseBounds.size)
            let currentFit = snapshotFit(in: bounds.size)
            scale = originalFit > 0 ? currentFit / originalFit : 1
        } else {
            // Preserve a deliberately zoomed page instead of snapping it back
            // to the minimum fit merely because a panel was opened.
            scale = 1
        }

        let baseCenter = CGPoint(
            x: resizeSnapshotBaseBounds.midX,
            y: resizeSnapshotBaseBounds.midY
        )
        let contentOffset = CGPoint(
            x: resizeSnapshotContentFrame.midX - baseCenter.x,
            y: resizeSnapshotContentFrame.midY - baseCenter.y
        )
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        if resizeSnapshotFollowsFit {
            snapshot.center = CGPoint(
                x: bounds.midX - scale * contentOffset.x,
                y: bounds.midY - scale * contentOffset.y
            )
        } else {
            snapshot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private func snapshotFit(in size: CGSize) -> CGFloat {
        guard resizeSnapshotContentFrame.width > 0,
              resizeSnapshotContentFrame.height > 0,
              size.width > 2 * margin,
              size.height > 2 * margin
        else { return 1 }
        return min(
            (size.width - 2 * margin) / resizeSnapshotContentFrame.width,
            (size.height - 2 * margin) / resizeSnapshotContentFrame.height
        )
    }

    private func finishAnimatedResize() {
        guard holdsPDFLayout else { return }
        resizeCompletion = nil
        holdsPDFLayout = false

        // Restore PDFKit's tiles for the final layout, but keep live selection
        // controls hidden while the snapshot still contains their old copy.
        // Showing both copies during the hand-off produced the doubled blue
        // rectangle visible in the recording.
        let regionViews: [UIView] = [
            selectionOverlay as UIView?,
            adjustmentOverlay as UIView?,
        ].compactMap { $0 }
        hiddenDuringResize
            .filter { hidden in !regionViews.contains(where: { $0 === hidden }) }
            .forEach { $0.isHidden = false }
        setNeedsLayout()
        layoutIfNeeded()
        regionViews.forEach { $0.isHidden = true }

        guard let snapshot = resizeSnapshot else {
            finishResizeHandoff()
            return
        }
        alignResizeSnapshot(to: visiblePageFrame)
        bringSubviewToFront(snapshot)

        // Give PDFKit one display pass to populate its final tiles. The old
        // cross-fade exposed tiny fit differences as a last-frame zoom; after
        // aligning both page rectangles, a direct hand-off is seamless.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if resizeSnapshot === snapshot, !holdsPDFLayout {
                layoutIfNeeded()
                alignResizeSnapshot(to: visiblePageFrame)
                discardResizeSnapshot()
                finishResizeHandoff()
            } else {
                snapshot.removeFromSuperview()
            }
        }
    }

    /// Match the snapshot's captured page rectangle to PDFKit's exact final
    /// page rectangle. This removes the tiny correction zoom at the end of an
    /// otherwise smooth assistant/sidebar animation.
    private func alignResizeSnapshot(to finalContentFrame: CGRect?) {
        guard let snapshot = resizeSnapshot,
              let finalContentFrame,
              resizeSnapshotContentFrame.width > 0,
              resizeSnapshotContentFrame.height > 0
        else { return }

        let scale = min(
            finalContentFrame.width / resizeSnapshotContentFrame.width,
            finalContentFrame.height / resizeSnapshotContentFrame.height
        )
        guard scale > 0, scale.isFinite else { return }

        let snapshotCenter = CGPoint(
            x: resizeSnapshotBaseBounds.midX,
            y: resizeSnapshotBaseBounds.midY
        )
        let contentOffset = CGPoint(
            x: resizeSnapshotContentFrame.midX - snapshotCenter.x,
            y: resizeSnapshotContentFrame.midY - snapshotCenter.y
        )
        snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
        snapshot.center = CGPoint(
            x: finalContentFrame.midX - scale * contentOffset.x,
            y: finalContentFrame.midY - scale * contentOffset.y
        )
    }

    private func finishResizeHandoff() {
        hiddenDuringResize.forEach { $0.isHidden = false }
        hiddenDuringResize.removeAll(keepingCapacity: true)
        updateDisplayedRegion()
        if let selectionOverlay { bringSubviewToFront(selectionOverlay) }
    }

    private func discardResizeSnapshot() {
        resizeSnapshot?.layer.removeAllAnimations()
        resizeSnapshot?.removeFromSuperview()
        resizeSnapshot = nil
        resizeSnapshotBaseBounds = .zero
        resizeSnapshotContentFrame = .zero
        resizeSnapshotFollowsFit = false
    }

    deinit {
        resizeCompletion?.cancel()
    }
}

/// PDFKit wrapper. The non-continuous display modes are the only ones that show
/// a real book: exactly one page (or one 2–3 style spread) fills the screen and
/// nothing scrolls. They bring no page-turn gesture of their own, and the
/// page-view controller that would provide one forces single-page layout — so
/// the sideways flick is added here instead.
