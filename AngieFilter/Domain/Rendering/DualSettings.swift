import CoreGraphics
import Foundation

enum DualLayout: String, CaseIterable, Identifiable, Sendable {
    case stacked
    case sideBySide
    case pip
    case circle
    case blend

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "上下"
        case .sideBySide: return "左右"
        case .pip: return "画中画"
        case .circle: return "圆窗"
        case .blend: return "叠加"
        }
    }
}

enum PipCorner: Int, CaseIterable, Sendable {
    case bottomRight
    case bottomLeft
    case topLeft
    case topRight

    func next() -> PipCorner {
        let cases = Self.allCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[(index + 1) % cases.count]
    }
}

/// Arrangement and the two looks used for one composited frame.
struct DualSettings: Equatable, Sendable {
    var layout: DualLayout = .stacked
    var lead: CameraFacing = .back
    var selected: CameraFacing = .back
    var pipCorner: PipCorner = .bottomRight
    /// Top-left origin, as a fraction of the outer frame. Nil uses `pipCorner`.
    var pipLeft: CGFloat?
    var pipTop: CGFloat?
    var veil: Float = 0.45
    var backLookID: Look.ID = Look.originalID
    var backAdjustment = LookAdjustment()
    var frontLookID: Look.ID = Look.originalID
    var frontAdjustment = LookAdjustment()

    var other: CameraFacing {
        lead == .back ? .front : .back
    }

    var veilOpacity: CGFloat {
        CGFloat(min(max(veil, 0.2), 0.8))
    }

    func lookID(for facing: CameraFacing) -> Look.ID {
        facing == .front ? frontLookID : backLookID
    }

    func adjustment(for facing: CameraFacing) -> LookAdjustment {
        facing == .front ? frontAdjustment : backAdjustment
    }
}
