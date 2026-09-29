import CoreImage
import UIKit

struct FrameCaptionKey: Equatable, Sendable {
    var model: String
    var place: String
    var date: String
    var custom: String
    var barWidth: Int
    var barHeight: Int
    var inset: Int
    var fontSize: Int
    var lightText: Bool
    var scrim: Bool
    var layout: FrameCaptionLayout
}

enum FrameCaptionLayout: Equatable, Sendable {
    /// Model, place, custom, date across one line.
    case line
    /// The custom line centered in the bottom letterbox bar.
    case subtitle
    /// The custom line as a title, with model, place, and date as a credit line under it.
    case poster
}

/// Keeps the last two caption bitmaps so preview and still widths do not evict each other.
final class FrameCaptionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(FrameCaptionKey, CIImage)] = []

    func image(for key: FrameCaptionKey) -> CIImage? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first { $0.0 == key }?.1
    }

    func remember(_ image: CIImage, for key: FrameCaptionKey) {
        lock.lock()
        entries.removeAll { $0.0 == key }
        entries.insert((key, image), at: 0)
        if entries.count > 2 {
            entries.removeLast(entries.count - 2)
        }
        lock.unlock()
    }
}

/// Draws the bottom caption on the main thread. `videoQueue` only pastes the result.
enum FrameCaptionRenderer {
    static func key(layout: FrameLayout, parameters: RenderParameters) -> FrameCaptionKey? {
        guard parameters.frame.allowsCaption else { return nil }
        let settings = parameters.frame
        let info = settings.style.printsInfo
        let model = info && settings.showsModel ? parameters.frameModelName : ""
        let place = info && settings.showsPlace ? parameters.framePlace : ""
        let date = info && settings.showsDate ? parameters.frameDate : ""
        let custom = settings.printedCustomText
        guard !model.isEmpty || !place.isEmpty || !date.isEmpty || !custom.isEmpty else { return nil }
        return FrameCaptionKey(
            model: model,
            place: place,
            date: date,
            custom: custom,
            barWidth: Int(layout.canvas.width.rounded()),
            barHeight: Int(layout.captionBarHeight.rounded()),
            inset: Int(layout.horizontalInset.rounded()),
            fontSize: Int(layout.fontSize.rounded()),
            lightText: settings.style.lightCaption,
            scrim: settings.style == .scrim,
            layout: settings.style == .subtitle ? .subtitle : settings.style == .poster ? .poster : .line
        )
    }

    static func image(for key: FrameCaptionKey) -> CIImage? {
        guard key.barWidth > 1, key.barHeight > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: key.barWidth, height: key.barHeight),
            format: format
        )
        let uiImage = renderer.image { context in
            draw(key, in: context.cgContext)
        }
        guard let cgImage = uiImage.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func draw(_ key: FrameCaptionKey, in context: CGContext) {
        switch key.layout {
        case .subtitle: drawSubtitle(key)
        case .poster: drawPoster(key)
        case .line: drawLine(key, in: context)
        }
    }

    private static func drawSubtitle(_ key: FrameCaptionKey) {
        let font = UIFont.systemFont(ofSize: CGFloat(key.fontSize), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white.withAlphaComponent(0.94),
            .kern: CGFloat(key.fontSize) * 0.06
        ]
        let widthOf: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: attributes).width }
        let inset = CGFloat(key.inset)
        let barWidth = CGFloat(key.barWidth)
        let text = truncated(key.custom, maxWidth: barWidth - inset * 2, widthOf: widthOf)
        guard !text.isEmpty else { return }
        // Sits in the upper part of the bar, just under the picture, as a subtitle track does.
        let y = CGFloat(key.barHeight) * 0.3 - font.lineHeight / 2
        (text as NSString).draw(at: CGPoint(x: (barWidth - widthOf(text)) / 2, y: max(0, y)), withAttributes: attributes)
    }

    /// Title across the upper half of the sheet under the photo, credits under it in small spaced capitals.
    private static func drawPoster(_ key: FrameCaptionKey) {
        let barWidth = CGFloat(key.barWidth)
        let barHeight = CGFloat(key.barHeight)
        let room = barWidth - CGFloat(key.inset) * 2
        let creditSize = max(6, CGFloat(key.fontSize) * 0.28)
        let titleAttributes: (CGFloat) -> [NSAttributedString.Key: Any] = { size in
            [
                .font: UIFont.systemFont(ofSize: size, weight: .heavy),
                .foregroundColor: UIColor.white.withAlphaComponent(0.95),
                .kern: size * 0.12
            ]
        }
        // A long title shrinks to the width, down to half size, before it is cut.
        let fullWidth = (key.custom.uppercased() as NSString).size(withAttributes: titleAttributes(CGFloat(key.fontSize))).width
        let titleSize = CGFloat(key.fontSize) * min(1, max(0.5, room / max(fullWidth, 1)))
        let title = titleAttributes(titleSize)
        let credit: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: creditSize, weight: .medium),
            .foregroundColor: UIColor.white.withAlphaComponent(0.62),
            .kern: creditSize * 0.28
        ]
        let titleWidth: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: title).width }
        let creditWidth: (String) -> CGFloat = { ($0 as NSString).size(withAttributes: credit).width }
        let heading = truncated(key.custom.uppercased(), maxWidth: room, widthOf: titleWidth)
        let credits = truncated(
            [key.model, key.place, key.date].filter { !$0.isEmpty }.joined(separator: "   ").uppercased(),
            maxWidth: room,
            widthOf: creditWidth
        )
        let titleLine = (title[.font] as? UIFont)?.lineHeight ?? titleSize
        let creditLine = (credit[.font] as? UIFont)?.lineHeight ?? creditSize
        let gap = creditSize * 1.6
        let block = (heading.isEmpty ? 0 : titleLine) + (heading.isEmpty || credits.isEmpty ? 0 : gap)
            + (credits.isEmpty ? 0 : creditLine)
        var y = (barHeight * 0.9 - block) / 2
        if !heading.isEmpty {
            (heading as NSString).draw(at: CGPoint(x: (barWidth - titleWidth(heading)) / 2, y: y), withAttributes: title)
            y += titleLine + gap
        }
        if !credits.isEmpty {
            (credits as NSString).draw(at: CGPoint(x: (barWidth - creditWidth(credits)) / 2, y: y), withAttributes: credit)
        }
    }

    private static func drawLine(_ key: FrameCaptionKey, in context: CGContext) {
        if key.scrim {
            let colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.62).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: 0, y: CGFloat(key.barHeight)),
                    options: []
                )
            }
        }
        let font = UIFont.systemFont(ofSize: CGFloat(key.fontSize), weight: .medium)
        let ink = key.lightText ? UIColor.white.withAlphaComponent(0.92) : UIColor.black.withAlphaComponent(0.82)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: ink
        ]
        if key.lightText {
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
            shadow.shadowOffset = CGSize(width: 0, height: 1)
            shadow.shadowBlurRadius = 2
            attributes[.shadow] = shadow
        }
        let widthOf: (String) -> CGFloat = { text in
            (text as NSString).size(withAttributes: attributes).width
        }
        let inset = CGFloat(key.inset)
        let barWidth = CGFloat(key.barWidth)
        let contentWidth = max(0, barWidth - inset * 2)
        let gap = CGFloat(key.fontSize) * 0.5
        let model = key.model
        let date = key.date
        let modelWidth = model.isEmpty ? 0 : widthOf(model)
        let dateWidth = date.isEmpty ? 0 : widthOf(date)
        let y = key.scrim
            ? CGFloat(key.barHeight) - font.lineHeight - CGFloat(key.fontSize) * 0.45
            : (CGFloat(key.barHeight) - font.lineHeight) / 2

        if !model.isEmpty {
            (model as NSString).draw(at: CGPoint(x: inset, y: y), withAttributes: attributes)
        }
        if !date.isEmpty {
            let x = barWidth - inset - dateWidth
            (date as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
        }

        let placeOrigin = inset + (model.isEmpty ? 0 : modelWidth + gap)
        let dateBlock = date.isEmpty ? 0 : dateWidth + gap
        let place = truncated(key.place, maxWidth: barWidth - inset - dateBlock - placeOrigin, widthOf: widthOf)
        let placeWidth = place.isEmpty ? 0 : widthOf(place)
        if !place.isEmpty {
            (place as NSString).draw(at: CGPoint(x: placeOrigin, y: y), withAttributes: attributes)
        }

        guard !key.custom.isEmpty else { return }
        let start = placeOrigin + (place.isEmpty ? 0 : placeWidth + gap)
        let end = barWidth - inset - dateBlock
        let room = max(0, end - start)
        let onlyCustom = model.isEmpty && place.isEmpty && date.isEmpty
        let text = truncated(key.custom, maxWidth: onlyCustom ? contentWidth : room, widthOf: widthOf)
        guard !text.isEmpty else { return }
        let textWidth = widthOf(text)
        let x = onlyCustom
            ? inset + (contentWidth - textWidth) / 2
            : start + max(0, (room - textWidth) / 2)
        (text as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attributes)
    }

    private static func truncated(_ text: String, maxWidth: CGFloat, widthOf: (String) -> CGFloat) -> String {
        guard maxWidth > 1 else { return "" }
        if widthOf(text) <= maxWidth { return text }
        let ellipsis = "…"
        var kept = text
        while !kept.isEmpty, widthOf(kept + ellipsis) > maxWidth {
            kept.removeLast()
        }
        return kept.isEmpty ? "" : kept + ellipsis
    }
}
