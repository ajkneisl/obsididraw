import CoreGraphics
import PencilKit

/// Where each page sits in the editor's single canvas coordinate space. Pages are inset from the
/// edges and stacked vertically with a gap; an infinite document is one page that grows downward.
struct PageLayout: Equatable {
    static let margin: CGFloat = 40
    static let gap: CGFloat = 40

    let isInfinite: Bool
    let frames: [CGRect]
    let contentWidth: CGFloat

    init(pageSizes: [CGSize], infinite: Bool) {
        isInfinite = infinite
        if infinite {
            let size = pageSizes.first ?? CGSize(width: Paper.infiniteWidth, height: 0)
            frames = [CGRect(origin: CGPoint(x: Self.margin, y: Self.margin), size: size)]
            contentWidth = size.width + Self.margin * 2
        } else {
            let maxWidth = pageSizes.map(\.width).max() ?? 0
            var y = Self.margin
            var frames: [CGRect] = []
            for size in pageSizes {
                frames.append(CGRect(x: Self.margin + (maxWidth - size.width) / 2, y: y, width: size.width, height: size.height))
                y += size.height + Self.gap
            }
            self.frames = frames
            contentWidth = maxWidth + Self.margin * 2
        }
    }

    /// Total height of a paged layout; infinite layouts grow with their content instead.
    var contentHeight: CGFloat {
        frames.last.map { $0.maxY + Self.margin } ?? 0
    }

    /// The page vertically closest to `y`.
    func pageIndex(nearestY y: CGFloat) -> Int {
        func distance(_ frame: CGRect) -> CGFloat {
            y < frame.minY ? frame.minY - y : max(0, y - frame.maxY)
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) } ?? 0
    }
}

/// A drawing being edited: page setup, optional background PDF, and all strokes in canvas coordinates.
struct EditorDocument {
    var paper: Paper
    var pdf: CGPDFDocument?
    var pageSizes: [CGSize]
    var drawing: PKDrawing

    var layout: PageLayout { PageLayout(pageSizes: pageSizes, infinite: paper.isInfinite) }
    var canAddPages: Bool { !paper.isInfinite && pdf == nil }
    /// A drawing always keeps one page.
    var canDeletePages: Bool { canAddPages && pageSizes.count > 1 }

    init(file: DrawingFile, pdf: CGPDFDocument?) {
        paper = file.paper
        self.pdf = pdf

        var sizes = file.pages.map { CGSize(width: $0.width, height: $0.height) }
        if let pdf {
            // The PDF decides how many pages there are and how big they are.
            sizes = (1...max(pdf.numberOfPages, 1)).compactMap { pdf.page(at: $0)?.displaySize }
        }
        if sizes.isEmpty {
            sizes = [paper.isInfinite ? CGSize(width: paper.width, height: 0) : paper.pageSize]
        }
        pageSizes = sizes
        drawing = PKDrawing()
        drawing = Self.drawing(from: file.pages.map { $0.strokes.compactMap { $0.pkStroke() } }, layout: layout)
    }

    func file(pdfPath: String?) -> DrawingFile {
        let pages = pageLocalStrokes()
        return DrawingFile(
            paper: paper,
            pdf: pdfPath,
            pages: pageSizes.indices.map { i in
                let height = paper.isInfinite ? Self.bottom(of: pages[i]) : pageSizes[i].height
                return DrawingFile.Page(
                    width: pageSizes[i].width,
                    height: height.rounded(.up),
                    strokes: pages[i].map { DrawingFile.Stroke($0) }
                )
            }
        )
    }

    /// Strokes grouped by the page they sit on, in page coordinates.
    func pageLocalStrokes() -> [[PKStroke]] {
        let layout = layout
        var pages = Array(repeating: [PKStroke](), count: layout.frames.count)
        for stroke in drawing.strokes {
            let i = layout.pageIndex(nearestY: stroke.renderBounds.midY)
            let origin = layout.frames[i].origin
            pages[i].append(stroke.translated(by: -origin.x, -origin.y))
        }
        return pages
    }

    mutating func addPage() {
        guard canAddPages else { return }
        let pages = pageLocalStrokes()
        pageSizes.append(paper.pageSize)
        drawing = Self.drawing(from: pages, layout: layout)
    }

    func pageHasInk(at index: Int) -> Bool {
        let pages = pageLocalStrokes()
        return pages.indices.contains(index) && !pages[index].isEmpty
    }

    /// Removes a page along with its ink. Later pages move up to close the gap.
    mutating func deletePage(at index: Int) {
        guard canDeletePages, pageSizes.indices.contains(index) else { return }
        var pages = pageLocalStrokes()
        pages.remove(at: index)
        pageSizes.remove(at: index)
        drawing = Self.drawing(from: pages, layout: layout)
    }

    /// Applies new page setup, moving strokes so they stay on sensible pages.
    mutating func setPaper(_ newPaper: Paper) {
        let pages = pageLocalStrokes()
        let wasInfinite = paper.isInfinite
        let oldSizes = pageSizes

        guard pdf == nil else {
            // PDF page sizes are fixed; only the colors can change.
            paper.color = newPaper.color
            return
        }
        paper = newPaper

        var newPages: [[PKStroke]]
        if newPaper.isInfinite {
            // Stack every page into one continuous strip.
            var offset: CGFloat = 0
            var strip: [PKStroke] = []
            for (i, strokes) in pages.enumerated() {
                strip += strokes.map { $0.translated(by: 0, offset) }
                offset += oldSizes[i].height
            }
            newPages = [strip]
            pageSizes = [CGSize(width: newPaper.width, height: 0)]
        } else if wasInfinite {
            // Cut the strip into pages of the new height.
            let height = newPaper.height
            let strokes = pages.first ?? []
            let count = max(1, Int((Self.bottom(of: strokes) / height).rounded(.up)))
            newPages = Array(repeating: [], count: count)
            for stroke in strokes {
                let i = min(max(Int(stroke.renderBounds.midY / height), 0), count - 1)
                newPages[i].append(stroke.translated(by: 0, -CGFloat(i) * height))
            }
            pageSizes = Array(repeating: newPaper.pageSize, count: count)
        } else {
            // Paged to paged: every stroke stays on its page.
            newPages = pages
            pageSizes = Array(repeating: newPaper.pageSize, count: pages.count)
        }
        drawing = Self.drawing(from: newPages, layout: layout)
    }

    private static func drawing(from pages: [[PKStroke]], layout: PageLayout) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (i, page) in pages.enumerated() {
            let origin = layout.frames[min(i, layout.frames.count - 1)].origin
            strokes += page.map { $0.translated(by: origin.x, origin.y) }
        }
        return PKDrawing(strokes: strokes)
    }

    static func bottom(of strokes: [PKStroke]) -> CGFloat {
        strokes.map(\.renderBounds.maxY).max() ?? 0
    }
}

// MARK: - PDF pages

nonisolated extension CGPDFPage {
    /// The crop box size as displayed, accounting for the page's rotation.
    var displaySize: CGSize {
        let box = getBoxRect(.cropBox)
        let rotation = (Int(rotationAngle) % 360 + 360) % 360
        return rotation == 90 || rotation == 270 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Draws the page into a y-down context, filling a `displaySize` rectangle at the origin.
    func drawDisplayed(in ctx: CGContext) {
        let size = displaySize
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.concatenate(getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: getBoxRect(.cropBox))
        ctx.drawPDFPage(self)
        ctx.restoreGState()
    }
}

nonisolated enum PDFLoader {
    static func load(_ url: URL) throws -> CGPDFDocument {
        let data = try CoordinatedFile.read(url)
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider) else {
            throw LoadError.unreadable
        }
        guard pdf.isUnlocked else { throw LoadError.locked }
        return pdf
    }

    enum LoadError: LocalizedError {
        case unreadable, locked

        var errorDescription: String? {
            switch self {
            case .unreadable: "This PDF couldn't be read."
            case .locked: "This PDF is password-protected."
            }
        }
    }
}
