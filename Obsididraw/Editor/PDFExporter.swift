import PencilKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a drawing to a PDF: one PDF page per page, ink as vector shapes, light page colors.
enum PDFExporter {
    static func data(for document: EditorDocument) -> Data {
        let pages = document.pageLocalStrokes()
        let pageColor = UIColor(hexRGBA: document.paper.color.light) ?? .white
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))

        return renderer.pdfData { context in
            for (i, strokes) in pages.enumerated() {
                var size = document.pageSizes[i]
                if document.paper.isInfinite {
                    size.height = max(EditorDocument.bottom(of: strokes) + PageLayout.margin, size.width / 4)
                }
                let rect = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: rect, pageInfo: [:])
                let ctx = context.cgContext

                ctx.setFillColor(pageColor.cgColor)
                ctx.fill(rect)
                document.pdf?.page(at: i + 1)?.drawDisplayed(in: ctx)
                if document.pdf == nil, let template = document.paper.template {
                    ctx.setFillColor(PageTemplate.color(dark: false).cgColor)
                    ctx.addPath(template.path(in: size, continuous: document.paper.isInfinite))
                    ctx.fillPath()
                }
                for stroke in strokes {
                    StrokeRenderer.draw(stroke, in: ctx)
                }
            }
        }
    }
}

/// Draws a PencilKit stroke as a filled, variable-width vector outline.
enum StrokeRenderer {
    static func draw(_ stroke: PKStroke, in ctx: CGContext) {
        // Fine enough that the curves of small handwriting stay smooth at any PDF zoom.
        let points = Array(stroke.path.interpolatedPoints(by: .distance(0.25)))
        guard !points.isEmpty else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.concatenate(stroke.transform)
        if let mask = stroke.mask {
            ctx.addPath(mask.cgPath)
            ctx.clip()
        }

        let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let opacity = points.map(\.opacity).reduce(0, +) / CGFloat(points.count)
        ctx.setFillColor(color.withAlphaComponent(alpha * opacity).cgColor)
        if stroke.ink.inkType == .marker { ctx.setBlendMode(.multiply) }

        let samples = points.map { point in
            let width = InkWidth.solid(size: (point.size.width + point.size.height) / 2, ink: stroke.ink.inkType)
            return Sample(center: point.location, radius: max(width / 2, minRadius))
        }
        ctx.addPath(inkPath(samples))
        ctx.fillPath()
    }

    private struct Sample {
        var center: CGPoint
        var radius: CGFloat
    }

    /// Radius floor, so ink written while zoomed in still shows up as a line.
    private static let minRadius: CGFloat = 0.2
    /// How far a simplified centerline may stray from the true curve, in points.
    private static let tolerance: CGFloat = 0.02
    private static let maxRadiusDrift: CGFloat = 0.04
    private static let maxRun: CGFloat = 32

    /// The stroke as a union of disks at each sample and a quad between each pair. All pieces wind
    /// the same way, so the default nonzero fill merges them. A single offset outline can't do
    /// this: on curves tighter than the pen is wide it folds over itself and leaves holes.
    private static func inkPath(_ samples: [Sample]) -> CGPath {
        let path = CGMutablePath()
        let kept = simplified(samples)

        func addDisk(_ s: Sample) {
            path.move(to: CGPoint(x: s.center.x + s.radius, y: s.center.y))
            path.addRelativeArc(center: s.center, radius: s.radius, startAngle: 0, delta: -2 * .pi)
            path.closeSubpath()
        }

        addDisk(kept[0])
        for (a, b) in zip(kept, kept.dropFirst()) {
            let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
            let length = hypot(dx, dy)
            if length > 1e-6 {
                let nx = -dy / length, ny = dx / length
                path.move(to: CGPoint(x: a.center.x + nx * a.radius, y: a.center.y + ny * a.radius))
                path.addLine(to: CGPoint(x: b.center.x + nx * b.radius, y: b.center.y + ny * b.radius))
                path.addLine(to: CGPoint(x: b.center.x - nx * b.radius, y: b.center.y - ny * b.radius))
                path.addLine(to: CGPoint(x: a.center.x - nx * a.radius, y: a.center.y - ny * a.radius))
                path.closeSubpath()
            }
            addDisk(b)
        }
        return path
    }

    /// Drops samples that a straight chord and constant width would reproduce within `tolerance`.
    private static func simplified(_ samples: [Sample]) -> [Sample] {
        guard samples.count > 2 else { return samples }
        var kept = [samples[0]]
        var run: CGFloat = 0, turn: CGFloat = 0
        for i in 1..<(samples.count - 1) {
            let a = samples[i - 1].center, s = samples[i].center, next = samples[i + 1].center
            let ux = s.x - a.x, uy = s.y - a.y, vx = next.x - s.x, vy = next.y - s.y
            run += hypot(ux, uy)
            turn += abs(atan2(ux * vy - uy * vx, ux * vx + uy * vy))
            // A run of length L turning by T strays from its chord by about L·T/8.
            if run * turn > tolerance * 8 || run > maxRun || abs(samples[i].radius - kept[kept.count - 1].radius) > maxRadiusDrift {
                kept.append(samples[i])
                run = 0
                turn = 0
            }
        }
        kept.append(samples[samples.count - 1])
        return kept
    }

}

struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
