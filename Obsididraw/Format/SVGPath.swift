import CoreGraphics
import UIKit

/// Converts between `CGPath` and the subset of SVG path data the format uses
/// (absolute `M`, `L`, `Q`, `C`, `Z`).
nonisolated enum SVGPath {
    static func string(from path: CGPath) -> String {
        var parts: [String] = []
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: parts.append("M" + coords(p[0]))
            case .addLineToPoint: parts.append("L" + coords(p[0]))
            case .addQuadCurveToPoint: parts.append("Q" + coords(p[0], p[1]))
            case .addCurveToPoint: parts.append("C" + coords(p[0], p[1], p[2]))
            case .closeSubpath: parts.append("Z")
            @unknown default: break
            }
        }
        return parts.joined(separator: " ")
    }

    static func bezierPath(from string: String) -> UIBezierPath? {
        let path = UIBezierPath()
        var command: Character?
        var numbers: [CGFloat] = []

        func flush() {
            func pt(_ i: Int) -> CGPoint { CGPoint(x: numbers[i * 2], y: numbers[i * 2 + 1]) }
            switch command {
            case "M" where numbers.count >= 2: path.move(to: pt(0))
            case "L" where numbers.count >= 2: path.addLine(to: pt(0))
            case "Q" where numbers.count >= 4: path.addQuadCurve(to: pt(1), controlPoint: pt(0))
            case "C" where numbers.count >= 6: path.addCurve(to: pt(2), controlPoint1: pt(0), controlPoint2: pt(1))
            case "Z": path.close()
            default: break
            }
            numbers.removeAll()
        }

        var token = ""
        func endNumber() {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        }

        for ch in string {
            if "MLQCZ".contains(ch) {
                endNumber()
                flush()
                command = ch
            } else if ch == " " || ch == "," {
                endNumber()
            } else {
                token.append(ch)
            }
        }
        endNumber()
        flush()
        return path.isEmpty ? nil : path
    }

    private static func coords(_ points: CGPoint...) -> String {
        points.map { "\(format($0.x)) \(format($0.y))" }.joined(separator: " ")
    }

    private static func format(_ value: CGFloat) -> String {
        var s = String(format: "%.2f", Double(value))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
}
