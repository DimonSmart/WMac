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


/// Pure geometry policy for ordinary zoomed and system-tiled windows.
/// All coordinates have the Accessibility top-left origin.
enum WindowReservationGeometry {
    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance &&
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func bestDisplay(for window: CGRect, in displays: [WindowReservationDisplay]) -> WindowReservationDisplay? {
        displays.compactMap { display -> (WindowReservationDisplay, CGFloat)? in
            let intersection = window.intersection(display.frame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }
            return (display, intersection.width * intersection.height)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    static func adjustedFrame(_ window: CGRect, visible: CGRect, full: CGRect, available: CGRect) -> CGRect? {
        let tolerance: CGFloat = 16
        guard window.width > 0, window.height > 0, visible.width > 0, visible.height > 0,
              available.height > 0, !approximatelyEqual(window, full),
              window.maxY > available.maxY + 2,
              abs(window.maxY - visible.maxY) <= tolerance,
              window.minX >= visible.minX - tolerance,
              window.maxX <= visible.maxX + tolerance,
              abs(window.minY - visible.minY) <= tolerance ||
                  abs(window.minY - visible.midY) <= tolerance else { return nil }
        let grid: [CGFloat] = [0, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 1]
        func onGrid(_ edge: CGFloat) -> Bool {
            grid.contains { abs(edge - (visible.minX + visible.width * $0)) <= tolerance }
        }
        guard onGrid(window.minX), onGrid(window.maxX) else { return nil }
        let height = available.maxY - window.minY
        guard height > 0 else { return nil }
        return CGRect(x: window.minX, y: window.minY, width: window.width, height: height)
    }
}

/// A virtual work area. macOS does not let third-party panels change NSScreen.visibleFrame.
struct WindowReservationDisplay: Equatable {
    let id: UInt32
    let frame: CGRect          // Accessibility coordinates (top-left origin).
    let visible: CGRect
    let available: CGRect
    let appKitAvailable: CGRect

}
