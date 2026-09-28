import CoreGraphics

enum AspectCrop {
    /// Center crop, applied after the image has been oriented upright.
    static func pixelRect(for aspectRatio: AspectRatio, imageExtent: CGRect) -> CGRect {
        pixelRect(widthOverHeight: aspectRatio.widthOverHeight, imageExtent: imageExtent)
    }

    static func pixelRect(widthOverHeight target: CGFloat, imageExtent: CGRect) -> CGRect {
        let width = imageExtent.width
        let height = imageExtent.height
        guard width > 1, height > 1, target > 0 else { return imageExtent }

        let imageRatio = width / height
        var crop = imageExtent

        if imageRatio > target {
            let croppedWidth = height * target
            crop.origin.x += (width - croppedWidth) / 2
            crop.size.width = croppedWidth
        } else if imageRatio < target {
            let croppedHeight = width / target
            crop.origin.y += (height - croppedHeight) / 2
            crop.size.height = croppedHeight
        }

        return CGRect(
            x: crop.origin.x.rounded(.down),
            y: crop.origin.y.rounded(.down),
            width: max(crop.width.rounded(.down), 1),
            height: max(crop.height.rounded(.down), 1)
        )
    }
}
