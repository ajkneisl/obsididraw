import PencilKit
import SwiftUI

/// The PencilKit canvas with page backgrounds drawn behind the ink, fit to the window's width.
struct CanvasView: UIViewRepresentable {
    let document: EditorDocument
    /// Bumped whenever `document.drawing` is replaced from outside the canvas (page setup changes).
    let revision: Int
    var allowsFingerDrawing: Bool
    var onChange: (PKDrawing) -> Void
    /// Called when the user pulls past the last page; nil when pages can't be added.
    var onAddPage: (() -> Void)?

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
        context.coordinator.revision = revision

        let picker = context.coordinator.toolPicker
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PageCanvasView, context: Context) {
        context.coordinator.onChange = onChange
        canvas.onAddPage = onAddPage
        canvas.drawingPolicy = drawingPolicy
        canvas.configure(layout: document.layout, paper: document.paper, pdf: document.pdf)
        if context.coordinator.revision != revision {
            context.coordinator.revision = revision
            canvas.drawing = document.drawing
        }
    }

    static func dismantleUIView(_ canvas: PageCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }

    private var drawingPolicy: PKCanvasViewDrawingPolicy {
        #if targetEnvironment(macCatalyst)
        .anyInput
        #else
        allowsFingerDrawing ? .anyInput : .pencilOnly
        #endif
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
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

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            (scrollView as? PageCanvasView)?.finishPullToAdd()
        }
    }
}

final class PageCanvasView: PKCanvasView {
    var onAddPage: (() -> Void)?

    private let pagesView = UIView()
    private let pullLabel = UILabel()
    private var pageViews: [UIView] = []
    private var layout: PageLayout?
    private var paper: Paper?
    private var pdf: CGPDFDocument?
    private var fittedWidth: CGFloat = 0
    private var isPullArmed = false
    private var scrollsToLastPage = false

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
        // The tool picker only shows while the canvas is first responder.
        if window != nil { becomeFirstResponder() }
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
        setNeedsLayout()
    }

    private func applyPageColors() {
        let traits = traitCollection
        for page in pageViews {
            page.backgroundColor = paper?.dynamicColor
            page.layer.borderColor = UIColor.separator.resolvedColor(with: traits).cgColor
            page.layer.shadowColor = UIColor.black.cgColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout, bounds.width > 0 else { return }

        // Fit the pages to the view's width, keeping the user's zoom unless they were at "fit".
        let isFirstFit = fittedWidth == 0
        if bounds.width != fittedWidth {
            let fit = bounds.width / layout.contentWidth
            let wasFitted = fittedWidth == 0 || abs(zoomScale - minimumZoomScale) < 0.001
            fittedWidth = bounds.width
            maximumZoomScale = fit * 5
            minimumZoomScale = fit
            if wasFitted { zoomScale = fit }
        }

        let visibleHeight = bounds.height / zoomScale
        var height = layout.contentHeight
        if layout.isInfinite, let first = layout.frames.first {
            // The page keeps half a screen of blank space below the lowest stroke.
            let bottom = drawing.bounds.isNull ? first.minY : drawing.bounds.maxY
            let pageBottom = max(bottom + visibleHeight / 2, first.minY + visibleHeight - PageLayout.margin * 2)
            pageViews.first?.frame.size.height = pageBottom - first.minY
            height = pageBottom + PageLayout.margin
        }
        let size = CGSize(width: layout.contentWidth * zoomScale, height: height * zoomScale)
        if contentSize != size { contentSize = size }
        // Zooming to fit shifts the scroll position; start at the top so the first margin shows.
        if isFirstFit { contentOffset = CGPoint(x: -adjustedContentInset.left, y: -adjustedContentInset.top) }

        pagesView.bounds = CGRect(x: 0, y: 0, width: layout.contentWidth, height: height)
        pagesView.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        pagesView.layer.position = .zero
        for page in pageViews {
            page.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
        }
        if subviews.first !== pagesView { sendSubviewToBack(pagesView) }

        let contentBottom = max(contentSize.height, contentOffset.y + bounds.height - max(overscroll, 0) - adjustedContentInset.bottom)
        pullLabel.frame = CGRect(x: contentOffset.x, y: contentBottom + 16, width: bounds.width, height: 24)

        if scrollsToLastPage, let last = layout.frames.last {
            scrollsToLastPage = false
            let y = min((last.minY - PageLayout.margin) * zoomScale, max(contentSize.height - bounds.height + adjustedContentInset.bottom, 0))
            setContentOffset(CGPoint(x: contentOffset.x, y: y - adjustedContentInset.top), animated: true)
        }
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
