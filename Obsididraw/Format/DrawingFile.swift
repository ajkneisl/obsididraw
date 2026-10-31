import Foundation
import PencilKit
import UIKit

/// The on-disk `.draw` document: plain JSON describing every PencilKit stroke, page by page, so
/// the file round-trips losslessly through the app and can be rendered by anything else
/// (notably the Obsidian plugin). The format is specified in `docs/FORMAT.md`.
nonisolated struct DrawingFile: Codable, Equatable {
    static let fileExtension = "draw"
    static let formatType = "obsididraw"
    static let currentVersion = 1

    var type: String = DrawingFile.formatType
    var version: Int = DrawingFile.currentVersion
    var source: String? = "Obsididraw"
    var paper: Paper
    /// Vault-relative path of the PDF drawn on, if any. Page `i` sits on top of PDF page `i`.
    var pdf: String?
    var pages: [Page]

    struct Page: Codable, Equatable {
        /// Page size in points. For infinite paper, `height` is the bottom of the lowest stroke.
        var width: Double
        var height: Double
        /// Strokes in page coordinates: origin top-left, y down.
        var strokes: [Stroke]
    }

    struct Stroke: Codable, Equatable {
        /// `pen`, `pencil`, `marker`, `monoline`, `fountainPen`, `watercolor`, `crayon`, or a
        /// raw PencilKit ink identifier for inks this version doesn't name.
        var ink: String
        /// `#RRGGBBAA`, sRGB, light-appearance color.
        var color: String
        /// Affine transform `[a, b, c, d, tx, ty]`; omitted when identity.
        var transform: [Double]?
        /// SVG path data clipping the stroke (left behind by the pixel eraser).
        var mask: String?
        /// PencilKit's texture seed, so textured inks re-render identically.
        var seed: UInt32?
        /// Creation time, seconds since 1970.
        var created: Double?
        /// B-spline control points, each `[x, y, t, w, h, opacity, force, azimuth, altitude, secondaryScale]`.
        var points: [[Double]]
    }

    static func blank(paper: Paper) -> DrawingFile {
        let page = paper.isInfinite
            ? Page(width: paper.width, height: 0, strokes: [])
            : Page(width: paper.width, height: paper.height, strokes: [])
        return DrawingFile(paper: paper, pages: [page])
    }
}

// MARK: - Serialization

extension DrawingFile {
    static func decode(_ data: Data) throws -> DrawingFile {
        struct Header: Decodable { var type: String?; var version: Int? }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.type == formatType else { throw FormatError.notADrawing }
        if let version = header.version, version > currentVersion { throw FormatError.unsupportedVersion(version) }
        return try JSONDecoder().decode(DrawingFile.self, from: data)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    enum FormatError: LocalizedError {
        case notADrawing
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notADrawing: "This file isn't an Obsididraw drawing."
            case .unsupportedVersion(let v): "This drawing uses format version \(v), which needs a newer Obsididraw."
            }
        }
    }
}

// MARK: - PencilKit conversion

extension DrawingFile.Stroke {
    init(_ stroke: PKStroke) {
        var t = stroke.transform
        var mask = stroke.mask?.cgPath
        var dx = 0.0, dy = 0.0
        // Pure translations (page offsets, lasso moves) are baked into the points.
        if t.a == 1, t.b == 0, t.c == 0, t.d == 1 {
            dx = t.tx
            dy = t.ty
            if let m = mask {
                var shift = CGAffineTransform(translationX: dx, y: dy)
                mask = m.copy(using: &shift)
            }
            t = .identity
        }

        ink = InkName.name(for: stroke.ink.inkType)
        color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).hexRGBA
        transform = t.isIdentity ? nil : [t.a, t.b, t.c, t.d, t.tx, t.ty].map { round($0, 4) }
        self.mask = mask.map(SVGPath.string(from:))
        seed = stroke.randomSeed
        created = round(stroke.path.creationDate.timeIntervalSince1970, 3)
        points = stroke.path.map { p in
            [
                round(p.location.x + dx, 2), round(p.location.y + dy, 2), round(p.timeOffset, 3),
                round(p.size.width, 2), round(p.size.height, 2), round(p.opacity, 3),
                round(p.force, 3), round(p.azimuth, 3), round(p.altitude, 3), round(p.secondaryScale, 3),
            ]
        }
    }

    func pkStroke() -> PKStroke? {
        let controlPoints = points.compactMap { v -> PKStrokePoint? in
            guard v.count >= 2 else { return nil }
            func at(_ i: Int, _ fallback: Double) -> CGFloat { CGFloat(i < v.count ? v[i] : fallback) }
            return PKStrokePoint(
                location: CGPoint(x: v[0], y: v[1]),
                timeOffset: TimeInterval(at(2, 0)),
                size: CGSize(width: at(3, 2), height: at(4, at(3, 2))),
                opacity: at(5, 1),
                force: at(6, 1),
                azimuth: at(7, 0),
                altitude: at(8, .pi / 2),
                secondaryScale: at(9, 1)
            )
        }
        guard !controlPoints.isEmpty else { return nil }

        let path = PKStrokePath(
            controlPoints: controlPoints,
            creationDate: created.map(Date.init(timeIntervalSince1970:)) ?? Date()
        )
        let affine = transform.flatMap { m in
            m.count == 6 ? CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]) : nil
        } ?? .identity

        return PKStroke(
            ink: PKInk(InkName.type(for: ink), color: UIColor(hexRGBA: color) ?? .black),
            path: path,
            transform: affine,
            mask: mask.flatMap(SVGPath.bezierPath(from:)),
            randomSeed: seed ?? 0
        )
    }
}

extension PKStroke {
    func translated(by dx: CGFloat, _ dy: CGFloat) -> PKStroke {
        var stroke = self
        stroke.transform = transform.concatenating(CGAffineTransform(translationX: dx, y: dy))
        return stroke
    }
}

private nonisolated func round(_ value: CGFloat, _ places: Int) -> Double {
    let scale = pow(10, Double(places))
    return (Double(value) * scale).rounded() / scale
}

/// Stable, human-readable names for PencilKit ink types.
nonisolated enum InkName {
    private static let known: [(PKInk.InkType, String)] = [
        (.pen, "pen"), (.pencil, "pencil"), (.marker, "marker"), (.monoline, "monoline"),
        (.fountainPen, "fountainPen"), (.watercolor, "watercolor"), (.crayon, "crayon"),
    ]

    static func name(for type: PKInk.InkType) -> String {
        known.first { $0.0 == type }?.1 ?? type.rawValue
    }

    static func type(for name: String) -> PKInk.InkType {
        known.first { $0.1 == name }?.0 ?? PKInk.InkType(rawValue: name) ?? .pen
    }
}

// MARK: - Colors

nonisolated extension UIColor {
    var hexRGBA: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        let bytes = [r, g, b, a].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return "#" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    convenience init?(hexRGBA hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 6 { digits += "ff" }
        guard digits.count == 8, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 24) & 0xff) / 255,
            green: CGFloat((value >> 16) & 0xff) / 255,
            blue: CGFloat((value >> 8) & 0xff) / 255,
            alpha: CGFloat(value & 0xff) / 255
        )
    }
}
