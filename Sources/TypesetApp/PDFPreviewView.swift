// Copyright (c) 2026 Twarge LLC.
// SPDX-License-Identifier: Apache-2.0

import PDFKit
import SwiftUI
import TypesetCore

/// The exact location the user was viewing in the preview: a zoom `scale`
/// (`0` = automatic fit-to-width) plus the top-left of the visible area as a
/// `PDFDestination` (`page` index + `x`/`y` in page coordinates).
struct PreviewViewport: Equatable {
    var scale: Double
    var page: Int
    var x: Double
    var y: Double

    var isMeaningful: Bool { scale > 0 || page > 0 || x != 0 || y != 0 }
}

@MainActor
private func capturePreviewViewport(from pdfView: PDFView) -> PreviewViewport? {
    guard let document = pdfView.document,
          let destination = pdfView.currentDestination,
          let page = destination.page else { return nil }
    let pageIndex = document.index(for: page)
    guard pageIndex != NSNotFound else { return nil }
    let scale = pdfView.autoScales ? 0 : Double(pdfView.scaleFactor)
    return PreviewViewport(
        scale: scale,
        page: pageIndex,
        x: Double(destination.point.x),
        y: Double(destination.point.y)
    )
}

@MainActor
private func applyPreviewViewport(_ viewport: PreviewViewport, to pdfView: PDFView, document: PDFDocument) {
    guard let page = document.page(at: min(max(0, viewport.page), max(0, document.pageCount - 1))) else { return }
    if viewport.scale > 0 {
        pdfView.autoScales = false
        let scale = min(max(CGFloat(viewport.scale), pdfView.minScaleFactor), pdfView.maxScaleFactor)
        if scale.isFinite, scale > 0 {
            pdfView.scaleFactor = scale
        }
    } else {
        pdfView.autoScales = true
    }
    pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: viewport.x, y: viewport.y)))
}

#if os(macOS)
struct PDFPreviewView: NSViewRepresentable {
    var preview: PDFPreview?
    var revision: Int
    var renderWarmupDelay: TimeInterval
    var restoredViewport: PreviewViewport?
    var onViewportChange: (PreviewViewport) -> Void = { _ in }
    var onSeek: (SourceRange) -> Void

    func makeNSView(context: Context) -> BufferedPDFPreviewContainer {
        BufferedPDFPreviewContainer(coordinator: context.coordinator)
    }

    func updateNSView(_ container: BufferedPDFPreviewContainer, context: Context) {
        context.coordinator.update(preview: preview, revision: revision, renderWarmupDelay: renderWarmupDelay, restoredViewport: restoredViewport, onViewportChange: onViewportChange, onSeek: onSeek, in: container)
    }
}
#else
struct PDFPreviewView: UIViewRepresentable {
    var preview: PDFPreview?
    var revision: Int
    var renderWarmupDelay: TimeInterval
    var restoredViewport: PreviewViewport?
    var onViewportChange: (PreviewViewport) -> Void = { _ in }
    var onSeek: (SourceRange) -> Void

    func makeUIView(context: Context) -> BufferedPDFPreviewContainer {
        BufferedPDFPreviewContainer(coordinator: context.coordinator)
    }

    func updateUIView(_ container: BufferedPDFPreviewContainer, context: Context) {
        context.coordinator.update(preview: preview, revision: revision, renderWarmupDelay: renderWarmupDelay, restoredViewport: restoredViewport, onViewportChange: onViewportChange, onSeek: onSeek, in: container)
    }
}
#endif

extension PDFPreviewView {
    func makeCoordinator() -> Coordinator {
        Coordinator(onSeek: onSeek)
    }

    @MainActor final class Coordinator: NSObject {
        var onSeek: (SourceRange) -> Void
        private var activeData: Data?
        private var stagedData: Data?
        private var stagedDocument: PDFDocument?
        private var activeRevision: Int?
        private var stagedRevision: Int?
        private var activeSourceRects: [PreviewSourceRect] = []
        private var stagedSourceRects: [PreviewSourceRect] = []
        private var isSwapScheduled = false
        private var preparationToken = 0
        /// Saved preview viewport (zoom + scroll spot) to apply on the first load
        /// after reopening, so the preview comes up exactly where the user left
        /// it rather than at PDFKit's fit-to-width default. Applied once; after
        /// that the live view's position carries forward through the buffer's
        /// recompile anchor.
        private var restoredViewport: PreviewViewport?
        private var hasAppliedViewportRestore = false
        #if os(iOS)
        /// Delay applying a freshly-compiled PDF into the live `PDFView`
        /// until the user has paused typing for this long. Compiles still
        /// fire on every keystroke (so the preview is always one compile
        /// behind the cursor); we just hold off on the visible swap, which
        /// is what causes PDFKit to mutate first responder on iOS. Each
        /// new compile arrival resets the timer, so during fast typing the
        /// PDF only refreshes when the user takes a breath.
        private static let pdfApplyDebounce: TimeInterval = 0.3
        private var pendingApplyWorkItem: DispatchWorkItem?
        #endif

        init(onSeek: @escaping (SourceRange) -> Void) {
            self.onSeek = onSeek
        }

        func update(preview: PDFPreview?, revision: Int, renderWarmupDelay: TimeInterval, restoredViewport: PreviewViewport?, onViewportChange: @escaping (PreviewViewport) -> Void, onSeek: @escaping (SourceRange) -> Void, in container: BufferedPDFPreviewContainer) {
            self.onSeek = onSeek
            self.restoredViewport = restoredViewport
            // Report the visible view's zoom + scroll spot upward as the user
            // pans and zooms, so the exact location can be persisted.
            container.onViewportChange = onViewportChange

            guard let preview else {
                #if os(iOS)
                pendingApplyWorkItem?.cancel()
                pendingApplyWorkItem = nil
                #endif
                activeData = nil
                stagedData = nil
                stagedDocument = nil
                activeRevision = nil
                stagedRevision = nil
                activeSourceRects = []
                stagedSourceRects = []
                isSwapScheduled = false
                preparationToken += 1
                container.clear()
                return
            }

            guard revision != activeRevision, revision != stagedRevision else { return }

            guard let document = PDFDocument(data: preview.data) else { return }
            stagedData = preview.data
            stagedDocument = document
            stagedRevision = revision
            stagedSourceRects = preview.sourceRects

            #if os(iOS)
            // Hold the visible PDF swap until typing pauses. The compile
            // already ran (this update is its result); we're only delaying
            // the moment we hand the new document to PDFKit, because that
            // hand-off is what disturbs first responder.
            pendingApplyWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak container] in
                guard let self, let container else { return }
                self.pendingApplyWorkItem = nil
                self.applyStagedPreview(in: container, renderWarmupDelay: renderWarmupDelay)
            }
            pendingApplyWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pdfApplyDebounce, execute: workItem)
            #else
            applyStagedPreview(in: container, renderWarmupDelay: renderWarmupDelay)
            #endif
        }

        private func applyStagedPreview(in container: BufferedPDFPreviewContainer, renderWarmupDelay: TimeInterval) {
            guard let document = stagedDocument else { return }
            container.prepareInactiveView(document: document)

            // Apply the target zoom + scroll to the OFF-SCREEN view *now*,
            // before the warmup delay — not at commit time. Assigning a
            // document leaves PDFKit in `autoScales` mode (the fit-to-width
            // "default" zoom); PDFKit then applies an explicit `scaleFactor`
            // on a *later* display cycle. If we deferred the restore to commit
            // (right before the swap), the swap would reveal the new page at
            // fit-zoom for a frame and then visibly jump to the correct zoom.
            // Restoring here lets the hidden view re-render at the real scale
            // during the warmup window, so the swap is seamless.
            restoreZoom(in: container, document: document)

            guard !isSwapScheduled else { return }

            isSwapScheduled = true
            preparationToken += 1
            let currentToken = preparationToken
            container.finishPreparingInactiveView(after: Self.clampedWarmupDelay(renderWarmupDelay)) {
                self.commitStagedPreview(in: container, token: currentToken)
            }
        }

        #if os(macOS)
        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let container = recognizer.view as? BufferedPDFPreviewContainer else { return }
            seek(from: recognizer.location(in: container), in: container)
        }
        #else
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let container = recognizer.view as? BufferedPDFPreviewContainer else { return }
            seek(from: recognizer.location(in: container), in: container)
        }
        #endif

        private func restore(_ anchor: PDFPreviewAnchor, in pdfView: PDFView, document: PDFDocument) {
            guard let page = document.page(at: min(anchor.pageIndex, max(0, document.pageCount - 1))) else { return }

            pdfView.autoScales = false
            let scale = min(max(anchor.scaleFactor, pdfView.minScaleFactor), pdfView.maxScaleFactor)
            if scale.isFinite, scale > 0 {
                pdfView.scaleFactor = scale
            }
            pdfView.go(to: PDFDestination(page: page, at: anchor.point))
            anchor.scrollAnchor?.restore(in: pdfView)
        }

        private static func clampedWarmupDelay(_ delay: TimeInterval) -> TimeInterval {
            min(1, max(0, delay.isFinite ? delay : 0.5))
        }

        /// Matches the off-screen (inactive) view's zoom and scroll position to
        /// the currently visible view, so that when it is swapped to the front
        /// it appears at the same place the user was looking — never at PDFKit's
        /// default fit-to-width zoom. Called during preparation (before warmup),
        /// so the off-screen view has time to re-render at the target scale
        /// before it becomes visible.
        private func restoreZoom(in container: BufferedPDFPreviewContainer, document: PDFDocument) {
            let anchor = PDFPreviewAnchor(pdfView: container.activePDFView)
            if let anchor {
                restore(anchor, in: container.inactivePDFView, document: document)
            } else if let firstPage = document.page(at: 0) {
                // No active document yet — this is the first load. If we have a
                // saved viewport, come up exactly there (zoom + spot), which also
                // avoids the fit-to-width default flashing in; otherwise fall back
                // to auto fit-to-width at the top of the first page.
                let pdfView = container.inactivePDFView
                if !hasAppliedViewportRestore,
                   let viewport = restoredViewport, viewport.isMeaningful {
                    applyPreviewViewport(viewport, to: pdfView, document: document)
                } else {
                    pdfView.autoScales = true
                    pdfView.go(to: firstPage)
                }
                hasAppliedViewportRestore = true
            }
        }

        private func commitStagedPreview(in container: BufferedPDFPreviewContainer, token: Int) {
            guard isSwapScheduled, preparationToken == token else { return }
            isSwapScheduled = false

            guard let data = stagedData else { return }

            // The off-screen view was already populated and zoom-restored in
            // `applyStagedPreview`; committing just promotes it to the front.
            activeData = data
            activeRevision = stagedRevision
            activeSourceRects = stagedSourceRects
            stagedData = nil
            stagedDocument = nil
            stagedRevision = nil
            stagedSourceRects = []
            container.showInactiveView(animated: container.hasVisibleDocument)
        }

        private func seek(from viewPoint: CGPoint, in pdfView: PDFView) {
            guard let range = sourceRange(at: viewPoint, in: pdfView) else { return }
            onSeek(range)
        }

        private func seek(from containerPoint: CGPoint, in container: BufferedPDFPreviewContainer) {
            let pdfView = container.activePDFView
            let viewPoint = pdfView.convert(containerPoint, from: container)
            seek(from: viewPoint, in: pdfView)
        }

        private func sourceRange(at viewPoint: CGPoint, in pdfView: PDFView) -> SourceRange? {
            guard
                let document = pdfView.document,
                let page = pdfView.page(for: viewPoint, nearest: true)
            else { return nil }

            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }

            let point = pdfView.convert(viewPoint, to: page)
            let bounds = page.bounds(for: .cropBox)
            let x = Double(point.x - bounds.minX)
            let y = Double(bounds.maxY - point.y)
            let rects = activeSourceRects.filter { $0.page == pageIndex }
            guard !rects.isEmpty else { return nil }

            var best: PreviewSourceRect?
            var bestScore = Double.infinity
            for rect in rects {
                let left = rect.x
                let top = rect.y
                let width = rect.width
                let height = rect.height
                guard (left + top + width + height).isFinite, width > 0, height > 0 else { continue }

                let contains = x >= left - 1 && x <= left + width + 1 && y >= top - 1 && y <= top + height + 1
                let dx = x < left ? left - x : x > left + width ? x - (left + width) : 0
                let dy = y < top ? top - y : y > top + height ? y - (top + height) : 0
                let distance = abs(dy) + abs(dx) * 0.25
                let score = contains ? distance : 1_000 + distance
                if score < bestScore {
                    best = rect
                    bestScore = score
                }
            }

            guard let best else { return nil }
            return best.range
        }
    }
}

#if os(macOS)
@MainActor final class BufferedPDFPreviewContainer: NSView {
    private let pdfViews: [PDFView]
    private var activeIndex = 0
    private var presentationRevision = 0
    /// Reports the visible view's viewport (zoom + scroll spot) as the user pans
    /// and zooms, so it can be persisted.
    var onViewportChange: ((PreviewViewport) -> Void)?
    /// Suppresses reports while we programmatically restore/swap, so a transient
    /// position doesn't clobber the saved one.
    var isApplyingViewport = false
    private weak var observedScrollClipView: NSView?

    var activePDFView: PDFView { pdfViews[activeIndex] }
    var inactivePDFView: PDFView { pdfViews[1 - activeIndex] }
    var hasVisibleDocument: Bool { activePDFView.document != nil }

    init(coordinator: PDFPreviewView.Coordinator) {
        pdfViews = [Self.makePDFView(), Self.makePDFView()]
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear

        let recognizer = NSClickGestureRecognizer(target: coordinator, action: #selector(PDFPreviewView.Coordinator.handleClick(_:)))
        addGestureRecognizer(recognizer)

        for (index, pdfView) in pdfViews.enumerated() {
            pdfView.frame = bounds
            pdfView.autoresizingMask = [.width, .height]
            pdfView.alphaValue = index == activeIndex ? 1 : 0
            pdfView.isHidden = index != activeIndex
            addSubview(pdfView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewScaleDidChange(_:)),
                name: Notification.Name.PDFViewScaleChanged,
                object: pdfView
            )
        }
    }

    @objc private func pdfViewScaleDidChange(_ notification: Notification) {
        guard let pdfView = notification.object as? PDFView, pdfView === activePDFView else { return }
        reportViewport()
    }

    /// (Re)observes the active view's scroll so panning is reported, not just
    /// zooming. The PDF's internal clip view posts bounds changes for both.
    func observeActiveScroll() {
        if let old = observedScrollClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
            observedScrollClipView = nil
        }
        guard let scrollView = activePDFView.documentView?.enclosingScrollView else { return }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(activeViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        observedScrollClipView = scrollView.contentView
    }

    @objc private func activeViewDidScroll(_ notification: Notification) {
        reportViewport()
    }

    private func reportViewport() {
        guard !isApplyingViewport, let viewport = capturePreviewViewport(from: activePDFView) else { return }
        onViewportChange?(viewport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        for (index, pdfView) in pdfViews.enumerated() {
            pdfView.document = nil
            pdfView.alphaValue = index == activeIndex ? 1 : 0
            pdfView.isHidden = index != activeIndex
        }
    }

    func prepareInactiveView(document: PDFDocument?) {
        presentationRevision += 1
        let pdfView = inactivePDFView
        pdfView.alphaValue = 1
        pdfView.isHidden = false
        addSubview(pdfView, positioned: .below, relativeTo: activePDFView)
        pdfView.frame = bounds
        pdfView.document = document
        layoutPDFView(pdfView)
    }

    func finishPreparingInactiveView(after delay: TimeInterval, _ completion: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPDFView(self.inactivePDFView)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.layoutPDFView(self.inactivePDFView)
                completion()
            }
        }
    }

    func showInactiveView(animated: Bool) {
        isApplyingViewport = true
        let oldView = activePDFView
        let newView = inactivePDFView
        activeIndex = 1 - activeIndex
        observeActiveScroll()
        presentationRevision += 1
        let currentRevision = presentationRevision

        let finish: @Sendable () -> Void = { [weak self, oldView, newView] in
            MainActor.assumeIsolated {
                guard let self, self.presentationRevision == currentRevision else { return }
                oldView.alphaValue = 0
                oldView.isHidden = true
                oldView.document = nil
                newView.alphaValue = 1
                newView.isHidden = false
                self.isApplyingViewport = false
            }
        }

        guard animated else {
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.allowsImplicitAnimation = true
            oldView.animator().alphaValue = 0
        } completionHandler: {
            finish()
        }
    }

    private static func makePDFView() -> PDFView {
        let pdfView = PDFView(frame: .zero)
        configure(pdfView)
        return pdfView
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPDFViews()
        }
    }

    override func layout() {
        super.layout()
        relayoutPDFViews()
    }

    private func relayoutPDFViews() {
        for pdfView in pdfViews {
            pdfView.frame = bounds
            guard pdfView.document != nil else { continue }
            layoutPDFView(pdfView)
        }
    }

    private func layoutPDFView(_ pdfView: PDFView) {
        Self.configureScrollContainers(in: pdfView)
        pdfView.layoutDocumentView()
        pdfView.layoutSubtreeIfNeeded()
        Self.configureScrollContainers(in: pdfView)
    }

    private static func configure(_ pdfView: PDFView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsetsZero
        pdfView.pageShadowsEnabled = false
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5
        pdfView.backgroundColor = .clear
    }

    private static func configureScrollContainers(in view: NSView) {
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsetsZero
            scrollView.scrollerInsets = NSEdgeInsetsZero
        }

        for subview in view.subviews {
            configureScrollContainers(in: subview)
        }
    }
}
#else
/// `PDFView` on iOS becomes first responder when its `document` is assigned,
/// which steals first responder from the editor's `UITextView` every time
/// the preview recompiles (i.e., on nearly every keystroke). We don't need
/// PDFView to be a responder — tap-to-seek is implemented via a gesture
/// recognizer on the surrounding container, not on the PDFView itself —
/// so we refuse the responder role at the root cause.
@MainActor private final class FocusPreservingPDFView: PDFView {
    override var canBecomeFirstResponder: Bool { false }
    override func becomeFirstResponder() -> Bool { false }
}

private func pdfInternalScrollView(in view: UIView) -> UIScrollView? {
    if let scrollView = view as? UIScrollView { return scrollView }
    for subview in view.subviews {
        if let scrollView = pdfInternalScrollView(in: subview) { return scrollView }
    }
    return nil
}

@MainActor final class BufferedPDFPreviewContainer: UIView {
    private let pdfViews: [PDFView]
    private var activeIndex = 0
    private var presentationRevision = 0
    /// Reports the visible view's viewport (zoom + scroll spot) as the user pans
    /// and zooms, so it can be persisted.
    var onViewportChange: ((PreviewViewport) -> Void)?
    /// Suppresses reports while we programmatically restore/swap.
    var isApplyingViewport = false
    private var scrollObservation: NSKeyValueObservation?

    var activePDFView: PDFView { pdfViews[activeIndex] }
    var inactivePDFView: PDFView { pdfViews[1 - activeIndex] }
    var hasVisibleDocument: Bool { activePDFView.document != nil }

    init(coordinator: PDFPreviewView.Coordinator) {
        pdfViews = [Self.makePDFView(), Self.makePDFView()]
        super.init(frame: .zero)
        backgroundColor = .clear

        let recognizer = UITapGestureRecognizer(target: coordinator, action: #selector(PDFPreviewView.Coordinator.handleTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        addGestureRecognizer(recognizer)

        for (index, pdfView) in pdfViews.enumerated() {
            pdfView.frame = bounds
            pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            pdfView.alpha = index == activeIndex ? 1 : 0
            pdfView.isHidden = index != activeIndex
            addSubview(pdfView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pdfViewScaleDidChange(_:)),
                name: Notification.Name.PDFViewScaleChanged,
                object: pdfView
            )
        }
    }

    @objc private func pdfViewScaleDidChange(_ notification: Notification) {
        guard let pdfView = notification.object as? PDFView, pdfView === activePDFView else { return }
        reportViewport()
    }

    /// (Re)observes the active view's internal scroll view so panning is
    /// reported, not just zooming.
    func observeActiveScroll() {
        scrollObservation?.invalidate()
        scrollObservation = nil
        guard let scrollView = pdfInternalScrollView(in: activePDFView) else { return }
        scrollObservation = scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.reportViewport()
            }
        }
    }

    private func reportViewport() {
        guard !isApplyingViewport, let viewport = capturePreviewViewport(from: activePDFView) else { return }
        onViewportChange?(viewport)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        for (index, pdfView) in pdfViews.enumerated() {
            pdfView.document = nil
            pdfView.alpha = index == activeIndex ? 1 : 0
            pdfView.isHidden = index != activeIndex
        }
    }

    func prepareInactiveView(document: PDFDocument?) {
        presentationRevision += 1
        let pdfView = inactivePDFView
        let previousResponder = window?.findFirstResponderInTree
        pdfView.alpha = 1
        pdfView.isHidden = false
        insertSubview(pdfView, belowSubview: activePDFView)
        pdfView.frame = bounds
        pdfView.document = document
        layoutPDFView(pdfView)
        Self.restoreFirstResponder(previousResponder, attemptsRemaining: 4)
    }

    func finishPreparingInactiveView(after delay: TimeInterval, _ completion: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPDFView(self.inactivePDFView)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.layoutPDFView(self.inactivePDFView)
                completion()
            }
        }
    }

    func showInactiveView(animated: Bool) {
        isApplyingViewport = true
        let oldView = activePDFView
        let newView = inactivePDFView
        activeIndex = 1 - activeIndex
        observeActiveScroll()
        presentationRevision += 1
        let currentRevision = presentationRevision
        let previousResponder = window?.findFirstResponderInTree

        let finish: @Sendable () -> Void = { [weak self, oldView, newView] in
            MainActor.assumeIsolated {
                guard let self, self.presentationRevision == currentRevision else { return }
                oldView.alpha = 0
                oldView.isHidden = true
                oldView.document = nil
                newView.alpha = 1
                newView.isHidden = false
                self.isApplyingViewport = false
                Self.restoreFirstResponder(previousResponder, attemptsRemaining: 4)
            }
        }

        guard animated else {
            finish()
            return
        }

        UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            oldView.alpha = 0
        } completion: { _ in
            finish()
        }
    }

    /// Re-claims first responder for the view that owned it before a PDF
    /// document swap. Setting `pdfView.document` (and the surrounding
    /// re-parenting / layout work) on iOS resigns first responder on the
    /// previously-focused view — typically the editor's `UITextView` —
    /// without us touching focus ourselves. Restoring on the next run-loop
    /// cycle lets PDFKit's responder mutation settle before we put the
    /// caret back where the user left it. Retries handle the case where
    /// PDFKit's claim arrives asynchronously over a couple of runloops.
    private static func restoreFirstResponder(_ responder: UIResponder?, attemptsRemaining: Int) {
        guard let responder, attemptsRemaining > 0 else { return }
        DispatchQueue.main.async { [weak responder] in
            guard let responder else { return }
            if responder.isFirstResponder { return }
            if responder.canBecomeFirstResponder, responder.becomeFirstResponder() { return }
            restoreFirstResponder(responder, attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private static func makePDFView() -> PDFView {
        let pdfView = FocusPreservingPDFView(frame: .zero)
        configure(pdfView)
        return pdfView
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPDFViews()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        relayoutPDFViews()
    }

    private func relayoutPDFViews() {
        for pdfView in pdfViews {
            pdfView.frame = bounds
            guard pdfView.document != nil else { continue }
            layoutPDFView(pdfView)
        }
    }

    private func layoutPDFView(_ pdfView: PDFView) {
        Self.configureScrollContainers(in: pdfView)
        pdfView.layoutDocumentView()
        pdfView.layoutIfNeeded()
        Self.configureScrollContainers(in: pdfView)
    }

    private static func configure(_ pdfView: PDFView) {
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = .zero
        pdfView.pageShadowsEnabled = false
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.25
        pdfView.maxScaleFactor = 5
        pdfView.backgroundColor = .clear
    }

    private static func configureScrollContainers(in view: UIView) {
        if let scrollView = view as? UIScrollView {
            scrollView.backgroundColor = .clear
            scrollView.contentInset = .zero
            scrollView.scrollIndicatorInsets = .zero
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        for subview in view.subviews {
            configureScrollContainers(in: subview)
        }
    }
}

private extension UIView {
    /// Walks the view hierarchy rooted at `self` to find the current first
    /// responder. Used to cache the focused editor view before a PDF
    /// document swap, so we can put focus back afterwards.
    var findFirstResponderInTree: UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findFirstResponderInTree {
                return responder
            }
        }
        return nil
    }
}
#endif

@MainActor private struct PDFPreviewAnchor {
    var pageIndex: Int
    var point: CGPoint
    var scaleFactor: CGFloat
    var scrollAnchor: PDFScrollAnchor?

    init?(pdfView: PDFView) {
        guard
            let document = pdfView.document,
            let page = pdfView.page(for: CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), nearest: true) ?? pdfView.currentPage
        else { return nil }

        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else { return nil }
        self.pageIndex = pageIndex
        self.point = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        self.scaleFactor = pdfView.scaleFactor
        self.scrollAnchor = PDFScrollAnchor(pdfView: pdfView)
    }
}

#if os(macOS)
@MainActor private struct PDFScrollAnchor {
    var origin: CGPoint
    var contentSize: CGSize

    init?(pdfView: PDFView) {
        guard
            let scrollView = pdfView.documentView?.enclosingScrollView,
            let documentView = scrollView.documentView
        else { return nil }
        origin = scrollView.contentView.bounds.origin
        contentSize = documentView.bounds.size
    }

    func restore(in pdfView: PDFView) {
        guard
            let scrollView = pdfView.documentView?.enclosingScrollView,
            let documentView = scrollView.documentView
        else { return }

        let target = Self.scaledOrigin(
            origin,
            from: contentSize,
            to: documentView.bounds.size,
            viewportSize: scrollView.contentView.bounds.size
        )
        scrollView.contentView.scroll(to: target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scaledOrigin(_ origin: CGPoint, from oldSize: CGSize, to newSize: CGSize, viewportSize: CGSize) -> CGPoint {
        let maxOldX = max(0, oldSize.width - viewportSize.width)
        let maxOldY = max(0, oldSize.height - viewportSize.height)
        let maxNewX = max(0, newSize.width - viewportSize.width)
        let maxNewY = max(0, newSize.height - viewportSize.height)
        let xRatio = maxOldX > 0 ? origin.x / maxOldX : 0
        let yRatio = maxOldY > 0 ? origin.y / maxOldY : 0
        return CGPoint(
            x: min(maxNewX, max(0, maxNewX * xRatio)),
            y: min(maxNewY, max(0, maxNewY * yRatio))
        )
    }
}
#else
@MainActor private struct PDFScrollAnchor {
    var offset: CGPoint
    var contentSize: CGSize

    init?(pdfView: PDFView) {
        guard let scrollView = Self.scrollView(in: pdfView) else { return nil }
        offset = scrollView.contentOffset
        contentSize = scrollView.contentSize
    }

    func restore(in pdfView: PDFView) {
        guard let scrollView = Self.scrollView(in: pdfView) else { return }
        let target = Self.scaledOffset(
            offset,
            from: contentSize,
            to: scrollView.contentSize,
            viewportSize: scrollView.bounds.size
        )
        scrollView.setContentOffset(target, animated: false)
    }

    private static func scaledOffset(_ offset: CGPoint, from oldSize: CGSize, to newSize: CGSize, viewportSize: CGSize) -> CGPoint {
        let maxOldX = max(0, oldSize.width - viewportSize.width)
        let maxOldY = max(0, oldSize.height - viewportSize.height)
        let maxNewX = max(0, newSize.width - viewportSize.width)
        let maxNewY = max(0, newSize.height - viewportSize.height)
        let xRatio = maxOldX > 0 ? offset.x / maxOldX : 0
        let yRatio = maxOldY > 0 ? offset.y / maxOldY : 0
        return CGPoint(
            x: min(maxNewX, max(0, maxNewX * xRatio)),
            y: min(maxNewY, max(0, maxNewY * yRatio))
        )
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = scrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }
}
#endif
