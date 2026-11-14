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

    /// How wide PencilKit paints a shape drawn with `tool`: as wide as a steady stroke of its own.
    static func lineWidth(of tool: PKInkingTool) -> CGFloat {
        InkWidth.painted(size: InkWidth.size(forWidth: tool.width, ink: tool.inkType), ink: tool.inkType)
    }

    func strokes(from start: CGPoint, to end: CGPoint, tool: PKInkingTool) -> [PKStroke] {
        let size = InkWidth.size(forWidth: tool.width, ink: tool.inkType)
        return polylines(from: start, to: end, lineWidth: Self.lineWidth(of: tool)).map { polyline in
            let locations = Self.resampled(polyline)
            let azimuths = Self.azimuths(along: locations, ink: tool.inkType)
            let points = locations.indices.map { i in
                PKStrokePoint(
                    location: locations[i],
                    timeOffset: TimeInterval(i) * 0.008,
                    size: CGSize(width: size, height: size),
                    opacity: 1,
                    force: 1,
                    azimuth: azimuths[i],
                    altitude: .pi / 2,
                    secondaryScale: 1
                )
            }
            return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: .identity, mask: nil)
        }
    }

    /// The direction the tip leans at each point. As in strokes PencilKit makes from a finger, it
    /// stays square to the direction of travel, which keeps the marker's broad tip, and so the
    /// shape, equally thick on every side. The fountain pen's nib holds one angle instead. Angles
    /// carry on past a full turn rather than wrapping, so the tip takes the short way round corners.
    private static func azimuths(along points: [CGPoint], ink: PKInk.InkType) -> [CGFloat] {
        guard ink != .fountainPen else { return Array(repeating: 0, count: points.count) }
        var azimuths: [CGFloat] = []
        for i in points.indices {
            let before = points[max(i - 1, 0)], after = points[min(i + 1, points.count - 1)]
            var azimuth = atan2(after.y - before.y, after.x - before.x) + .pi / 2
            if let last = azimuths.last { azimuth = last + (azimuth - last).remainder(dividingBy: 2 * .pi) }
            azimuths.append(azimuth)
        }
        return azimuths
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
