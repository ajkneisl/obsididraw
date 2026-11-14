import PencilKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// The PencilKit canvas with page backgrounds drawn behind the ink, fit to the window's width.
struct CanvasView: UIViewRepresentable {
    let document: EditorDocument
    /// Bumped whenever `document.drawing` is replaced from outside the canvas (page setup changes).
    let revision: Int
    var allowsFingerDrawing: Bool
    /// While set, dragging draws this shape instead of freehand ink.
    var shapeKind: ShapeKind?
    var onChange: (PKDrawing) -> Void
    /// Called when a touch or Pencil stroke on the canvas lifts.
    var onTouch: () -> Void
    /// Called when the user pulls past the last page; nil when pages can't be added.
    var onAddPage: (() -> Void)?
    var proxy: CanvasProxy?

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    func makeUIView(context: Context) -> PageCanvasView {
        let canvas = PageCanvasView()
        canvas.configure(layout: document.layout, paper: document.paper, pdf: document.pdf)
        canvas.drawing = document.drawing
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = drawingPolicy
        canvas.onAddPage = onAddPage
        canvas.onTouch = onTouch
        canvas.setShapeKind(shapeKind)
        proxy?.canvas = canvas
        context.coordinator.revision = revision
        canvas.attachToolPicker()
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        canvas.onAddPage = onAddPage
        canvas.onTouch = onTouch
        canvas.drawingPolicy = drawingPolicy
        canvas.setShapeKind(shapeKind)
        proxy?.canvas = canvas
        canvas.configure(layout: document.layout, paper: document.paper, pdf: document.pdf)
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            canvas.drawing = document.drawing
        }
        canvas.scheduleToolPickerReclaim()
    }

    static func dismantleUIView(_ canvas: PageCanvasView, coordinator: Coordinator) {
        canvas.detachToolPicker()
    }

    private var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(macCatalyst)
        .anyInput
        #else
        allowsFingerDrawing ? .anyInput : .pencilOnly
        #endif
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onChange: (PKDrawing) -> Void
        var revision = 0

        init(onChange: @escaping (PKDrawing) -> Void) {
            self.onChange = onChange
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            canvasView.setNeedsLayout()
            onChange(canvasView.drawing)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? PageCanvasView)?.updatePullToAdd()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? PageCanvasView)?.zoomDidChange()
        }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            (scrollView as? PageCanvasView)?.finishPullToAdd()
        }
    }
}

/// Lets the editor's toolbar ask the canvas what is on screen.
final class CanvasProxy {
    fileprivate weak var canvas: PageCanvasView?

    /// The page at the middle of the screen.
    var pageInView: Int? { canvas?.pageInView }
}

final class PageCanvasView: PKCanvasView {
    var onAddPage: (() -> Void)?
    var onTouch: (() -> Void)?

    /// One picker for every canvas, so nothing is handed over when switching documents and the
    /// selected tool carries across them.
    private static let toolPicker: PKToolPicker = {
        let picker = PKToolPicker()
        picker.addObserver(inkMemory)
        inkMemory.toolPickerSelectedToolItemDidChange(picker)
        return picker
    }()
    private static let inkMemory = InkMemory()

    private let pagesView = UIView()
    private let pullLabel = UILabel()
    private var pageViews: [UIView] = []
    private var templateLayers: [CAShapeLayer] = []
    private var layout: PageLayout?
    private var paper: Paper?
    private var pdf: CGPDFDocument?
    private var fittedWidth: CGFloat = 0
    private var isPullArmed = false
    private var scrollsToLastPage = false
    private var scrollsBackToContent = false
    private var refitOffsetY: CGFloat?
    private var keepsToolPicker = false
    private var isReclaimScheduled = false

    private var shapeKind: ShapeKind?
    private var shapeStart: CGPoint?
    private var shapeTool: PKInkingTool { Self.inkMemory.tool }
    private let shapePreview = CAShapeLayer()
    private lazy var shapeRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleShapeDrag))
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = false
        return recognizer
    }()

    /// How far past the end, in screen points, the user has to pull to add a page.
    private static let pullThreshold: CGFloat = 90

    /// The surface around the pages, distinct from both the default light and dark page colors.
    /// Shown behind the canvas, which has to stay transparent: PencilKit paints the canvas's own
    /// background over anything placed inside it, which would hide the pages.
    static let deskColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? .black : UIColor(white: 0.84, alpha: 1)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pagesView.isUserInteractionEnabled = false
        pagesView.layer.anchorPoint = .zero
        insertSubview(pagesView, at: 0)

        pullLabel.font = .preferredFont(forTextStyle: .subheadline)
        pullLabel.textColor = .secondaryLabel
        pullLabel.textAlignment = .center
        pullLabel.alpha = 0
        addSubview(pullLabel)

        shapePreview.fillColor = nil
        shapePreview.lineCap = .round
        shapePreview.lineJoin = .round
        // Page views are added to `pagesView` later, so this keeps the preview above them.
        shapePreview.zPosition = 1
        pagesView.layer.addSublayer(shapePreview)
        addGestureRecognizer(shapeRecognizer)
        addGestureRecognizer(TouchLiftObserver { [weak self] in
            self?.scheduleToolPickerReclaim()
            self?.onTouch?()
        })

        for name in [UIScene.didActivateNotification, UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(scheduleToolPickerReclaim), name: name, object: nil)
        }

        alwaysBounceVertical = true
        backgroundColor = .clear
        isOpaque = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (canvas: PageCanvasView, _) in
            canvas.applyPageColors()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleToolPickerReclaim()
    }

    // MARK: Tool picker

    func attachToolPicker() {
        keepsToolPicker = true
        Self.toolPicker.addObserver(self)
        Self.toolPicker.setVisible(true, forFirstResponder: self)
    }

    func detachToolPicker() {
        keepsToolPicker = false
        Self.toolPicker.setVisible(false, forFirstResponder: self)
        Self.toolPicker.removeObserver(self)
        _ = resignFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { scheduleToolPickerReclaim() }
        return resigned
    }

    /// The tool picker only shows while the canvas is first responder, which it can lose to
    /// presentations, text fields, the sidebar, or the app leaving the foreground.
    @objc func scheduleToolPickerReclaim() {
        guard keepsToolPicker, !isFirstResponder, !isReclaimScheduled else { return }
        isReclaimScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.isReclaimScheduled = false
            self?.reclaimToolPicker()
        }
    }

    private func reclaimToolPicker() {
        guard keepsToolPicker, !isFirstResponder, let window, window.windowScene?.activationState == .foregroundActive else { return }
        // Text being typed elsewhere keeps its keyboard; its end-of-editing notification brings us back.
        guard !(UIResponder.currentFirstResponder is UIKeyInput) else { return }
        if window.rootViewController?.presentedViewController != nil {
            // Nothing announces when a sheet or alert has gone, so check again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.scheduleToolPickerReclaim() }
            return
        }
        _ = becomeFirstResponder()
    }

    // MARK: Shapes

    /// PencilKit's drawing gestures. It keeps a second one beside the one it exposes, and other
    /// drags on the canvas only start once both have given up, so shapes need both turned off:
    /// with one left on, a shape starts a third of a second into its drag.
    private var drawingRecognizers: [UIGestureRecognizer] {
        let exposed = drawingGestureRecognizer
        return exposed.view?.gestureRecognizers?.filter { type(of: $0) == type(of: exposed) } ?? [exposed]
    }

    func setShapeKind(_ kind: ShapeKind?) {
        if kind != shapeKind { endShapePreview() }
        let wasDrawingShapes = shapeKind != nil
        shapeKind = kind
        shapeRecognizer.isEnabled = kind != nil
        let types: [UITouch.TouchType] = drawingPolicy == .pencilOnly ? [.pencil] : [.pencil, .direct, .indirectPointer]
        shapeRecognizer.allowedTouchTypes = types.map { $0.rawValue as NSNumber }
        if kind != nil {
            drawingRecognizers.forEach { $0.isEnabled = false }
        } else if wasDrawingShapes {
            // Being given a tool makes PencilKit turn its drawing back on, as far as that tool uses it.
            let current = tool
            tool = current
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // PencilKit turns its drawing back on whenever the tool changes. Every touch is hit-tested
        // before any gesture sees it, so this keeps shapes from being drawn freehand.
        if shapeKind != nil { drawingRecognizers.forEach { $0.isEnabled = false } }
        return super.hitTest(point, with: event)
    }

    @objc private func handleShapeDrag(_ recognizer: UIPanGestureRecognizer) {
        guard let shapeKind else { return }
        let location = recognizer.location(in: self)
        let point = CGPoint(x: location.x / zoomScale, y: location.y / zoomScale)

        switch recognizer.state {
        case .began:
            let moved = recognizer.translation(in: self)
            shapeStart = CGPoint(x: point.x - moved.x / zoomScale, y: point.y - moved.y / zoomScale)
            // The eraser and lasso have no ink, so shapes use the last ink that was selected.
            if let inking = tool as? PKInkingTool { Self.inkMemory.tool = inking }
            shapePreview.lineWidth = ShapeKind.lineWidth(of: shapeTool)
            shapePreview.strokeColor = PKInkingTool.convertColor(shapeTool.color, from: .light, to: traitCollection.userInterfaceStyle).cgColor
            updateShapePreview(to: point)
        case .changed:
            updateShapePreview(to: point)
        case .ended:
            if let start = shapeStart, hypot(point.x - start.x, point.y - start.y) >= 2 {
                let strokes = shapeKind.strokes(from: start, to: point, tool: shapeTool)
                replaceDrawing(with: drawing.appending(PKDrawing(strokes: strokes)))
            }
            endShapePreview()
        default:
            endShapePreview()
        }
    }

    private func updateShapePreview(to point: CGPoint) {
        guard let shapeKind, let shapeStart else { return }
        let path = CGMutablePath()
        for polyline in shapeKind.polylines(from: shapeStart, to: point, lineWidth: ShapeKind.lineWidth(of: shapeTool)) {
            path.addLines(between: polyline)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapePreview.path = path
        CATransaction.commit()
    }

    private func endShapePreview() {
        shapeStart = nil
        shapePreview.path = nil
    }

    /// Setting `drawing` directly isn't undoable, so register it with the canvas's undo manager.
    private func replaceDrawing(with newDrawing: PKDrawing) {
        let oldDrawing = drawing
        drawing = newDrawing
        undoManager?.registerUndo(withTarget: self) { $0.replaceDrawing(with: oldDrawing) }
        delegate?.canvasViewDrawingDidChange?(self)
    }

    func configure(layout: PageLayout, paper: Paper, pdf: CGPDFDocument?) {
        guard layout != self.layout || paper != self.paper || pdf !== self.pdf else { return }
        let oldLayout = self.layout
        self.layout = layout
        self.paper = paper
        self.pdf = pdf

        // PDFs are made for light pages, so keep the ink and page light on them.
        overrideUserInterfaceStyle = pdf == nil ? .unspecified : .light

        pageViews.forEach { $0.removeFromSuperview() }
        templateLayers = []
        pageViews = layout.frames.enumerated().map { i, frame in
            let page = UIView(frame: frame)
            page.layer.borderWidth = 0.75
            page.layer.shadowOpacity = 0.18
            page.layer.shadowRadius = 8
            page.layer.shadowOffset = CGSize(width: 0, height: 2)
            if let pdfPage = pdf?.page(at: i + 1) {
                let pdfView = PDFPageView(page: pdfPage, frame: page.bounds)
                pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                page.addSubview(pdfView)
            } else {
                let templateLayer = CAShapeLayer()
                page.layer.addSublayer(templateLayer)
                templateLayers.append(templateLayer)
            }
            pagesView.addSubview(page)
            return page
        }
        applyPageColors()

        // Keep the zoom unless the page width changed; jump to a page that was just added.
        if oldLayout?.contentWidth != layout.contentWidth { fittedWidth = 0 }
        if let oldLayout, !layout.isInfinite, layout.frames.count == oldLayout.frames.count + 1 {
            scrollsToLastPage = true
        }
        // Deleting a page can leave the view scrolled past the new end.
        if let oldLayout, layout.frames.count < oldLayout.frames.count { scrollsBackToContent = true }
        setNeedsLayout()
    }

    fileprivate var pageInView: Int? {
        guard let layout, !layout.frames.isEmpty, bounds.height > 0 else { return nil }
        let visibleMidY = bounds.minY + (adjustedContentInset.top + bounds.height - adjustedContentInset.bottom) / 2
        return layout.pageIndex(nearestY: visibleMidY / zoomScale)
    }

    private func applyPageColors() {
        let traits = traitCollection
        for page in pageViews {
            page.backgroundColor = paper?.dynamicColor
            page.layer.borderColor = UIColor.separator.resolvedColor(with: traits).cgColor
            page.layer.shadowColor = UIColor.black.cgColor
        }
        for layer in templateLayers {
            layer.fillColor = PageTemplate.color(dark: traits.userInterfaceStyle == .dark).cgColor
        }
    }

    /// Infinite pages grow as they're drawn on, so their pattern is rebuilt when the size changes.
    private func updateTemplates(isContinuous: Bool) {
        guard let template = paper?.template else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (page, layer) in zip(pageViews, templateLayers) where layer.path == nil || layer.bounds.size != page.bounds.size {
            layer.frame = page.bounds
            layer.path = template.path(in: page.bounds.size, continuous: isContinuous)
        }
        CATransaction.commit()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout, bounds.width > 0 else { return }

        // Fit the pages to the view's width, keeping the user's zoom unless they were at "fit".
        let isFirstFit = fittedWidth == 0
        if bounds.width != fittedWidth {
            let fit = bounds.width / layout.contentWidth
            let wasFitted = fittedWidth == 0 || abs(zoomScale - minimumZoomScale) < 0.001
            let visibleTop = (contentOffset.y + adjustedContentInset.top) / zoomScale
            fittedWidth = bounds.width
            maximumZoomScale = fit * 5
            minimumZoomScale = fit
            if wasFitted {
                zoomScale = fit
                // Re-fitting (the sidebar hiding, a rotation) keeps the same part of the page in view.
                if !isFirstFit { refitOffsetY = visibleTop * fit - adjustedContentInset.top }
            }
        }

        let height = layoutPages(layout)
        let size = CGSize(width: layout.contentWidth * zoomScale, height: height * zoomScale)
        if contentSize != size { contentSize = size }
        // Zooming to fit shifts the scroll position; start at the top so the first margin shows.
        if isFirstFit { contentOffset = CGPoint(x: -adjustedContentInset.left, y: -adjustedContentInset.top) }
        if let refitOffsetY {
            contentOffset = CGPoint(x: -adjustedContentInset.left, y: refitOffsetY)
            self.refitOffsetY = nil
        }
        if subviews.first !== pagesView { sendSubviewToBack(pagesView) }

        let contentBottom = max(contentSize.height, contentOffset.y + bounds.height - max(overscroll, 0) - adjustedContentInset.bottom)
        pullLabel.frame = CGRect(x: contentOffset.x, y: contentBottom + 16, width: bounds.width, height: 24)

        if scrollsToLastPage, let last = layout.frames.last {
            scrollsToLastPage = false
            let y = min((last.minY - PageLayout.margin) * zoomScale, max(contentSize.height - bounds.height + adjustedContentInset.bottom, 0))
            setContentOffset(CGPoint(x: contentOffset.x, y: y - adjustedContentInset.top), animated: true)
        }
        if scrollsBackToContent {
            scrollsBackToContent = false
            if overscroll > 0 { setContentOffset(CGPoint(x: contentOffset.x, y: contentOffset.y - overscroll), animated: true) }
        }

        // Runs on every scroll and stroke, so a lost picker can't stay lost while the canvas is in use.
        scheduleToolPickerReclaim()
    }

    /// Sizes the pages and scales them with the ink, returning the content's height in page points.
    @discardableResult
    private func layoutPages(_ layout: PageLayout) -> CGFloat {
        var height = layout.contentHeight
        if layout.isInfinite, let first = layout.frames.first {
            // The page keeps half a screen of blank space below the lowest stroke.
            let visibleHeight = bounds.height / zoomScale
            let bottom = drawing.bounds.isNull ? first.minY : drawing.bounds.maxY
            let pageBottom = max(bottom + visibleHeight / 2, first.minY + visibleHeight - PageLayout.margin * 2)
            pageViews.first?.frame.size.height = pageBottom - first.minY
            height = pageBottom + PageLayout.margin
        }

        pagesView.bounds = CGRect(x: 0, y: 0, width: layout.contentWidth, height: height)
        pagesView.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        pagesView.layer.position = .zero
        for page in pageViews {
            page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
        }
        updateTemplates(isContinuous: layout.isInfinite)
        return height
    }

    /// Keeps the pages in step with the ink as the zoom changes. The next layout pass would be too
    /// late: a pinch that ends past the zoom limits springs back in an animation, and only changes
    /// made as it starts move along with the ink. Later ones jump straight to where it will end.
    func zoomDidChange() {
        guard let layout, bounds.width > 0 else { return }
        layoutPages(layout)
        setNeedsLayout()
    }

    // MARK: Pull to add a page

    /// How far the user has pulled past the end of the content, in screen points.
    private var overscroll: CGFloat {
        let maxOffset = max(contentSize.height + adjustedContentInset.bottom - bounds.height, -adjustedContentInset.top)
        return contentOffset.y - maxOffset
    }

    func updatePullToAdd() {
        guard onAddPage != nil else {
            pullLabel.alpha = 0
            return
        }
        let pull = overscroll
        pullLabel.alpha = max(0, min(1, pull / Self.pullThreshold))
        guard isDragging else { return }
        let armed = pull >= Self.pullThreshold
        if armed != isPullArmed, armed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        isPullArmed = armed
        pullLabel.text = armed ? "Release to Add a Page" : "Pull to Add a Page"
    }

    func finishPullToAdd() {
        guard isPullArmed else { return }
        isPullArmed = false
        pullLabel.text = "Pull to Add a Page"
        onAddPage?()
    }
}

/// Remembers the ink last selected in the tool picker. Shapes are drawn with it while the eraser
/// or lasso is selected, as those have no ink of their own.
private final class InkMemory: NSObject, PKToolPickerObserver {
    var tool = PKInkingTool(.pen, color: .black, width: PKInkingTool.InkType.pen.defaultWidth)

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        if let item = toolPicker.selectedToolItem as? PKToolPickerInkingItem { tool = item.inkingTool }
    }
}

/// Reports touches lifting from the canvas without taking part in any other gesture.
private final class TouchLiftObserver: UIGestureRecognizer {
    private let onLift: () -> Void

    init(onLift: @escaping () -> Void) {
        self.onLift = onLift
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onLift()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }
}

private extension UIResponder {
    private static weak var captured: UIResponder?

    /// Sending an action to a nil target delivers it to the first responder.
    static var currentFirstResponder: UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(#selector(captureAsFirstResponder), to: nil, from: nil, for: nil)
        return captured
    }

    @objc private func captureAsFirstResponder() {
        UIResponder.captured = self
    }
}

/// Renders one PDF page with tiles, so it stays sharp at any zoom.
private final class PDFPageView: UIView {
    override class var layerClass: AnyClass { PDFTiledLayer.self }

    init(page: CGPDFPage, frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let tiled = layer as! PDFTiledLayer
        tiled.page = page
        tiled.levelsOfDetail = 1
        tiled.levelsOfDetailBias = 5
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.setNeedsDisplay()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Draws on background threads, so it stays off the main actor.
private nonisolated final class PDFTiledLayer: CATiledLayer {
    var page: CGPDFPage?

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        page = (layer as? PDFTiledLayer)?.page
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override func draw(in ctx: CGContext) {
        guard let page else { return }
        let size = page.displaySize
        ctx.scaleBy(x: bounds.width / size.width, y: bounds.height / size.height)
        page.drawDisplayed(in: ctx)
    }
}
