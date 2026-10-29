import CoreGraphics
import Foundation

enum WindowArrangement: UInt32, CaseIterable, Equatable, Sendable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, maximizeHeight, larger, smaller, center, restore

    func targetFrame(current: CGRect, workArea: CGRect) -> CGRect? {
        guard Self.valid(current), Self.valid(workArea) else { return nil }
        let halfWidth = workArea.width / 2
        let halfHeight = workArea.height / 2
        switch self {
        case .left: return CGRect(x: workArea.minX, y: workArea.minY, width: halfWidth, height: workArea.height)
        case .right: return CGRect(x: workArea.midX, y: workArea.minY, width: halfWidth, height: workArea.height)
        case .top: return CGRect(x: workArea.minX, y: workArea.minY, width: workArea.width, height: halfHeight)
        case .bottom: return CGRect(x: workArea.minX, y: workArea.midY, width: workArea.width, height: halfHeight)
        case .topLeft: return CGRect(x: workArea.minX, y: workArea.minY, width: halfWidth, height: halfHeight)
        case .topRight: return CGRect(x: workArea.midX, y: workArea.minY, width: halfWidth, height: halfHeight)
        case .bottomLeft: return CGRect(x: workArea.minX, y: workArea.midY, width: halfWidth, height: halfHeight)
        case .bottomRight: return CGRect(x: workArea.midX, y: workArea.midY, width: halfWidth, height: halfHeight)
        case .firstThird: return column(0, width: 1.0 / 3, area: workArea)
        case .centerThird: return column(1.0 / 3, width: 1.0 / 3, area: workArea)
        case .lastThird: return column(2.0 / 3, width: 1.0 / 3, area: workArea)
        case .firstTwoThirds: return column(0, width: 2.0 / 3, area: workArea)
        case .centerTwoThirds: return column(1.0 / 6, width: 2.0 / 3, area: workArea)
        case .lastTwoThirds: return column(1.0 / 3, width: 2.0 / 3, area: workArea)
        case .maximize: return workArea
        case .maximizeHeight:
            return CGRect(x: current.minX, y: workArea.minY, width: current.width, height: workArea.height)
        case .larger, .smaller:
            let factor: CGFloat = self == .larger ? 1.1 : 0.9
            let width = min(workArea.width, max(1, current.width * factor))
            let height = min(workArea.height, max(1, current.height * factor))
            return centered(size: CGSize(width: width, height: height), workArea: workArea)
        case .center:
            return CGRect(x: workArea.midX - current.width / 2, y: workArea.midY - current.height / 2,
                          width: current.width, height: current.height)
        case .restore:
            return nil
        }
    }

    private func column(_ offset: CGFloat, width: CGFloat, area: CGRect) -> CGRect {
        CGRect(x: area.minX + area.width * offset, y: area.minY,
               width: area.width * width, height: area.height)
    }

    private func centered(size: CGSize, workArea: CGRect) -> CGRect {
        let width = min(workArea.width, size.width)
        let height = min(workArea.height, size.height)
        return CGRect(x: workArea.midX - width / 2, y: workArea.midY - height / 2,
                      width: width, height: height)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
}
