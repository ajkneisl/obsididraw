import CoreGraphics
import UIKit

/// The pattern printed on a page, behind the ink. The geometry is specified in `docs/FORMAT.md`
/// and mirrored by the Obsidian plugin's `template.ts`.
nonisolated enum PageTemplate: String, Codable, CaseIterable, Identifiable {
    case blank, lined, linedCompact, squares, dots, cornell
    case twoPaneLined, twoPaneLinedCompact, threePaneLined, threePaneLinedCompact

    /// A template from a newer version of the format shows as blank rather than failing to open.
    init(from decoder: Decoder) throws {
        self = PageTemplate(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .blank
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "Blank"
        case .lined: "Lined"
        case .linedCompact: "Lined (Compact)"
        case .squares: "Squares"
        case .dots: "Dots"
        case .cornell: "Cornell Notes"
        case .twoPaneLined: "Two Pane Lined"
        case .twoPaneLinedCompact: "Two Pane Lined (Compact)"
        case .threePaneLined: "Three Pane Lined"
        case .threePaneLinedCompact: "Three Pane Lined (Compact)"
        }
    }

    /// The distance between rules. Compact templates fit a second rule between each pair.
    private var ruleSpacing: CGFloat {
        switch self {
        case .linedCompact, .twoPaneLinedCompact, .threePaneLinedCompact: Self.spacing / 2
        default: Self.spacing
        }
    }

    private static let spacing: CGFloat = 24
    private static let top: CGFloat = 48
    private static let margin: CGFloat = 24
    private static let gutter: CGFloat = 24
    private static let thickness: CGFloat = 0.6
    private static let dotRadius: CGFloat = 0.9

    static func color(dark: Bool) -> UIColor {
        UIColor(white: dark ? 1 : 0, alpha: 0.3)
    }

    /// The pattern as a single path to fill, in page coordinates. A `continuous` page has no bottom
    /// edge of its own (infinite paper), so its pattern runs right to the end of `size`.
    func path(in size: CGSize, continuous: Bool) -> CGPath {
        let path = CGMutablePath()
        let spacing = Self.spacing, top = Self.top, margin = Self.margin, gutter = Self.gutter
        let thickness = Self.thickness, width = size.width, height = size.height
        let lastRule = continuous ? height : height - spacing

        func rule(from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
            path.addRect(CGRect(x: x0, y: y - thickness / 2, width: x1 - x0, height: thickness))
        }
        func divider(x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
            path.addRect(CGRect(x: x - thickness / 2, y: y0, width: thickness, height: y1 - y0))
        }
        func rules(from x0: CGFloat, to x1: CGFloat, through bottom: CGFloat) {
            for y in stride(from: top, through: bottom, by: ruleSpacing) { rule(from: x0, to: x1, y: y) }
        }
        func panes(_ count: Int) {
            let columnWidth = (width - margin * 2 - gutter * CGFloat(count - 1)) / CGFloat(count)
            guard columnWidth > 0 else { return }
            for i in 0..<count {
                let x = margin + CGFloat(i) * (columnWidth + gutter)
                rules(from: x, to: x + columnWidth, through: lastRule)
                if i < count - 1 { divider(x: x + columnWidth + gutter / 2, from: margin, to: lastRule) }
            }
        }

        switch self {
        case .blank:
            break
        case .lined, .linedCompact:
            rules(from: 0, to: width, through: lastRule)
        case .squares:
            for x in stride(from: spacing, to: width, by: spacing) { divider(x: x, from: 0, to: height) }
            for y in stride(from: spacing, to: height, by: spacing) { rule(from: 0, to: width, y: y) }
        case .dots:
            let r = Self.dotRadius
            for y in stride(from: spacing, to: height, by: spacing) {
                for x in stride(from: spacing, to: width, by: spacing) {
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                }
            }
        case .cornell:
            let cue = (width * 0.3).rounded()
            let summary = continuous ? height : (height * 0.8).rounded()
            rule(from: 0, to: width, y: top)
            divider(x: cue, from: top, to: summary)
            for y in stride(from: top + spacing, to: summary, by: spacing) { rule(from: cue, to: width, y: y) }
            if !continuous { rule(from: 0, to: width, y: summary) }
        case .twoPaneLined, .twoPaneLinedCompact:
            panes(2)
        case .threePaneLined, .threePaneLinedCompact:
            panes(3)
        }
        return path
    }
}
