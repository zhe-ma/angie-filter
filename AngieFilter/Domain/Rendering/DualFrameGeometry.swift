import CoreGraphics

/// Top-left pane frames inside the outer photo. Shared by the preview chrome and the compositor.
struct DualFrameGeometry: Equatable, Sendable {
    struct Pane: Equatable, Sendable {
        var frame: CGRect
        var facing: CameraFacing
        var opacity: CGFloat
        var shape: Shape

        enum Shape: Equatable, Sendable {
            case rect
            case rounded(CGFloat)
            case circle
        }

        var isCircle: Bool {
            if case .circle = shape { return true }
            return false
        }

        var cornerRadius: CGFloat {
            if case .rounded(let radius) = shape { return radius }
            return 0
        }

        func contains(_ point: CGPoint) -> Bool {
            switch shape {
            case .circle:
                let dx = point.x - frame.midX
                let dy = point.y - frame.midY
                let radius = frame.width / 2
                return dx * dx + dy * dy <= radius * radius
            case .rect, .rounded:
                return frame.contains(point)
            }
        }
    }

    enum Hit: Equatable, Sendable {
        case none
        case blend(CGRect)
        case pane(CameraFacing, CGRect)
    }

    var layout: DualLayout
    var canvas: CGSize
    var lead: Pane
    var other: Pane

    func pane(facing: CameraFacing) -> Pane {
        lead.facing == facing ? lead : other
    }

    func hit(_ point: CGPoint) -> Hit {
        guard CGRect(origin: .zero, size: canvas).contains(point) else { return .none }
        if layout == .blend { return .blend(lead.frame) }
        if other.contains(point) { return .pane(other.facing, other.frame) }
        if lead.contains(point) { return .pane(lead.facing, lead.frame) }
        return .none
    }

    static func make(canvas: CGSize, settings: DualSettings) -> DualFrameGeometry {
        let full = CGRect(origin: .zero, size: canvas)
        let leadFacing = settings.lead
        let otherFacing = settings.other
        switch settings.layout {
        case .stacked:
            let height = canvas.height / 2
            return DualFrameGeometry(
                layout: .stacked,
                canvas: canvas,
                lead: Pane(frame: CGRect(x: 0, y: 0, width: canvas.width, height: height), facing: leadFacing, opacity: 1, shape: .rect),
                other: Pane(frame: CGRect(x: 0, y: height, width: canvas.width, height: height), facing: otherFacing, opacity: 1, shape: .rect)
            )
        case .sideBySide:
            let width = canvas.width / 2
            return DualFrameGeometry(
                layout: .sideBySide,
                canvas: canvas,
                lead: Pane(frame: CGRect(x: 0, y: 0, width: width, height: canvas.height), facing: leadFacing, opacity: 1, shape: .rect),
                other: Pane(frame: CGRect(x: width, y: 0, width: width, height: canvas.height), facing: otherFacing, opacity: 1, shape: .rect)
            )
        case .pip, .circle:
            let inset = insetFrame(canvas: canvas, settings: settings)
            let shape: Pane.Shape = settings.layout == .circle
                ? .circle
                : .rounded(min(inset.width, inset.height) * 0.08)
            return DualFrameGeometry(
                layout: settings.layout,
                canvas: canvas,
                lead: Pane(frame: full, facing: leadFacing, opacity: 1, shape: .rect),
                other: Pane(frame: inset, facing: otherFacing, opacity: 1, shape: shape)
            )
        case .blend:
            return DualFrameGeometry(
                layout: .blend,
                canvas: canvas,
                lead: Pane(frame: full, facing: leadFacing, opacity: 1, shape: .rect),
                other: Pane(frame: full, facing: otherFacing, opacity: settings.veilOpacity, shape: .rect)
            )
        }
    }

    static func insetFrame(canvas: CGSize, settings: DualSettings) -> CGRect {
        let width: CGFloat
        let height: CGFloat
        if settings.layout == .circle {
            let side = min(canvas.width, canvas.height) * 0.36
            width = side
            height = side
        } else {
            width = canvas.width * 0.36
            height = canvas.height * 0.30
        }
        var left: CGFloat
        var top: CGFloat
        if let pipLeft = settings.pipLeft, let pipTop = settings.pipTop {
            left = pipLeft * canvas.width
            top = pipTop * canvas.height
        } else {
            let marginX = canvas.width * 0.05
            let marginTop = canvas.height * 0.06
            let marginBottom = canvas.height * 0.16
            let atRight = settings.pipCorner == .bottomRight || settings.pipCorner == .topRight
            let atBottom = settings.pipCorner == .bottomRight || settings.pipCorner == .bottomLeft
            left = atRight ? canvas.width - marginX - width : marginX
            top = atBottom ? canvas.height - marginBottom - height : marginTop
        }
        left = min(max(0, left), max(0, canvas.width - width))
        top = min(max(0, top), max(0, canvas.height - height))
        return CGRect(x: left, y: top, width: width, height: height)
    }
}
