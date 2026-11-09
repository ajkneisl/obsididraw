import CoreGraphics
import PencilKit

/// A shape drawn by dragging on the canvas. Shapes are saved as ordinary PencilKit strokes, so they
/// erase, lasso, export and render in Obsidian like anything drawn by hand.
enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse, triangle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .triangle: "Triangle"
        }
    }

    var systemImage: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        }
    }

    /// The polylines tracing this shape when dragged from `start` to `end`, one per stroke.
    /// Closed outlines begin partway along an edge, so a stroke's ends never fall on a corner.
    func polylines(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat) -> [[CGPoint]] {
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch self {
        case .line:
            return [[start, end]]
        case .arrow:
            let length = hypot(end.x - start.x, end.y - start.y)
            let headLength = min(length / 2, max(14, lineWidth * 4))
            let angle = atan2(end.y - start.y, end.x - start.x)
            func barb(_ side: CGFloat) -> CGPoint {
                let a = angle + .pi + side * .pi / 7
                return CGPoint(x: end.x + cos(a) * headLength, y: end.y + sin(a) * headLength)
            }
            return [[start, end], [barb(-1), end, barb(1)]]
        case .rectangle:
            let top = CGPoint(x: box.midX, y: box.minY)
            return [[
                top,
                CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.minY),
                top,
            ]]
        case .ellipse:
            let perimeter = .pi * (box.width + box.height)
            let count = max(32, Int(perimeter / Self.pointSpacing))
            return [(0...count).map { i in
                let a = CGFloat(i) / CGFloat(count) * 2 * .pi
                return CGPoint(x: box.midX + cos(a) * box.width / 2, y: box.midY + sin(a) * box.height / 2)
            }]
        case .triangle:
            let base = CGPoint(x: box.midX, y: box.maxY)
            return [[base, CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.midX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), base]]
        }
    }

    func strokes(from start: CGPoint, to end: CGPoint, tool: PKInkingTool) -> [PKStroke] {
        let size = InkWidth.size(forWidth: tool.width, ink: tool.inkType)
        return polylines(from: start, to: end, lineWidth: tool.width).map { polyline in
            let points = Self.resampled(polyline).enumerated().map { i, location in
                PKStrokePoint(
                    location: location,
                    timeOffset: TimeInterval(i) * 0.008,
                    size: CGSize(width: size, height: size),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2,
                    secondaryScale: 1
                )
            }
            return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity, mask: nil)
        }
    }

    /// Spacing of a shape's control points. Strokes are B-splines, so this keeps corners tight:
    /// they round off by a fraction of it.
    private static let pointSpacing: CGFloat = 4

    private static func resampled(_ polyline: [CGPoint]) -> [CGPoint] {
        guard var previous = polyline.first else { return [] }
        var points = [previous]
        for next in polyline.dropFirst() {
            let length = hypot(next.x - previous.x, next.y - previous.y)
            let steps = max(Int((length / pointSpacing).rounded(.up)), polyline.count == 2 ? 4 : 1)
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(CGPoint(x: previous.x + (next.x - previous.x) * t, y: previous.y + (next.y - previous.y) * t))
            }
            previous = next
        }
        return points
    }
}
