import CoreGraphics
import Foundation
import UIKit

/// Page setup for a drawing: its size and the page color in light and dark appearance.
nonisolated struct Paper: Codable, Equatable {
    enum Size: String, Codable, CaseIterable, Identifiable {
        case infinite, a4, a5, letter, legal, custom
        /// Pages come from a background PDF; their sizes can't be changed.
        case pdf

        var id: String { rawValue }

        var title: String {
            switch self {
            case .infinite: "Infinite"
            case .a4: "A4"
            case .a5: "A5"
            case .letter: "US Letter"
            case .legal: "US Legal"
            case .custom: "Custom"
            case .pdf: "PDF"
            }
        }

        /// Portrait dimensions in points (1/72 inch).
        var portraitSize: CGSize? {
            switch self {
            case .a4: CGSize(width: 595.28, height: 841.89)
            case .a5: CGSize(width: 419.53, height: 595.28)
            case .letter: CGSize(width: 612, height: 792)
            case .legal: CGSize(width: 612, height: 1008)
            case .infinite, .custom, .pdf: nil
            }
        }
    }

    struct Colors: Codable, Equatable {
        /// `#RRGGBBAA` page color in light appearance.
        var light: String
        /// `#RRGGBBAA` page color in dark appearance.
        var dark: String

        static let standard = Colors(light: "#ffffffff", dark: "#1c1c1eff")
    }

    var size: Size
    /// Page width in points. For infinite paper, the width of the scrolling page.
    var width: Double
    /// Page height in points. Unused for infinite paper.
    var height: Double
    var color: Colors
    /// The pattern behind the ink. Nil means blank; ignored on PDFs.
    var template: PageTemplate?

    static let infiniteWidth = 800.0

    static let standard = Paper(size: .infinite, width: infiniteWidth, height: 0, color: .standard)

    var isInfinite: Bool { size == .infinite }
    var isLandscape: Bool { width > height && !isInfinite }
    var pageSize: CGSize { CGSize(width: width, height: height) }

    /// Changes the size preset, keeping the current orientation.
    mutating func setSize(_ newSize: Size) {
        let landscape = isLandscape
        size = newSize
        switch newSize {
        case .infinite:
            width = Self.infiniteWidth
            height = 0
        case .custom, .pdf:
            if height <= 0 { height = width * 1.414 }
        default:
            let portrait = newSize.portraitSize!
            width = landscape ? portrait.height : portrait.width
            height = landscape ? portrait.width : portrait.height
        }
    }

    mutating func setLandscape(_ landscape: Bool) {
        guard !isInfinite, landscape != isLandscape else { return }
        swap(&width, &height)
    }

    /// A color that follows the current light/dark appearance.
    var dynamicColor: UIColor {
        let light = UIColor(hexRGBA: color.light) ?? .white
        let dark = UIColor(hexRGBA: color.dark) ?? .black
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
}

// MARK: - Defaults for new drawings

extension Paper {
    private static let defaultsKey = "defaultPaper"

    static var defaultForNewDrawings: Paper {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let paper = try? JSONDecoder().decode(Paper.self, from: data)
            else { return .standard }
            return paper
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}
