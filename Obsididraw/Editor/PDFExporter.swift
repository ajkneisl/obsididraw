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
        let points = Array(stroke.path.interpolatedPoints(by: .distance(1)))
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

        ctx.addPath(outline(points))
        ctx.fillPath()
    }

    /// Offsets the centerline by half the ink width on each side, with round caps.
    private static func outline(_ points: [PKStrokePoint]) -> CGPath {
        let path = CGMutablePath()
        let radii = points.map { ($0.size.width + $0.size.height) / 4 }

        guard points.count > 1 else {
            let r = radii[0], c = points[0].location
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            return path
        }

        var normals: [CGVector] = []
        var normal = CGVector(dx: 0, dy: 1)
        for i in points.indices {
            let prev = points[max(i - 1, 0)].location
            let next = points[min(i + 1, points.count - 1)].location
            let dx = next.x - prev.x, dy = next.y - prev.y
            let length = hypot(dx, dy)
            if length > 1e-6 { normal = CGVector(dx: -dy / length, dy: dx / length) }
            normals.append(normal)
        }

        func offset(_ i: Int, _ side: CGFloat) -> CGPoint {
            let p = points[i].location
            return CGPoint(x: p.x + normals[i].dx * radii[i] * side, y: p.y + normals[i].dy * radii[i] * side)
        }

        let last = points.count - 1
        path.move(to: offset(0, 1))
        for i in 1...last { path.addLine(to: offset(i, 1)) }
        let endAngle = atan2(normals[last].dy, normals[last].dx)
        path.addArc(center: points[last].location, radius: radii[last], startAngle: endAngle, endAngle: endAngle - .pi, clockwise: true)
        for i in stride(from: last, through: 0, by: -1) { path.addLine(to: offset(i, -1)) }
        let startAngle = atan2(normals[0].dy, normals[0].dx) + .pi
        path.addArc(center: points[0].location, radius: radii[0], startAngle: startAngle, endAngle: startAngle - .pi, clockwise: true)
        path.closeSubpath()
        return path
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
