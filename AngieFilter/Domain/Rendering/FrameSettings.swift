import CoreGraphics
import Foundation

enum FrameStyle: Equatable, Sendable {
    case off
    case white
    case black
    case paper
    case window
    case stamp
    case scrim
    case instant
    case captioned

    /// Left/right, top, and bottom, as fractions of the short side. Zero means the photo is not enlarged.
    var border: (side: CGFloat, top: CGFloat, bottom: CGFloat) {
        switch self {
        case .off, .window, .stamp, .scrim:
            return (0, 0, 0)
        case .white, .black, .paper:
            return (0.055, 0.055, 0.055)
        case .captioned:
            return (0.045, 0.045, 0.11)
        case .instant:
            return (0.055, 0.055, 0.20)
        }
    }

    /// Height of an on-photo caption band, as a fraction of the short side.
    var overlayBand: CGFloat {
        switch self {
        case .stamp: return 0.12
        case .scrim: return 0.18
        default: return 0
        }
    }

    var expandsCanvas: Bool {
        let edge = border
        return edge.side > 0 || edge.top > 0 || edge.bottom > 0
    }

    var allowsCaption: Bool {
        self == .captioned || self == .instant || self == .stamp || self == .scrim
    }

    var lightCaption: Bool { self == .stamp || self == .scrim }

    var isBlack: Bool { self == .black }

    var isPaper: Bool { self == .paper }
}

/// In-memory frame choice. Shoulder-style switches stay when the style changes.
struct FrameSettings: Equatable, Sendable {
    var style: FrameStyle = .off
    var showsModel = true
    var showsPlace = false
    var showsDate = true
    var customText = ""

    var drawsBorder: Bool { style != .off }

    var allowsCaption: Bool { style.allowsCaption }

    /// Whitespace-only text is not printed.
    var printedCustomText: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let customTextLimit = 12

    /// Keeps the first 12 extended grapheme clusters.
    static func limited(_ text: String) -> String {
        String(text.prefix(customTextLimit))
    }
}

enum FrameDateText {
    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d.%02d.%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Outer canvas for a photo that has already been cropped. Core Image origin is bottom-left.
struct FrameLayout: Equatable, Sendable {
    var canvas: CGSize
    var photoOrigin: CGPoint
    var captionBarHeight: CGFloat
    var fontSize: CGFloat
    var horizontalInset: CGFloat

    struct Fractions: Equatable, Sendable {
        var left: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    static func make(photoSize: CGSize, style: FrameStyle) -> FrameLayout? {
        let width = photoSize.width
        let height = photoSize.height
        guard width > 1, height > 1, style != .off else { return nil }
        let short = min(width, height)
        let border = style.border
        let side = (border.side * short).rounded()
        let top = (border.top * short).rounded()
        let bottom = (border.bottom * short).rounded()
        let band = (style.overlayBand * short).rounded()
        let inset = side > 0 ? side : (0.045 * short).rounded()
        let fontScale: CGFloat = style.lightCaption ? 0.026 : 0.031
        return FrameLayout(
            canvas: CGSize(width: width + side * 2, height: height + top + bottom),
            photoOrigin: CGPoint(x: side, y: bottom),
            captionBarHeight: bottom > 0 ? bottom : band,
            fontSize: max(8, (fontScale * short).rounded()),
            horizontalInset: inset
        )
    }

    static func outerWidthOverHeight(photoWidthOverHeight: CGFloat, style: FrameStyle) -> CGFloat {
        let border = style.border
        let photoWidth = photoWidthOverHeight
        let short = min(photoWidth, 1)
        let outerWidth = photoWidth + (border.side * 2) * short
        let outerHeight = 1 + (border.top + border.bottom) * short
        guard outerHeight > 0 else { return photoWidth }
        return outerWidth / outerHeight
    }

    static func fractions(photoWidthOverHeight: CGFloat, style: FrameStyle) -> Fractions {
        let border = style.border
        let photoWidth = photoWidthOverHeight
        let short = min(photoWidth, 1)
        let outerWidth = photoWidth + (border.side * 2) * short
        let outerHeight = 1 + (border.top + border.bottom) * short
        guard outerWidth > 0, outerHeight > 0 else {
            return Fractions(left: 0, top: 0, bottom: 0)
        }
        return Fractions(
            left: (border.side * short) / outerWidth,
            top: (border.top * short) / outerHeight,
            bottom: (border.bottom * short) / outerHeight
        )
    }
}
