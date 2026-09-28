import CoreGraphics
import Foundation

enum FrameStyle: Equatable, Sendable {
    case off
    case white
    case captioned
}

/// In-memory frame choice. Shoulder-style switches stay when the style changes.
struct FrameSettings: Equatable, Sendable {
    var style: FrameStyle = .off
    var showsModel = true
    var showsPlace = false
    var showsDate = true
    var customText = ""

    var drawsBorder: Bool { style != .off }

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

    static func make(photoSize: CGSize) -> FrameLayout? {
        let width = photoSize.width
        let height = photoSize.height
        guard width > 1, height > 1 else { return nil }
        let short = min(width, height)
        let side = (0.045 * short).rounded()
        let bottom = (0.11 * short).rounded()
        return FrameLayout(
            canvas: CGSize(width: width + side * 2, height: height + side + bottom),
            photoOrigin: CGPoint(x: side, y: bottom),
            captionBarHeight: bottom,
            fontSize: max(8, (bottom * 0.28).rounded()),
            horizontalInset: side
        )
    }

    static func outerWidthOverHeight(photoWidthOverHeight: CGFloat) -> CGFloat {
        let photoWidth = photoWidthOverHeight
        let short = min(photoWidth, 1)
        let outerWidth = photoWidth + 0.09 * short
        let outerHeight = 1 + 0.155 * short
        return outerWidth / outerHeight
    }

    static func fractions(photoWidthOverHeight: CGFloat) -> Fractions {
        let photoWidth = photoWidthOverHeight
        let short = min(photoWidth, 1)
        let outerWidth = photoWidth + 0.09 * short
        let outerHeight = 1 + 0.155 * short
        return Fractions(
            left: (0.045 * short) / outerWidth,
            top: (0.045 * short) / outerHeight,
            bottom: (0.11 * short) / outerHeight
        )
    }
}
